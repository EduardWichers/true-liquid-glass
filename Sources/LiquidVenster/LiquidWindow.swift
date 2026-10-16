import AppKit

/// Window class for True Liquid Glass's own windows: minimizing (yellow button or ⌘M) plays
/// the water effect, closing (red button or ⌘W) lets the window evaporate. Works without
/// any permission.
final class LiquidWindow: NSWindow {
    var liquidEnabled = true
    private var bypassEffect = false

    override func miniaturize(_ sender: Any?) {
        if bypassEffect {
            super.miniaturize(sender)
            return
        }
        if let reason = reasonToSkipEffect(.minimize) {
            logInfo("\(title): minimizing normally (\(reason))")
            super.miniaturize(sender)
            return
        }
        if !MinimizeCoordinator.shared.submitOwn(self, action: .minimize) {
            logInfo("\(title): minimizing normally (effect unavailable)")
            super.miniaturize(sender)
        }
    }

    override func performClose(_ sender: Any?) {
        if bypassEffect {
            super.performClose(sender)
            return
        }
        // Respect a delegate that does not want the window to close, exactly like AppKit.
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        if let reason = reasonToSkipEffect(.close) {
            logInfo("\(title): closing normally (\(reason))")
            close()
            return
        }
        if !MinimizeCoordinator.shared.submitOwn(self, action: .close) {
            logInfo("\(title): closing normally (effect unavailable)")
            close()
        }
    }

    private func reasonToSkipEffect(_ action: WindowAction) -> String? {
        if !liquidEnabled { return "effect disabled for this window" }
        if isMiniaturized { return "already minimized" }
        if !isVisible { return "window not visible" }
        if inLiveResize { return "window is being resized" }
        if MinimizeCoordinator.reduceMotionActive { return "Reduce motion is on" }
        switch action {
        case .minimize:
            if !AppSettings.shared.minimizeEffectEnabled { return "water effect switched off" }
            if !styleMask.contains(.miniaturizable) { return "window cannot minimize" }
            if NSEvent.modifierFlags.contains(.option) { return "Option held: minimize all" }
        case .close:
            if !AppSettings.shared.closeEffectEnabled { return "evaporation switched off" }
            if NSEvent.modifierFlags.contains(.option) { return "Option held: close all" }
        }
        return nil
    }

    /// Minimize without the effect (used by the coordinator once the overlay covers us).
    func nativeMiniaturize() {
        guard !isMiniaturized else { return }
        bypassEffect = true
        super.miniaturize(nil)
        bypassEffect = false
    }

    /// Close without the effect (the delegate was already asked in `performClose`).
    func nativeClose() {
        guard isVisible || isMiniaturized else { return }
        close()
    }

    /// Center of the clicked button in Quartz coordinates: the ripple starts there.
    func buttonCenterQuartz(_ action: WindowAction, primaryHeight: CGFloat) -> CGPoint? {
        let kind: NSWindow.ButtonType = action == .minimize ? .miniaturizeButton : .closeButton
        guard let button = standardWindowButton(kind), let superview = button.superview else { return nil }
        let inWindow = superview.convert(button.frame, to: nil)
        let onScreen = convertToScreen(inWindow)
        return ScreenGeometry.quartzPoint(fromCocoa: CGPoint(x: onScreen.midX, y: onScreen.midY),
                                          primaryHeight: primaryHeight)
    }
}

/// Colourful content for the test windows, drawn with AppKit so snapshots are reliable.
final class DemoContentView: NSView {
    private let palette: Int

    init(palette: Int) {
        self.palette = palette
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    private static let palettes: [(NSColor, NSColor, NSColor)] = [
        (NSColor(srgbRed: 0.98, green: 0.62, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.91, green: 0.26, blue: 0.45, alpha: 1), NSColor(srgbRed: 1.0, green: 0.93, blue: 0.55, alpha: 1)),
        (NSColor(srgbRed: 0.27, green: 0.73, blue: 0.62, alpha: 1), NSColor(srgbRed: 0.18, green: 0.35, blue: 0.75, alpha: 1), NSColor(srgbRed: 0.75, green: 1.0, blue: 0.85, alpha: 1)),
        (NSColor(srgbRed: 0.62, green: 0.42, blue: 0.95, alpha: 1), NSColor(srgbRed: 0.95, green: 0.38, blue: 0.62, alpha: 1), NSColor(srgbRed: 1.0, green: 0.85, blue: 0.95, alpha: 1)),
    ]

    override func draw(_ dirtyRect: NSRect) {
        let (top, bottom, accent) = DemoContentView.palettes[(palette - 1 + 30) % DemoContentView.palettes.count]
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: 90)

        // A few soft circles so the liquid has some structure to carry along.
        for i in 0..<7 {
            let x = bounds.width * CGFloat((i * 37 + palette * 13) % 100) / 100
            let y = bounds.height * CGFloat((i * 53 + palette * 29) % 100) / 100
            let r = 30 + CGFloat((i * 17) % 60)
            accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
        }

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 4
        let title: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .heavy),
            .foregroundColor: NSColor.white,
            .shadow: shadow,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .shadow: shadow,
        ]
        let left: CGFloat = 32
        (AppInfo.name as NSString).draw(at: NSPoint(x: left, y: 64), withAttributes: title)
        let bodyRect = NSRect(x: left, y: 114, width: max(bounds.width - left * 2, 40), height: 90)
        (tr(.demoBody) as NSString).draw(with: bodyRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                         attributes: body)

        // Some fake UI so it looks like a real window.
        for row in 0..<4 {
            let rect = NSRect(x: left, y: 210 + CGFloat(row) * 34, width: bounds.width - left * 2, height: 24)
            NSColor.white.withAlphaComponent(row % 2 == 0 ? 0.30 : 0.18).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }
    }
}

@MainActor
enum DemoWindows {
    private static var windows: [(window: LiquidWindow, number: Int)] = []
    private static var counter = 0
    private static var closeObservers: [ObjectIdentifier: NSObjectProtocol] = [:]
    private static var languageObserver: NSObjectProtocol?

    @discardableResult
    static func open() -> LiquidWindow {
        observeLanguage()
        counter += 1
        let window = LiquidWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        window.title = tr(.testWindowTitle, counter)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 280, height: 200)
        window.contentView = DemoContentView(palette: counter)
        window.center()
        let offset = CGFloat((counter - 1) % 6) * 28
        window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        windows.append((window, counter))

        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                              object: window, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let closed = note.object as? LiquidWindow else { return }
                windows.removeAll { $0.window === closed }
                if let token = closeObservers.removeValue(forKey: ObjectIdentifier(closed)) {
                    NotificationCenter.default.removeObserver(token)
                }
            }
        }
        closeObservers[ObjectIdentifier(window)] = observer
        return window
    }

    /// Re-title and redraw open test windows when the language changes.
    private static func observeLanguage() {
        guard languageObserver == nil else { return }
        languageObserver = NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                for entry in windows {
                    entry.window.title = tr(.testWindowTitle, entry.number)
                    entry.window.contentView?.needsDisplay = true
                }
            }
        }
    }
}
