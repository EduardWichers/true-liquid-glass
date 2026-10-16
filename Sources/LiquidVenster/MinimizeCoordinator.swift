import AppKit
import ApplicationServices

/// What the clicked traffic-light button does.
enum WindowAction: String {
    /// Yellow button: water flows into the Dock.
    case minimize
    /// Red button: the window evaporates.
    case close

    var effect: LiquidEffect { self == .minimize ? .water : .steam }
}

/// A click on the yellow or red button of another app's window (from `ClickInterceptor`).
struct ExternalWindowRequest {
    let action: WindowAction
    let pid: pid_t
    let window: AXUIElement
    let button: AXUIElement
    /// Quartz coordinates (top-left origin).
    let windowFrame: CGRect
    let clickPoint: CGPoint
    let windowID: CGWindowID?
    let appName: String
}

enum CoordinatorError: Error, LocalizedError {
    case noScreens
    case offscreen(CGRect)
    case spansDisplays
    case noDisplayID
    case transparentWindow
    case displayAsleep

    var errorDescription: String? {
        switch self {
        case .noScreens: return "No displays found"
        case .offscreen(let r): return "Window \(r) is not on any display"
        case .spansDisplays: return "Window spans several displays"
        case .noDisplayID: return "Display ID unknown"
        case .transparentWindow: return "Window is (almost) fully transparent"
        case .displayAsleep: return "Display is asleep"
        }
    }

    /// Situations where falling back to the normal animation is expected, not an error.
    var isExpected: Bool {
        switch self {
        case .spansDisplays, .displayAsleep, .transparentWindow: return true
        default: return false
        }
    }
}

/// Runs a closure at most once.
final class Once {
    private(set) var hasRun = false
    func run(_ body: () -> Void) {
        guard !hasRun else { return }
        hasRun = true
        body()
    }
}

/// Plays the animations one at a time and guarantees that every accepted click
/// ends the way the user asked (minimized / closed): whenever anything fails the
/// window is minimized or closed the normal way.
@MainActor
final class MinimizeCoordinator {
    static let shared = MinimizeCoordinator()

    private enum Job {
        case external(ExternalWindowRequest)
        case own(LiquidWindow, WindowAction)
    }

    struct Placement {
        let screen: NSScreen
        let displayID: CGDirectDisplayID
        let primaryHeight: CGFloat
    }

    static let maxQueuedJobs = 3
    static let windowCornerRadius: CGFloat = 12
    /// After pressing the red button the window must be gone within this time; otherwise the
    /// app is probably asking something (e.g. "save changes?") and the overlay steps aside.
    static let closeVerificationDelay: Double = 0.5

    private var queue: [Job] = []
    private var activeJob: Job?
    private var activeOverlay: LiquidOverlay?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let settings = AppSettings.shared

