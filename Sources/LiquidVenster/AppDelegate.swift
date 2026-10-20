import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings.shared
    let status = AppStatus()
    private let interceptor = ClickInterceptor()
    private let arguments: [String]

    private(set) var settingsWindow: LiquidWindow?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    private var lastLoggedState: String?
    private var lastInterceptorFailure: CFTimeInterval = 0
    private var askedAccessibility = false
    private var askedScreenCapture = false
    private var launchedAsLoginItem = false

    init(arguments: [String]) {
        self.arguments = arguments
        super.init()
    }

    // MARK: Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Only available while launching: was the app started by "open at login"?
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == kAEOpenApplication,
           event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem {
            launchedAsLoginItem = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if quitIfAlreadyRunning() { return }
        logInfo("\(AppInfo.name) \(AppInfo.version) started (macOS \(ProcessInfo.processInfo.operatingSystemVersionString), language \(Localizer.shared.language.rawValue))")

        buildMainMenu()
        buildStatusItem()

        // Compile the shaders in the background so the first click is instant.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = LiquidRenderer.shared()
            DispatchQueue.main.async {
                if case .failure(let error) = result { self.status.rendererError = error.liquidDescription }
            }
        }

        interceptor.shouldIntercept = { [weak self] action in
            guard let self else { return false }
            let effectOn = action == .minimize ? self.settings.minimizeEffectEnabled : self.settings.closeEffectEnabled
            return effectOn && self.settings.systemWideEnabled && self.status.screenCapture && self.status.rendererError == nil
                && !(self.status.reduceMotion && self.settings.respectReduceMotion)
        }
        interceptor.onButtonClick = { request in
            MinimizeCoordinator.shared.submitExternal(request)
        }

        settings.$systemWideEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        settings.$respectReduceMotion.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)

        // Menus follow the language chosen in the app.
        NotificationCenter.default.addObserver(forName: .appLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                logInfo("Language changed to \(Localizer.shared.language.rawValue)")
                self?.buildMainMenu()
                self?.updateStatusMenu()
            }
        }
        // Accessibility permission changes are broadcast; Screen Recording is polled.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        LoginItem.enableOnFirstLaunchIfInstalled()
        // Window arranging, launcher and file shelf.
        interceptor.onPassiveMouse = { type, location in
            switch type {
            case .leftMouseDown: WindowSnapper.shared.mouseDown(at: location)
            case .leftMouseDragged: WindowSnapper.shared.mouseDragged(to: location)
            case .leftMouseUp: WindowSnapper.shared.mouseUp(at: location)
            default: break
            }
        }
        ToolsController.shared.openSettings = { [weak self] in self?.showSettings() }
        ToolsController.shared.start(settings: settings, status: status)
        settings.objectWillChange
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.updateStatusMenu() } }
            .store(in: &cancellables)
        settings.$snapDragEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        settings.$snapEnabled.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        refresh()

        if let index = arguments.firstIndex(of: "--make-screenshots") {
            // `--make-screenshots <folder> [--language xx]`: images for the README.
            let folder = index + 1 < arguments.count ? arguments[index + 1] : "screenshots"
            if let languageIndex = arguments.firstIndex(of: "--language"), languageIndex + 1 < arguments.count,
               let language = AppLanguage(rawValue: arguments[languageIndex + 1]) {
                Localizer.shared.useForThisSession(language)
            }
            Task { @MainActor in
                let ok = await ScreenshotMaker.run(outputDirectory: URL(fileURLWithPath: folder, isDirectory: true), delegate: self)
                self.interceptor.stop()
                exit(ok ? 0 : 1)
            }
        } else if arguments.contains("--tools-demo") {
            runToolsDemo()
        } else if let index = arguments.firstIndex(of: "--demo") {
            let cycles = (index + 1 < arguments.count ? Int(arguments[index + 1]) : nil) ?? 2
            runDemo(cycles: max(1, min(cycles, 20)), quitAfterwards: arguments.contains("--quit-after"))
        } else if launchedAsLoginItem && status.isFullyConfigured {
            // Running as a service: stay quietly in the background.
            logInfo("Started at login; running in the background")
        } else {
            showSettings()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showSettings() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        interceptor.stop()
    }

    /// Two copies would both intercept clicks; keep the first one.
    private func quitIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0.processIdentifier != getpid() }
        guard let other = others.first else { return false }
        logWarning("\(AppInfo.name) is already running (pid \(other.processIdentifier)); this copy quits")
        other.activate()
        DispatchQueue.main.async { NSApp.terminate(nil) }
        return true
    }

    // MARK: State

    private func refresh() {
        let accessibility = Permissions.accessibilityGranted
        let screenCapture = Permissions.screenCaptureGranted
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if status.accessibility != accessibility { status.accessibility = accessibility }
        if status.screenCapture != screenCapture { status.screenCapture = screenCapture }
        if status.reduceMotion != reduceMotion { status.reduceMotion = reduceMotion }
        let loginItem = LoginItem.state
        if status.loginItem != loginItem { status.loginItem = loginItem }

        // The event tap serves the button effects and snapping windows dragged to a screen edge.
        let wantTap = accessibility && (settings.systemWideEnabled || (settings.snapEnabled && settings.snapDragEnabled))
        if wantTap {
            if !interceptor.isRunning {
                // Don't hammer tapCreate every 1.5 s when it keeps failing.
                if CACurrentMediaTime() - lastInterceptorFailure > 10 || status.interceptorError == nil {
                    do {
                        try interceptor.start()
                        status.interceptorError = nil
                    } catch {
                        lastInterceptorFailure = CACurrentMediaTime()
                        let failure = (error as? InterceptorError) ?? .tapCreationFailed
                        if status.interceptorError != failure { logError(error.liquidDescription) }
                        status.interceptorError = failure
                    }
                }
            } else if !interceptor.ensureHealthy() {
                logWarning("Event tap not responding; recreating it")
                interceptor.stop()
                try? interceptor.start()
            }
        } else if interceptor.isRunning {
            interceptor.stop()
        }
        if !wantTap && status.interceptorError != nil { status.interceptorError = nil }
        if status.interceptorRunning != interceptor.isRunning { status.interceptorRunning = interceptor.isRunning }

        // The log is always English; the menu follows the app language.
        let english = status.summary(settings: settings, language: .english)
        if english.text != lastLoggedState {
            lastLoggedState = english.text
            if english.isProblem { logWarning(english.text) } else { logInfo(english.text) }
            updateStatusMenu()
        }
    }

    // MARK: Windows

    @objc func showSettings() {
        presentSettings(tab: nil)
    }

    @objc func showTroubleshooting() {
        presentSettings(tab: .troubleshooting)
    }

    func presentSettings(tab: SettingsTab?) {
        if settingsWindow == nil {
            let window = LiquidWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 740),
                                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                      backing: .buffered, defer: false)
            window.title = AppInfo.name
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 520, height: 520)
            window.contentView = NSHostingView(rootView: SettingsView(settings: settings, status: status,
                                                                      log: AppLog.shared, localizer: Localizer.shared,
                                                                      actions: makeActions()))
            window.setContentSize(NSSize(width: 560, height: 740))
            window.center()
            window.setFrameAutosaveName("LiquidVensterSettings")
            settingsWindow = window
        }
        if let tab { status.selectedTab = tab }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func makeActions() -> SettingsActions {
        SettingsActions(
            openDemo: { [weak self] in self?.openDemo() },
            testEffect: { [weak self] in self?.testEffect() },
            requestAccessibility: { [weak self] in self?.requestAccessibility() },
            requestScreenCapture: { [weak self] in self?.requestScreenCapture() },
            openAccessibilitySettings: { Permissions.openAccessibilitySettings() },
            openScreenCaptureSettings: { Permissions.openScreenCaptureSettings() },
            resetPermissions: { [weak self] in self?.resetPermissions() },
            relaunch: { [weak self] in self?.relaunch() },
            showInFinder: { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) },
            refresh: { [weak self] in self?.refresh() })
    }

    /// First click shows the system prompt; later clicks go straight to System Settings
    /// (macOS only shows each prompt once).
    private func requestAccessibility() {
        if askedAccessibility {
            Permissions.openAccessibilitySettings()
        } else {
            Permissions.requestAccessibility()
        }
        askedAccessibility = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    private func requestScreenCapture() {
        if askedScreenCapture {
            Permissions.openScreenCaptureSettings()
        } else if !Permissions.requestScreenCapture() {
            logInfo("Screen Recording requested; enable \(AppInfo.name) and restart the app")
        }
        askedScreenCapture = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.refresh() }
    }

    /// Removes this app's own Accessibility and Screen Recording entries (fixes entries
    /// that belong to an older build), after the user confirmed.
    private func resetPermissions() {
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = tr(.resetTitle)
        confirm.informativeText = tr(.resetMessage)
        confirm.addButton(withTitle: tr(.resetConfirm))
        confirm.addButton(withTitle: tr(.cancel))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        interceptor.stop()
        let results = ["Accessibility", "ScreenCapture"].map { Permissions.resetWithTccutil(service: $0) }
        let success = results.allSatisfy { $0 }
        askedAccessibility = false
        askedScreenCapture = false
        refresh()

        let done = NSAlert()
        done.alertStyle = success ? .informational : .warning
        done.messageText = success ? tr(.resetDone) : tr(.resetFailed)
        done.addButton(withTitle: "OK")
        done.runModal()
        if success {
            requestAccessibility()
        } else {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc func showAbout() {
        let credits = NSMutableAttributedString(string: tr(.creditsMadeBy, AppInfo.author),
                                                attributes: [.font: NSFont.systemFont(ofSize: 11),
                                                             .foregroundColor: NSColor.secondaryLabelColor])
        if let url = AppInfo.authorURL {
            credits.append(NSAttributedString(string: "\n"))
            credits.append(NSAttributedString(string: url.absoluteString,
                                              attributes: [.link: url, .font: NSFont.systemFont(ofSize: 11)]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppInfo.name, .credits: credits])
    }

    @objc func openDemo() {
        DemoWindows.open()
    }

    @objc func testEffect() {
        let window = DemoWindows.open()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak window] in
            window?.miniaturize(nil)
        }
    }

    @objc func openLauncher() { Launcher.shared.show() }

    @objc func openShelf() { FileShelf.shared.show(near: nil) }

    @objc func toggleSystemWide() {
        settings.systemWideEnabled.toggle()
    }

    @objc func relaunch() {
        let path = Bundle.main.bundlePath
        guard path.hasSuffix(".app") else {
            logWarning("Restart only works when \(AppInfo.name) runs as an .app bundle")
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", path]
        do {
            try task.run()
            NSApp.terminate(nil)
        } catch {
            logError("Restart failed: \(error.liquidDescription)")
        }
    }

    // MARK: Menus

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: AppInfo.name)
        let about = appMenu.addItem(withTitle: tr(.menuAbout), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(.separator())
        let prefs = appMenu.addItem(withTitle: tr(.menuSettings), action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        let help = appMenu.addItem(withTitle: tr(.menuTroubleshooting), action: #selector(showTroubleshooting), keyEquivalent: "")
        help.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr(.menuHide), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: tr(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: tr(.menuEdit))
        editMenu.addItem(withTitle: tr(.menuCopy), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: tr(.menuSelectAll), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: tr(.menuWindow))
        windowMenu.addItem(withTitle: tr(.menuMinimize), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: tr(.menuZoom), action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        let demo = windowMenu.addItem(withTitle: tr(.menuNewTestWindow), action: #selector(openDemo), keyEquivalent: "n")
        demo.target = self
        windowMenu.addItem(withTitle: tr(.menuCloseWindow), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: AppInfo.name) {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "💧"
        }
        item.button?.toolTip = AppInfo.name
        statusItem = item
        updateStatusMenu()
    }

    private func updateStatusMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()
        let summary = status.summary(settings: settings)
        let state = NSMenuItem(title: summary.text, action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: tr(.menuEffectAllApps), action: #selector(toggleSystemWide), keyEquivalent: "")
        toggle.target = self
        toggle.state = settings.systemWideEnabled ? .on : .off
        menu.addItem(toggle)
        let demo = NSMenuItem(title: tr(.menuPlayEffect), action: #selector(testEffect), keyEquivalent: "")
        demo.target = self
        menu.addItem(demo)
        let prefs = NSMenuItem(title: tr(.menuSettings), action: #selector(showSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        let help = NSMenuItem(title: tr(.menuTroubleshooting), action: #selector(showTroubleshooting), keyEquivalent: "")
        help.target = self
        menu.addItem(help)
        menu.addItem(.separator())
        if settings.launcherEnabled {
            let launcher = NSMenuItem(title: "\(tr(.menuLauncher))   \(settings.launcherHotkey.combo.display)",
                                      action: #selector(openLauncher), keyEquivalent: "")
            launcher.target = self
            menu.addItem(launcher)
        }
        if settings.shelfEnabled {
            let shelf = NSMenuItem(title: "\(tr(.menuShelf))   \(settings.shelfHotkey.combo.display)",
                                   action: #selector(openShelf), keyEquivalent: "")
            shelf.target = self
            menu.addItem(shelf)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: tr(.menuQuit), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    // MARK: Demo / automated check

    /// `--tools-demo`: arranges a test window with the shortcuts' actions and opens/closes the
    /// launcher and shelf; exits with 0 when everything behaved.
    private func runToolsDemo() {
        Task { @MainActor in
            var failures = 0
            let window = DemoWindows.open()
            NSApp.activate()
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { exit(2) }
            // Only while this app is frontmost: otherwise the snapper would act on the user's own window.
            func weAreFrontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() }
            if weAreFrontmost() {
                for (action, expected) in [(SnapAction.leftHalf, SnapLayout.frame(for: .leftHalf, visible: visible, current: window.frame)),
                                           (.leftHalf, SnapLayout.frame(for: .leftTwoThirds, visible: visible, current: window.frame)),
                                           (.topRight, SnapLayout.frame(for: .topRight, visible: visible, current: window.frame)),
                                           (.maximize, visible.integral)] {
                    window.makeKeyAndOrderFront(nil)
                    guard weAreFrontmost() else { logWarning("Tools demo: another app came to the front; stopped arranging"); break }
                    WindowSnapper.shared.perform(action)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let ok = SnapLayout.approximatelyEqual(window.frame, expected, tolerance: 4)
                    logInfo("Tools demo: \(action.rawValue) → \(ok ? "OK" : "FAILED (\(window.frame) ≠ \(expected))")")
                    if !ok { failures += 1 }
                }
                if weAreFrontmost() { WindowSnapper.shared.perform(.restore) }
                try? await Task.sleep(nanoseconds: 700_000_000)
                logInfo("Tools demo: restore → \(window.frame)")
            } else {
                logWarning("Tools demo: could not come to the front (another app is in use); arranging own window skipped")
            }
            window.close()

            // Another app's window (via Accessibility): a Finder window we open ourselves.
            if AXIsProcessTrusted(), let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first {
                let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("TLG snap test", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(folder)
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                finder.activate()
                try? await Task.sleep(nanoseconds: 600_000_000)
                let app = AXUIElementCreateApplication(finder.processIdentifier)
                if let finderWindow = AX.element(app, kAXFocusedWindowAttribute), AX.string(finderWindow, kAXTitleAttribute) == "TLG snap test",
                   let h = ScreenGeometry.primaryHeight(), let screen = NSScreen.main {
                    WindowSnapper.shared.perform(.rightHalf)
                    try? await Task.sleep(nanoseconds: 700_000_000)
                    let expected = ScreenGeometry.quartzRect(fromCocoa: SnapLayout.frame(for: .rightHalf, visible: screen.visibleFrame, current: .zero), primaryHeight: h)
                    let actual = AX.frame(finderWindow) ?? .zero
                    let ok = SnapLayout.approximatelyEqual(actual, expected, tolerance: 6)
                    logInfo("Tools demo: Finder window rightHalf → \(ok ? "OK" : "FAILED (\(actual) ≠ \(expected))")")
                    if !ok { failures += 1 }
                    WindowSnapper.shared.perform(.restore)
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    if let close = AX.element(finderWindow, kAXCloseButtonAttribute) { AX.press(close) }
                } else {
                    logWarning("Tools demo: test Finder window not focused; skipped")
                    // Close our test window anyway.
                    for candidate in AX.children(app) where AX.string(candidate, kAXTitleAttribute) == "TLG snap test" {
                        if let close = AX.element(candidate, kAXCloseButtonAttribute) { AX.press(close) }
                    }
                }
                try? FileManager.default.removeItem(at: folder)
            }
            Launcher.shared.show()
            try? await Task.sleep(nanoseconds: 500_000_000)
            Launcher.shared.model.query = "2+3*4"
            try? await Task.sleep(nanoseconds: 300_000_000)
            let calc = Launcher.shared.model.results.first?.title ?? "-"
            if calc != "= 14" { failures += 1 }
            logInfo("Tools demo: launcher shows \(calc) for 2+3*4")
            // Keyboard: ↓ to the Google row, ⌥↩ searches Google (captured here, no browser is opened).
            var googled: URL?
            Launcher.shared.model.openURL = { googled = $0 }
            Launcher.shared.postTestKey(kVK_DownArrow)
            try? await Task.sleep(nanoseconds: 300_000_000)
            let model = Launcher.shared.model
            let onGoogleRow = model.results.indices.contains(model.selection) && model.results[model.selection].isWeb
            Launcher.shared.postTestKey(kVK_Return, modifiers: .option)
            for _ in 0..<20 where Launcher.shared.isVisible || googled == nil {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let googleOK = googled?.absoluteString == "https://www.google.com/search?q=2%2B3%2A4" && !Launcher.shared.isVisible
            if !onGoogleRow || !googleOK { failures += 1 }
            logInfo("Tools demo: ↓ selects the Google row \(onGoogleRow ? "OK" : "FAILED"), ⌥↩ → \(googled?.absoluteString ?? "nothing") \(googleOK ? "OK" : "FAILED")")
            Launcher.shared.hide()
            let launcherShortcut = settings.launcherHotkey.combo
            let registered = HotKeyCenter.shared.registeredCombos(owner: "launcher").contains(launcherShortcut)
            let reservedBy = status.systemShortcuts[launcherShortcut].map { "\($0)" } ?? "none"
            logInfo("Tools demo: launcher shortcut \(launcherShortcut.display) registered=\(registered), macOS clash=\(reservedBy)")
            FileShelf.shared.show(near: nil)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !FileShelf.shared.isVisible { failures += 1 }
            FileShelf.shared.hide()
            logInfo("Tools demo finished: \(failures == 0 ? "all OK" : "\(failures) failure(s)")")
            exit(failures == 0 ? 0 : 2)
        }
    }

    /// `--demo [n] [--quit-after]`: minimizes a test window n times and verifies the result.
    private func runDemo(cycles: Int, quitAfterwards: Bool) {
        Task { @MainActor in
            let window = DemoWindows.open()
            var failures = 0
            for round in 1...cycles {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                logInfo("Demo \(round)/\(cycles): minimizing \(window.title)")
                let started = CACurrentMediaTime()
                window.miniaturize(nil)
                let deadline = started + 1.5 / settings.speed + 3.0
                while CACurrentMediaTime() < deadline {
                    if window.isMiniaturized && !MinimizeCoordinator.shared.isAnimating { break }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }
                let ok = window.isMiniaturized && window.alphaValue == 1 && !MinimizeCoordinator.shared.isAnimating
                if ok {
                    logInfo(String(format: "Demo: OK – minimized after %.2f s", CACurrentMediaTime() - started))
                } else {
                    failures += 1
                    logError("Demo: FAILED – isMiniaturized=\(window.isMiniaturized) alpha=\(window.alphaValue)")
                }
                window.deminiaturize(nil)
                try? await Task.sleep(nanoseconds: 800_000_000)
                if window.isMiniaturized || !window.isVisible {
                    failures += 1
                    logError("Demo: FAILED – window did not come back from the Dock")
                }
            }
            // Red button: the window must evaporate and really be closed afterwards.
            window.close()
            let closing = DemoWindows.open()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            logInfo("Demo close: closing \(closing.title)")
            let closeStarted = CACurrentMediaTime()
            closing.performClose(nil)
            let closeDeadline = closeStarted + 1.8 / settings.speed + 3.0
            while CACurrentMediaTime() < closeDeadline {
                if !closing.isVisible && !MinimizeCoordinator.shared.isAnimating { break }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            if !closing.isVisible && closing.alphaValue == 1 && !MinimizeCoordinator.shared.isAnimating {
                logInfo(String(format: "Demo close: OK – closed after %.2f s", CACurrentMediaTime() - closeStarted))
            } else {
                failures += 1
                logError("Demo close: FAILED – visible=\(closing.isVisible) alpha=\(closing.alphaValue)")
            }
            logInfo("Demo finished: \(cycles + 1 - failures)/\(cycles + 1) succeeded")
            if quitAfterwards {
                interceptor.stop()
                exit(failures == 0 ? 0 : 2)
            }
        }
    }
}
