import AppKit
import ApplicationServices
import Carbon.HIToolbox
import SwiftUI

/// Window layouts, like Magnet / Windows Snap.
enum SnapAction: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, maximize, restore
    case topHalf, bottomHalf
    case topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird, leftTwoThirds, rightTwoThirds
    case center

    var id: String { rawValue }

    var label: L {
        switch self {
        case .leftHalf: return .snapLeftHalf
        case .rightHalf: return .snapRightHalf
        case .maximize: return .snapMaximize
        case .restore: return .snapRestore
        case .topHalf: return .snapTopHalf
        case .bottomHalf: return .snapBottomHalf
        case .topLeft: return .snapTopLeft
        case .topRight: return .snapTopRight
        case .bottomLeft: return .snapBottomLeft
        case .bottomRight: return .snapBottomRight
        case .leftThird: return .snapLeftThird
        case .centerThird: return .snapCenterThird
        case .rightThird: return .snapRightThird
        case .leftTwoThirds: return .snapLeftTwoThirds
        case .rightTwoThirds: return .snapRightTwoThirds
        case .center: return .snapCenter
        }
    }
}

/// Default shortcut keys (same layout as Magnet: U I / J K for the quarters, D F G for the
/// thirds, E T for two thirds, arrows like Windows: ←/→ halves, ↑ maximize, ↓ restore).
enum SnapKeys {
    static let table: [SnapAction: Int] = [
        .leftHalf: kVK_LeftArrow, .rightHalf: kVK_RightArrow, .maximize: kVK_UpArrow, .restore: kVK_DownArrow,
        .topLeft: kVK_ANSI_U, .topRight: kVK_ANSI_I, .bottomLeft: kVK_ANSI_J, .bottomRight: kVK_ANSI_K,
        .leftThird: kVK_ANSI_D, .centerThird: kVK_ANSI_F, .rightThird: kVK_ANSI_G,
        .leftTwoThirds: kVK_ANSI_E, .rightTwoThirds: kVK_ANSI_T, .center: kVK_ANSI_C,
    ]

    /// Actions that have a shortcut, in the order shown in the settings.
    static let ordered: [SnapAction] = [.leftHalf, .rightHalf, .maximize, .restore, .topLeft, .topRight,
                                        .bottomLeft, .bottomRight, .leftThird, .centerThird, .rightThird,
                                        .leftTwoThirds, .rightTwoThirds, .center]

    static func combo(_ action: SnapAction, modifiers: NSEvent.ModifierFlags) -> KeyCombo? {
        table[action].map { KeyCombo($0, modifiers) }
    }
}

/// Pure layout maths in Cocoa coordinates (origin bottom-left), testable without windows.
enum SnapLayout {
    static func frame(for action: SnapAction, visible v: CGRect, current: CGRect) -> CGRect {
        let w = v.width, h = v.height
        let r: CGRect
        switch action {
        case .leftHalf: r = CGRect(x: v.minX, y: v.minY, width: w / 2, height: h)
        case .rightHalf: r = CGRect(x: v.minX + w / 2, y: v.minY, width: w / 2, height: h)
        case .maximize: r = v
        case .restore: r = current
        case .topHalf: r = CGRect(x: v.minX, y: v.minY + h / 2, width: w, height: h / 2)
        case .bottomHalf: r = CGRect(x: v.minX, y: v.minY, width: w, height: h / 2)
        case .topLeft: r = CGRect(x: v.minX, y: v.minY + h / 2, width: w / 2, height: h / 2)
        case .topRight: r = CGRect(x: v.minX + w / 2, y: v.minY + h / 2, width: w / 2, height: h / 2)
        case .bottomLeft: r = CGRect(x: v.minX, y: v.minY, width: w / 2, height: h / 2)
        case .bottomRight: r = CGRect(x: v.minX + w / 2, y: v.minY, width: w / 2, height: h / 2)
        case .leftThird: r = CGRect(x: v.minX, y: v.minY, width: w / 3, height: h)
        case .centerThird: r = CGRect(x: v.minX + w / 3, y: v.minY, width: w / 3, height: h)
        case .rightThird: r = CGRect(x: v.minX + 2 * w / 3, y: v.minY, width: w / 3, height: h)
        case .leftTwoThirds: r = CGRect(x: v.minX, y: v.minY, width: 2 * w / 3, height: h)
        case .rightTwoThirds: r = CGRect(x: v.minX + w / 3, y: v.minY, width: 2 * w / 3, height: h)
        case .center:
            let size = CGSize(width: min(current.width, w), height: min(current.height, h))
            r = CGRect(x: v.midX - size.width / 2, y: v.midY - size.height / 2, width: size.width, height: size.height)
        }
        return r.integral
    }