    private init() {
        let center = NotificationCenter.default
        observers.append((center, center.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeOverlay?.abort("another desktop (Space) became active") }
        }))
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeOverlay?.abort("display went to sleep") }
        }))
    }

    var isAnimating: Bool { activeOverlay != nil }

    static var reduceMotionActive: Bool {
        AppSettings.shared.respectReduceMotion && NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: Submitting

    func submitExternal(_ request: ExternalWindowRequest) {
        if ScreenGeometry.isSessionLocked() {
            MinimizeCoordinator.performNatively(request)
            return
        }
        if isQueued(window: request.window) {
            logDebug("\(request.appName): window is already being handled")
            return
        }
        guard queue.count < MinimizeCoordinator.maxQueuedJobs else {
            logWarning("Too many windows at once; \(request.appName) is handled without effect")
            MinimizeCoordinator.performNatively(request)
            return
        }
        queue.append(.external(request))
        pump()
    }

    /// Returns false when the caller should minimize / close the window natively.
    func submitOwn(_ window: LiquidWindow, action: WindowAction) -> Bool {
        if case .failure(let error) = LiquidRenderer.shared() {
            logWarning("No effect: \(error.liquidDescription)")
            return false
        }
        if ScreenGeometry.isSessionLocked() {
            logInfo("Screen is locked; \(window.title) is handled without effect")
            return false
        }
        if isQueued(window: window) { return true }
        guard queue.count < MinimizeCoordinator.maxQueuedJobs else {
            logWarning("Too many windows at once; \(window.title) is handled without effect")
            return false
        }
        queue.append(.own(window, action))
        pump()
        return true
    }

    private func isQueued(window: AXUIElement) -> Bool {
        let all = queue + (activeJob.map { [$0] } ?? [])
        return all.contains { job in
            if case .external(let r) = job { return CFEqual(r.window, window) }
            return false
        }
    }

    private func isQueued(window: LiquidWindow) -> Bool {
        let all = queue + (activeJob.map { [$0] } ?? [])
        return all.contains { job in
            if case .own(let w, _) = job { return w === window }
            return false
        }
    }

    private func pump() {
        guard activeJob == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        activeJob = job
        Task { @MainActor in
            switch job {
            case .external(let request): await self.runExternal(request)
            case .own(let window, let action): await self.runOwn(window, action: action)
            }
        }
    }

    private func jobFinished() {
        activeJob = nil
        activeOverlay = nil
        pump()
    }

    private func screensChanged() {
        guard let overlay = activeOverlay else { return }
        let stillThere = NSScreen.screens.contains {
            ScreenGeometry.displayID(of: $0) == overlay.displayID && $0.frame == overlay.screenFrame
        }
        if !stillThere { overlay.abort("display configuration changed") }
    }

    // MARK: Other apps

    private func runExternal(_ request: ExternalWindowRequest) async {
        let started = CACurrentMediaTime()
        do {
            let renderer = try LiquidRenderer.shared().get()
            guard Permissions.screenCaptureGranted else { throw CaptureError.permissionDenied }
            let placement = try MinimizeCoordinator.placement(forQuartzRect: request.windowFrame)

            let capture = try await withTimeout(seconds: 2.0, label: "screen capture of \(request.appName)") {
                try await WindowCapture.capture(windowID: request.windowID, pid: request.pid,
                                                frameQuartz: request.windowFrame, displayID: placement.displayID)
            }
            // The window may have been closed or minimized while we were capturing.
            // (An unreadable attribute is not proof of that; then we simply carry on.)
            let windowGone = AX.frame(request.window) == nil && AX.string(request.window, kAXRoleAttribute) == nil
            if AX.bool(request.window, kAXMinimizedAttribute) == true || windowGone {
                logInfo("\(request.appName): window is already gone or minimized")
                jobFinished()
                return
            }
            if !WindowCapture.framesClose(capture.windowFrameQuartz, request.windowFrame, tolerance: 6) {
                logWarning("Window frame changed during capture: \(request.windowFrame) → \(capture.windowFrameQuartz)")
            }

            let dock = request.action == .minimize ? DockLocator.locate(pid: request.pid) : nil
            let overlay = try makeOverlay(renderer: renderer, windowImage: capture.window,
                                          background: capture.background, maskCorners: false,
                                          windowFrameQuartz: capture.windowFrameQuartz,
                                          clickQuartz: request.clickPoint, effect: request.action.effect,
                                          dock: dock, placement: placement, label: request.appName)

            let performOnce = Once()
            overlay.onFirstFramePresented = { [weak overlay] in
                performOnce.run {
                    if !MinimizeCoordinator.performNatively(request) {
                        overlay?.abort("window could not be \(request.action == .minimize ? "minimized" : "closed")")
                        return
                    }
                    if request.action == .close {
                        // If the app asks something first ("save changes?"), the window stays:
                        // then show it again instead of letting it evaporate.
                        DispatchQueue.main.asyncAfter(deadline: .now() + MinimizeCoordinator.closeVerificationDelay) { [weak overlay] in
                            if !MinimizeCoordinator.isGone(request) {
                                overlay?.abort("window did not close (the app is probably asking something)")
                            }
                        }
                    }
                }
            }
            overlay.isTargetGone = { MinimizeCoordinator.isGone(request) }
            overlay.onEnd = { [weak self] reason in
                if case .aborted(let message) = reason { logWarning("Animation aborted: \(message)") }
                performOnce.run { MinimizeCoordinator.performNatively(request) }
                self?.jobFinished()
            }
            activeOverlay = overlay
            logDebug("Preparation \(Int((CACurrentMediaTime() - started) * 1000)) ms")
            overlay.start()
        } catch {
            MinimizeCoordinator.reportFallback(error, label: request.appName, action: request.action)
            MinimizeCoordinator.performNatively(request)
            jobFinished()
        }
    }

    /// Minimizes or closes the window the regular way by "pressing" its button, so the app's
    /// own logic runs (e.g. a "save changes?" question). Minimizing falls back to setting the
    /// minimized attribute directly.
    @discardableResult
    static func performNatively(_ request: ExternalWindowRequest) -> Bool {
        AX.setTimeout(request.button, seconds: 1.0)
        AX.setTimeout(request.window, seconds: 1.0)
        let press = AX.press(request.button)
        if press == .success { return true }
        guard request.action == .minimize else {
            logError("\(request.appName): pressing the close button failed (\(AX.describe(press)))")
            return false
        }
        logWarning("\(request.appName): pressing the button failed (\(AX.describe(press))); trying AXMinimized")
        let set = AX.setMinimized(request.window, true)
        if set == .success { return true }
        logError("\(request.appName): minimizing failed (\(AX.describe(set)))")
        return false
    }

    /// Minimized, closed or hidden. A window that no longer exists counts as gone.
    static func isGone(_ request: ExternalWindowRequest) -> Bool {
        switch request.action {
        case .minimize:
            return AX.bool(request.window, kAXMinimizedAttribute) ?? true
        case .close:
            if let id = request.windowID {
                guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
                      let info = list.first else { return true }
                return !((info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false)
            }
            return AX.string(request.window, kAXRoleAttribute) == nil
        }
    }

    // MARK: Our own windows

    private func runOwn(_ window: LiquidWindow, action: WindowAction) async {
        let performOnce = Once()
        let perform: (LiquidWindow) -> Void = { window in
            performOnce.run {
                switch action {
                case .minimize: window.nativeMiniaturize()
                case .close: window.nativeClose()
                }
            }
        }
        do {
            let renderer = try LiquidRenderer.shared().get()
            guard window.isVisible, !window.isMiniaturized else { jobFinished(); return }
            guard let h = ScreenGeometry.primaryHeight() else { throw CoordinatorError.noScreens }
            let frameQuartz = ScreenGeometry.quartzRect(fromCocoa: window.frame, primaryHeight: h)
            let placement = try MinimizeCoordinator.placement(forQuartzRect: frameQuartz)

            var windowImage: CGImage
            var background: CGImage?
            var maskCorners = false
            var capturedFrame = frameQuartz
            if Permissions.screenCaptureGranted {
                do {
                    let capture = try await withTimeout(seconds: 2.0, label: "screen capture of own window") {
                        try await WindowCapture.capture(windowID: CGWindowID(window.windowNumber), pid: getpid(),
                                                        frameQuartz: frameQuartz, displayID: placement.displayID)
                    }
                    windowImage = capture.window
                    background = capture.background
                    capturedFrame = capture.windowFrameQuartz
                } catch {
                    logWarning("Screen capture failed (\(error.liquidDescription)); using a snapshot without background")
                    windowImage = try WindowCapture.snapshotOwnWindow(window)
                    maskCorners = true
                }
            } else {
                windowImage = try WindowCapture.snapshotOwnWindow(window)
                maskCorners = true
            }
            // State may have changed while capturing.
            guard window.isVisible, !window.isMiniaturized else { jobFinished(); return }

            let transparent = background == nil
            let dock = action == .minimize ? DockLocator.locate(pid: getpid()) : nil
            let overlay = try makeOverlay(renderer: renderer, windowImage: windowImage, background: background,
                                          maskCorners: maskCorners, windowFrameQuartz: capturedFrame,
                                          clickQuartz: window.buttonCenterQuartz(action, primaryHeight: h),
                                          effect: action.effect, dock: dock, placement: placement, label: window.title)

            overlay.onFirstFramePresented = { [weak window] in
                guard let window else { return }
                // Without a background plate the overlay is transparent, so the real
                // window must become invisible while it disappears underneath.
                if transparent { window.alphaValue = 0 }
                perform(window)
            }
            overlay.isTargetGone = { [weak window] in
                guard let window else { return true }
                return window.isMiniaturized || !window.isVisible
            }
            overlay.onEnd = { [weak self, weak window] reason in
                if case .aborted(let message) = reason { logWarning("Animation aborted: \(message)") }
                if let window {
                    perform(window)
                    window.alphaValue = 1   // a closed window may be shown again later
                }
                self?.jobFinished()
            }
            activeOverlay = overlay
            overlay.start()
        } catch {
            MinimizeCoordinator.reportFallback(error, label: window.title, action: action)
            window.alphaValue = 1
            perform(window)
            jobFinished()
        }
    }

    // MARK: Shared

    /// The colour picker works in sRGB; captures and the overlay use Display P3.
    static func shaderColor(_ color: WaterColor) -> SIMD3<Float> {
        let srgb = NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: 1)
        guard let p3 = srgb.usingColorSpace(.displayP3) else {
            return SIMD3(Float(color.red), Float(color.green), Float(color.blue))
        }
        func unit(_ v: CGFloat) -> Float { v.isFinite ? Float(min(max(v, 0), 1)) : 0.5 }
        return SIMD3(unit(p3.redComponent), unit(p3.greenComponent), unit(p3.blueComponent))
    }

    private static func reportFallback(_ error: Error, label: String, action: WindowAction) {
        let verb = action == .minimize ? "Minimizing" : "Closing"
        let message = "\(label): effect not possible – \(error.liquidDescription). \(verb) normally."
        if (error as? CoordinatorError)?.isExpected == true { logInfo(message) } else { logError(message) }
    }

    static func placement(forQuartzRect rect: CGRect) throws -> Placement {
        let screens = NSScreen.screens
        guard !screens.isEmpty, let h = ScreenGeometry.primaryHeight(screens) else { throw CoordinatorError.noScreens }
        let cocoa = ScreenGeometry.cocoaRect(fromQuartz: rect, primaryHeight: h)
        guard let best = ScreenGeometry.bestFrame(for: cocoa, in: screens.map(\.frame)) else {
            throw CoordinatorError.offscreen(rect)
        }
        if best.spansMultiple { throw CoordinatorError.spansDisplays }
        let screen = screens[best.index]
        guard let id = ScreenGeometry.displayID(of: screen) else { throw CoordinatorError.noDisplayID }
        if ScreenGeometry.isDisplayAsleep(id) { throw CoordinatorError.displayAsleep }
        return Placement(screen: screen, displayID: id, primaryHeight: h)
    }

    private func makeOverlay(renderer: LiquidRenderer, windowImage: CGImage, background: CGImage?,
                             maskCorners: Bool, windowFrameQuartz: CGRect, clickQuartz: CGPoint?,
                             effect: LiquidEffect, dock: DockTarget?, placement: Placement,
                             label: String) throws -> LiquidOverlay {
        let screen = placement.screen
        let h = placement.primaryHeight
        let viewRect = CGRect(origin: .zero, size: screen.frame.size)
        let local = ScreenGeometry.localRect(fromQuartz: windowFrameQuartz, screenFrame: screen.frame, primaryHeight: h)
        guard ScreenGeometry.isValid(local) else { throw CoordinatorError.offscreen(windowFrameQuartz) }

        // If the Dock is on another display the water drains to the nearest edge of this one.
        // (Steam does not need a target; it just rises.)
        let rawTarget = dock.map {
            ScreenGeometry.localPoint(fromQuartz: $0.pointQuartz, screenFrame: screen.frame, primaryHeight: h)
        } ?? CGPoint(x: local.midX, y: viewRect.maxY)
        let target = ScreenGeometry.clamp(rawTarget, into: viewRect, inset: 6)
        let ripple = clickQuartz.map {
            ScreenGeometry.localPoint(fromQuartz: $0, screenFrame: screen.frame, primaryHeight: h)
        } ?? CGPoint(x: local.minX + 40, y: local.minY + 18)

        let pixelsPerPoint = CGFloat(windowImage.width) / max(local.width, 1)
        let (windowTexture, pixels) = try renderer.makeTexture(
            from: windowImage, colorSpace: WindowCapture.colorSpace, keepPixels: true,
            cornerRadiusPixels: maskCorners ? MinimizeCoordinator.windowCornerRadius * pixelsPerPoint : 0)
        guard let pixels else { throw RenderError.texture("no pixel data") }
        guard pixels.coverage() > 0.02 else { throw CoordinatorError.transparentWindow }
        let backgroundTexture = try background.map {
            try renderer.makeTexture(from: $0, colorSpace: WindowCapture.colorSpace, keepPixels: false).0
        }

        // The falling water lands on top of the Dock icon (just above it).
        let iconSize = min(max(dock?.iconSize ?? 48, 16), 256)
        let floorY = target.y - iconSize * 0.5 - 2
        let input = LiquidSceneInput(
            viewSize: viewRect.size, windowRect: local, target: target, rippleOrigin: ripple,
            edge: dock?.edge ?? .bottom, drainRadius: iconSize * 0.22, floorY: floorY,
            opaqueBackground: backgroundTexture != nil,
            waterColor: MinimizeCoordinator.shaderColor(settings.waterColor),
            colorStrength: Float(settings.colorStrength),
            cornerRadius: Float(MinimizeCoordinator.windowCornerRadius),
            effect: effect,
            alphaAt: { u, v in pixels.alpha(u: u, v: v) })
        let scene = try LiquidScene.build(input)
        let session = try LiquidRenderSession(renderer: renderer, scene: scene,
                                              windowTexture: windowTexture, backgroundTexture: backgroundTexture)
        let overlay = LiquidOverlay(screen: screen, session: session, speed: settings.speed)
        logInfo(String(format: "%@: %@, %d particles, %.2f s, %@%@",
                       label, effect == .water ? "water" : "steam", scene.particles.count, overlay.realDuration,
                       backgroundTexture != nil ? "with background" : "without background",
                       dock.map { ", to \($0.source)" } ?? ""))
        return overlay
    }
}
