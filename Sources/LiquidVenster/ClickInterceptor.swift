import AppKit
import ApplicationServices

enum InterceptorError: Error, LocalizedError {
    case notTrusted
    case tapCreationFailed
    case runLoopSourceFailed

    var errorDescription: String? {
        switch self {
        case .notTrusted: return "No access to Accessibility"
        case .tapCreationFailed: return "Could not intercept mouse clicks (event tap refused)"
        case .runLoopSourceFailed: return "Could not attach the event tap to the run loop"
        }
    }
}

/// Watches left clicks system-wide. A click on the yellow (minimize) or red (close) button
/// of another app's window is swallowed (mouse-down, drags and mouse-up) and reported
/// instead; every other click passes through untouched.
///
/// The callback runs on the main thread and must stay fast; the only potentially slow
/// part, the accessibility hit-test, is limited by a 0.2 s messaging timeout and only
/// done for clicks in the top strip of a normal window.
@MainActor
final class ClickInterceptor {
    struct WindowInfo {
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
    }

    private struct Pending {
        /// nil = only swallow this click (e.g. the second half of a double-click).
        let request: ExternalWindowRequest?
        let buttonFrame: CGRect
    }

    /// Right after a minimize click, further clicks on the same spot are swallowed so a
    /// double-click does not minimize the window natively before the effect starts.
    private var recentButtonFrame: CGRect = .null
    private var recentUntil: CFTimeInterval = 0

    var onButtonClick: ((ExternalWindowRequest) -> Void)?
    /// Evaluated on every mouse-down; must be cheap (use cached values).
    var shouldIntercept: (WindowAction) -> Bool = { _ in false }

    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var pending: Pending?
    private(set) var systemDisableCount = 0

    func start() throws {
        guard !isRunning else { return }
        guard AXIsProcessTrusted() else { throw InterceptorError.notTrusted }
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: clickInterceptorCallback, userInfo: refcon) else {
            throw InterceptorError.tapCreationFailed
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            throw InterceptorError.runLoopSourceFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        logInfo("Clicks on yellow and red buttons are now intercepted")
    }

    func stop() {
        guard isRunning else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        pending = nil
        isRunning = false
        logInfo("Stopped intercepting clicks")
    }