    /// Pressing ←/→ again cycles ½ → ⅔ → ⅓ (like Windows / Rectangle).
    static func cycled(_ action: SnapAction, visible: CGRect, current: CGRect) -> SnapAction {
        let sequence: [SnapAction]
        switch action {
        case .leftHalf: sequence = [.leftHalf, .leftTwoThirds, .leftThird]
        case .rightHalf: sequence = [.rightHalf, .rightTwoThirds, .rightThird]
        default: return action
        }
        for (index, step) in sequence.enumerated() where approximatelyEqual(frame(for: step, visible: visible, current: current), current) {
            return sequence[(index + 1) % sequence.count]
        }
        return action
    }

    /// Which zone a window dragged to the screen edge snaps into (cursor in Cocoa coordinates).
    static func dragZone(cursor: CGPoint, screenFrame f: CGRect, visible v: CGRect) -> SnapAction? {
        let edge: CGFloat = 4
        let corner: CGFloat = 80
        if cursor.x <= f.minX + edge {
            if cursor.y >= v.maxY - corner { return .topLeft }
            if cursor.y <= v.minY + corner { return .bottomLeft }
            return .leftHalf
        }
        if cursor.x >= f.maxX - edge {
            if cursor.y >= v.maxY - corner { return .topRight }
            if cursor.y <= v.minY + corner { return .bottomRight }
            return .rightHalf
        }
        if cursor.y >= v.maxY - 2 { return .maximize }
        return nil
    }

    static func approximatelyEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 3) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}

/// Moves and resizes the frontmost window (Accessibility for other apps, AppKit for our own),
/// and snaps windows dragged to a screen edge. Shows a Liquid Glass preview of the target.
@MainActor
final class WindowSnapper {
    static let shared = WindowSnapper()

    private let preview = SnapPreview()
    private var history: [CGWindowID: CGRect] = [:]   // Quartz frames before snapping, for "Restore"
    private var ownHistory: [ObjectIdentifier: CGRect] = [:]

    // Drag snapping state.
    private struct DragCandidate {
        let windowID: CGWindowID
        let pid: pid_t
        let startBounds: CGRect
        let startMouse: CGPoint
    }
    private var candidate: DragCandidate?
    private var dragging = false
    private var dragZone: SnapAction?
    private var lastMoveCheck: CFTimeInterval = 0

    var dragSnappingEnabled = false

    // MARK: Shortcuts

    func registerShortcuts(modifiers: NSEvent.ModifierFlags) {
        HotKeyCenter.shared.unregisterAll(owner: "snap")
        for action in SnapKeys.ordered {
            guard let combo = SnapKeys.combo(action, modifiers: modifiers) else { continue }
            HotKeyCenter.shared.register(combo, owner: "snap") { [weak self] in self?.perform(action) }
        }
    }

    func unregisterShortcuts() {
        HotKeyCenter.shared.unregisterAll(owner: "snap")
    }

    // MARK: Performing a layout

    func perform(_ requested: SnapAction) {
        guard let h = ScreenGeometry.primaryHeight() else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier == getpid() {
            performOnOwnWindow(requested)
            return
        }
        guard AXIsProcessTrusted() else {
            logWarning("Arrange windows needs Accessibility")
            NSSound.beep()
            return
        }
        guard let (window, frameQuartz) = focusedWindow() else {
            logInfo("Arrange windows: no focused window")
            NSSound.beep()
            return
        }
        let cocoa = ScreenGeometry.cocoaRect(fromQuartz: frameQuartz, primaryHeight: h)
        guard let screen = screen(for: cocoa) else { return }
        let visible = screen.visibleFrame
        let windowID = AX.windowID(window)

        let target: CGRect
        if requested == .restore {
            guard let id = windowID, let previous = history[id] else {
                target = SnapLayout.frame(for: .center, visible: visible, current: cocoa)
                apply(window: window, cocoa: target, primaryHeight: h, screen: screen)
                return
            }
            history[id] = nil
            target = ScreenGeometry.cocoaRect(fromQuartz: previous, primaryHeight: h)
        } else {
            let action = SnapLayout.cycled(requested, visible: visible, current: cocoa)
            target = SnapLayout.frame(for: action, visible: visible, current: cocoa)
            if let id = windowID, history[id] == nil { history[id] = frameQuartz }
        }
        apply(window: window, cocoa: target, primaryHeight: h, screen: screen)
    }

    private func performOnOwnWindow(_ requested: SnapAction) {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible,
              let screen = window.screen ?? NSScreen.main else { NSSound.beep(); return }
        let key = ObjectIdentifier(window)
        let visible = screen.visibleFrame
        let target: CGRect
        if requested == .restore {
            target = ownHistory.removeValue(forKey: key) ?? SnapLayout.frame(for: .center, visible: visible, current: window.frame)
        } else {
            let action = SnapLayout.cycled(requested, visible: visible, current: window.frame)
            target = SnapLayout.frame(for: action, visible: visible, current: window.frame)
            if ownHistory[key] == nil { ownHistory[key] = window.frame }
        }
        preview.flash(target)
        window.setFrame(target, display: true, animate: true)
    }

    private func apply(window: AXUIElement, cocoa: CGRect, primaryHeight h: CGFloat, screen: NSScreen) {
        preview.flash(cocoa)
        let quartz = ScreenGeometry.quartzRect(fromCocoa: cocoa, primaryHeight: h)
        AX.setTimeout(window, seconds: 0.5)
        // Size, position, size again: the second size fixes windows that were clamped while
        // still at the old position (e.g. when moving to another display).
        let s1 = AX.setSize(window, quartz.size)
        let p = AX.setPosition(window, quartz.origin)
        let s2 = AX.setSize(window, quartz.size)
        if p != .success || (s1 != .success && s2 != .success) {
            logWarning("Arrange windows: could not move/resize (position \(AX.describe(p)), size \(AX.describe(s2)))")
        }
    }