    /// Turns the tap back on if the system disabled it; returns false if it stays off.
    @discardableResult
    func ensureHealthy() -> Bool {
        guard isRunning, let tap else { return false }
        if CGEvent.tapIsEnabled(tap: tap) { return true }
        logWarning("Event tap was off; re-enabled")
        CGEvent.tapEnable(tap: tap, enable: true)
        return CGEvent.tapIsEnabled(tap: tap)
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            systemDisableCount += 1
            pending = nil
            logWarning("System disabled the event tap (\(type == .tapDisabledByTimeout ? "timeout" : "user input")); re-enabled")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .leftMouseDown:
            pending = nil   // a mouse-up that never arrived must not leave us stuck
            guard shouldIntercept(.minimize) || shouldIntercept(.close) else { return pass }
            if CACurrentMediaTime() < recentUntil, recentButtonFrame.insetBy(dx: -4, dy: -4).contains(event.location) {
                pending = Pending(request: nil, buttonFrame: recentButtonFrame)
                return nil
            }
            let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            // Option-click = "minimize all" etc.: leave special clicks to the system.
            guard event.flags.intersection(modifiers).isEmpty else { return pass }
            guard event.getIntegerValueField(.mouseEventClickState) <= 1 else { return pass }
            let started = CACurrentMediaTime()
            let hit = hitTest(event.location)
            let elapsed = (CACurrentMediaTime() - started) * 1000
            if elapsed > 100 { logWarning("Hit test took \(Int(elapsed)) ms") }
            guard let hit else { return pass }
            pending = hit
            return nil

        case .leftMouseDragged:
            return pending == nil ? pass : nil

        case .leftMouseUp:
            guard let current = pending else { return pass }
            pending = nil
            guard let request = current.request else { return nil }
            // Like a real button: releasing outside it cancels the click.
            if current.buttonFrame.insetBy(dx: -4, dy: -4).contains(event.location) {
                recentButtonFrame = current.buttonFrame
                recentUntil = CACurrentMediaTime() + 0.6
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.onButtonClick?(request) }
                }
            } else {
                logInfo("Click on \(request.action == .minimize ? "yellow" : "red") button cancelled (released outside the button)")
            }
            return nil

        default:
            return pass
        }
    }

    /// Returns the click target if `location` (Quartz) is on an enabled minimize (yellow) or
    /// close (red) button of a normal, non-fullscreen window of another app that sits on a
    /// single display, and the effect for that button is switched on.
    private func hitTest(_ location: CGPoint) -> Pending? {
        guard let h = ScreenGeometry.primaryHeight() else { return nil }
        let cocoa = ScreenGeometry.cocoaPoint(fromQuartz: location, primaryHeight: h)
        guard let (windowNumber, info) = ClickInterceptor.windowUnderMouse(quartz: location, cocoa: cocoa) else { return nil }
        // Our own windows handle the effect themselves (and an AX call into our own
        // process from the main thread would dead-lock until the timeout).
        guard info.pid != getpid(), info.layer == 0 else { return nil }
        // The traffic lights always live in the top strip of a window.
        guard location.y >= info.bounds.minY - 1, location.y - info.bounds.minY <= 90 else { return nil }

        let app = AXUIElementCreateApplication(info.pid)
        AX.setTimeout(app, seconds: 0.2)
        var hit: AXUIElement?
        let error = AXUIElementCopyElementAtPosition(app, Float(location.x), Float(location.y), &hit)
        guard error == .success, let element = hit else {
            if error != .noValue && error != .success {
                logDebug("Hit test in pid \(info.pid) failed: \(AX.describe(error))")
            }
            return nil
        }
        AX.setTimeout(element, seconds: 0.2)
        let action: WindowAction
        switch AX.string(element, kAXSubroleAttribute) {
        case kAXMinimizeButtonSubrole?: action = .minimize
        case kAXCloseButtonSubrole?: action = .close
        default: return nil
        }
        guard shouldIntercept(action) else { return nil }
        if AX.bool(element, kAXEnabledAttribute) == false { return nil }

        let name = NSRunningApplication(processIdentifier: info.pid)?.localizedName ?? "pid \(info.pid)"
        guard let window = AX.window(containing: element) else {
            logWarning("\(name): \(action.rawValue) button without window; normal click")
            return nil
        }
        AX.setTimeout(window, seconds: 0.3)
        if AX.bool(window, "AXFullScreen") == true { return nil }
        if AX.bool(window, kAXMinimizedAttribute) == true { return nil }
        guard let windowFrame = AX.frame(window), let buttonFrame = AX.frame(element) else {
            logWarning("\(name): window or button frame unknown; normal click")
            return nil
        }
        let cocoaRect = ScreenGeometry.cocoaRect(fromQuartz: windowFrame, primaryHeight: h)
        guard let best = ScreenGeometry.bestFrame(for: cocoaRect, in: NSScreen.screens.map(\.frame)) else { return nil }
        if best.spansMultiple {
            logInfo("\(name): window spans several displays; normal animation")
            return nil
        }
        if MinimizeCoordinator.reduceMotionActive { return nil }

        let windowID = AX.windowID(window)
            ?? (WindowCapture.framesClose(info.bounds, windowFrame) ? windowNumber : nil)
        let request = ExternalWindowRequest(action: action, pid: info.pid, window: window, button: element,
                                              windowFrame: windowFrame, clickPoint: location,
                                              windowID: windowID, appName: name)
        return Pending(request: request, buttonFrame: buttonFrame)
    }

    /// The window that receives a click at this point. Uses the window server's own hit-test
    /// and falls back to walking the on-screen window list (front to back).
    static func windowUnderMouse(quartz: CGPoint, cocoa: CGPoint) -> (CGWindowID, WindowInfo)? {
        let me = getpid()
        let overlayLevel = Int(CGWindowLevelForKey(.screenSaverWindow))
        let number = NSWindow.windowNumber(at: cocoa, belowWindowWithWindowNumber: 0)
        if number > 0, let info = windowInfo(CGWindowID(number)), !(info.pid == me && info.layer >= overlayLevel) {
            return (CGWindowID(number), info)
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for entry in list {
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let info = parse(entry) else { continue }
            if info.pid == me && info.layer >= overlayLevel { continue }       // our click-through overlay
            if let alpha = (entry[kCGWindowAlpha as String] as? NSNumber)?.doubleValue, alpha < 0.01 { continue }
            if info.bounds.contains(quartz) { return (id, info) }
        }
        return nil
    }

    static func windowInfo(_ id: CGWindowID) -> WindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
              let entry = list.first else { return nil }
        return parse(entry)
    }

    private static func parse(_ entry: [String: Any]) -> WindowInfo? {
        guard let pid = (entry[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let layer = (entry[kCGWindowLayer as String] as? NSNumber)?.intValue,
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { return nil }
        return WindowInfo(pid: pid, layer: layer, bounds: bounds)
    }
}

/// C callback for the event tap. Runs on the main run loop (where the source was added).
private func clickInterceptorCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                      refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<ClickInterceptor>.fromOpaque(refcon).takeUnretainedValue()
    return MainActor.assumeIsolated { interceptor.handle(type: type, event: event) }
}