    private func focusedWindow() -> (AXUIElement, CGRect)? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AX.setTimeout(element, seconds: 0.5)
        guard let window = AX.element(element, kAXFocusedWindowAttribute) ?? AX.element(element, kAXMainWindowAttribute),
              let frame = AX.frame(window) else { return nil }
        if AX.bool(window, "AXFullScreen") == true { return nil }
        return (window, frame)
    }

    private func screen(for cocoa: CGRect) -> NSScreen? {
        let screens = NSScreen.screens
        guard let best = ScreenGeometry.bestFrame(for: cocoa, in: screens.map(\.frame)) else { return NSScreen.main }
        return screens[best.index]
    }

    // MARK: Drag to the edge (fed by the event tap; must stay cheap)

    func mouseDown(at quartz: CGPoint) {
        candidate = nil
        dragging = false
        dragZone = nil
        guard dragSnappingEnabled, AXIsProcessTrusted(), let h = ScreenGeometry.primaryHeight() else { return }
        let cocoa = ScreenGeometry.cocoaPoint(fromQuartz: quartz, primaryHeight: h)
        guard let (id, info) = ClickInterceptor.windowUnderMouse(quartz: quartz, cocoa: cocoa),
              info.pid != getpid(), info.layer == 0,
              quartz.y - info.bounds.minY <= 40 else { return }   // only drags that start in the title bar
        candidate = DragCandidate(windowID: id, pid: info.pid, startBounds: info.bounds, startMouse: quartz)
    }

    func mouseDragged(to quartz: CGPoint) {
        guard let candidate, let h = ScreenGeometry.primaryHeight() else { return }
        if !dragging {
            guard hypot(quartz.x - candidate.startMouse.x, quartz.y - candidate.startMouse.y) > 8 else { return }
            let now = CACurrentMediaTime()
            guard now - lastMoveCheck > 0.05 else { return }
            lastMoveCheck = now
            // It only counts when the window really moves (not a text selection or a slider).
            guard let info = ClickInterceptor.windowInfo(candidate.windowID),
                  info.bounds.origin != candidate.startBounds.origin,
                  info.bounds.size == candidate.startBounds.size else { return }
            dragging = true
        }
        let cursor = ScreenGeometry.cocoaPoint(fromQuartz: quartz, primaryHeight: h)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) else { return }
        let zone = SnapLayout.dragZone(cursor: cursor, screenFrame: screen.frame, visible: screen.visibleFrame)
        guard zone != dragZone else { return }
        dragZone = zone
        if let zone {
            preview.show(SnapLayout.frame(for: zone, visible: screen.visibleFrame, current: .zero))
        } else {
            preview.hide()
        }
    }

    func mouseUp(at quartz: CGPoint) {
        defer {
            candidate = nil
            dragging = false
            dragZone = nil
        }
        guard dragging, let zone = dragZone, let candidate, let h = ScreenGeometry.primaryHeight() else {
            if dragZone != nil { preview.hide() }
            return
        }
        let cursor = ScreenGeometry.cocoaPoint(fromQuartz: quartz, primaryHeight: h)
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else {
            preview.hide()
            return
        }
        let target = SnapLayout.frame(for: zone, visible: screen.visibleFrame, current: .zero)
        // Let the window server finish the drag before we move the window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.preview.hide()
            let app = AXUIElementCreateApplication(candidate.pid)
            AX.setTimeout(app, seconds: 0.5)
            let windows = AX.children(app).filter { AX.string($0, kAXRoleAttribute) == kAXWindowRole }
            guard let window = windows.first(where: { AX.windowID($0) == candidate.windowID })
                    ?? AX.element(app, kAXFocusedWindowAttribute) else { return }
            if self.history[candidate.windowID] == nil {
                self.history[candidate.windowID] = candidate.startBounds
            }
            self.apply(window: window, cocoa: target, primaryHeight: h, screen: screen)
        }
    }
}

/// Liquid Glass rectangle that shows where a window will go.
@MainActor
final class SnapPreview {
    private var panel: GlassPanel?
    private var hideWork: DispatchWorkItem?

    private func makePanel() -> GlassPanel {
        let panel = GlassPanel(size: NSSize(width: 100, height: 100), canBecomeKey: false, level: .floating)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        panel.setContent(
            Color.clear
                .liquidGlass(cornerRadius: 22, tint: Color.accentColor.opacity(0.18))
                .padding(8)
        )
        return panel
    }

    func show(_ cocoaFrame: CGRect) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().setFrame(cocoaFrame, display: true)
            }
        } else {
            panel.setFrame(cocoaFrame, display: true)
            panel.fadeIn()
        }
    }

    func hide() {
        hideWork?.cancel()
        guard let panel, panel.isVisible else { return }
        panel.fadeOut()
    }

    /// Short confirmation after a keyboard shortcut.
    func flash(_ cocoaFrame: CGRect) {
        show(cocoaFrame)
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }
}
