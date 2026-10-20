import AppKit
import Security

/// One line in the troubleshooting list.
struct DiagnosticItem: Identifiable {
    enum State: String {
        case ok = "OK"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
    }

    enum Fix: Hashable {
        case openAccessibility
        case openScreenCapture
        case resetPermissions
        case restart
        case showInFinder
        case enableSystemWide
        case ignoreReduceMotion
        case enableLoginItem
        case openLoginItems
        case quitApp(bundleID: String, name: String)
        case openDesktopSettings
    }

    let id: String
    let state: State
    let title: String
    let detail: String?
    var fixes: [Fix] = []
}

/// Checks the most common reasons why the effect does not work.
@MainActor
enum Diagnostics {
    struct Signature {
        let valid: Bool
        let adhoc: Bool
    }

    static func run(settings: AppSettings, status: AppStatus, copies: [String],
                    language: AppLanguage? = nil) -> [DiagnosticItem] {
        let l = Localizer.shared
        func t(_ key: L) -> String { l.string(key, in: language) }
        func f(_ key: L, _ args: CVarArg...) -> String { l.format(key, args, in: language) }
        var items: [DiagnosticItem] = []

        // macOS version (the app does not even start below 14).
        let v = ProcessInfo.processInfo.operatingSystemVersion
        items.append(DiagnosticItem(id: "macos", state: .ok,
                                    title: f(.diagMacOS, "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"),
                                    detail: t(.diagMacOSDetail)))

        // Where does the app run from?
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") {
            items.append(DiagnosticItem(id: "location", state: .error, title: t(.diagLocationTranslocated),
                                        detail: t(.diagLocationTranslocatedDetail), fixes: [.showInFinder]))
        } else if path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/") {
            items.append(DiagnosticItem(id: "location", state: .ok, title: t(.diagLocationOK), detail: nil))
        } else {
            items.append(DiagnosticItem(id: "location", state: .warning, title: t(.diagLocationOther),
                                        detail: f(.diagLocationOtherDetail, (path as NSString).abbreviatingWithTildeInPath),
                                        fixes: [.showInFinder]))
        }

        // Signature: decides whether permissions survive updates.
        if let signature = signature() {
            if !signature.valid {
                items.append(DiagnosticItem(id: "signature", state: .error, title: t(.diagSignatureInvalid),
                                            detail: t(.diagSignatureInvalidDetail)))
            } else if signature.adhoc {
                items.append(DiagnosticItem(id: "signature", state: .warning, title: t(.diagSignatureAdhoc),
                                            detail: t(.diagSignatureAdhocDetail)))
            } else {
                items.append(DiagnosticItem(id: "signature", state: .ok, title: t(.diagSignatureOK),
                                            detail: t(.diagSignatureOKDetail)))
            }
        }

        // Several copies can confuse permissions and launch an old version.
        if copies.count > 1 {
            items.append(DiagnosticItem(id: "copies", state: .warning, title: t(.diagCopiesMultiple),
                                        detail: f(.diagCopiesMultipleDetail,
                                                  copies.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: "\n")),
                                        fixes: [.showInFinder]))
        } else if copies.count == 1 {
            items.append(DiagnosticItem(id: "copies", state: .ok, title: t(.diagCopiesOne), detail: nil))
        }

        // Permissions.
        if status.accessibility {
            items.append(DiagnosticItem(id: "ax", state: .ok, title: t(.diagAXOK), detail: nil))
        } else {
            items.append(DiagnosticItem(id: "ax", state: .error, title: t(.diagAXMissing), detail: t(.diagAXMissingDetail),
                                        fixes: [.openAccessibility, .resetPermissions]))
        }
        if status.screenCapture {
            items.append(DiagnosticItem(id: "sc", state: .ok, title: t(.diagSCOK), detail: nil))
        } else {
            items.append(DiagnosticItem(id: "sc", state: .error, title: t(.diagSCMissing), detail: t(.diagSCMissingDetail),
                                        fixes: [.openScreenCapture, .restart]))
        }

        // Click recognition.
        if !settings.systemWideEnabled {
            items.append(DiagnosticItem(id: "tap", state: .warning, title: t(.diagTapOff), detail: t(.diagTapOffDetail),
                                        fixes: [.enableSystemWide]))
        } else if let error = status.interceptorError {
            items.append(DiagnosticItem(id: "tap", state: .error, title: t(.diagTapError),
                                        detail: error.reason(in: language), fixes: [.resetPermissions, .restart]))
        } else if status.interceptorRunning {
            items.append(DiagnosticItem(id: "tap", state: .ok, title: t(.diagTapOK), detail: nil))
        }

        // Graphics.
        switch LiquidRenderer.shared() {
        case .success(let renderer):
            items.append(DiagnosticItem(id: "gpu", state: .ok, title: f(.diagGPUOK, renderer.device.name), detail: nil))
        case .failure(let error):
            items.append(DiagnosticItem(id: "gpu", state: .error, title: t(.diagGPUError),
                                        detail: f(.diagGPUErrorDetail, error.liquidDescription)))
        }

        // Reduce motion.
        if status.reduceMotion && settings.respectReduceMotion {
            items.append(DiagnosticItem(id: "motion", state: .warning, title: t(.diagReduceMotion),
                                        detail: t(.diagReduceMotionDetail), fixes: [.ignoreReduceMotion]))
        }

        // Running as a service.
        switch status.loginItem {
        case .enabled:
            items.append(DiagnosticItem(id: "login", state: .ok, title: t(.diagLoginOK), detail: nil))
        case .requiresApproval:
            items.append(DiagnosticItem(id: "login", state: .warning, title: t(.diagLoginApproval),
                                        detail: t(.loginItemNeedsApproval), fixes: [.openLoginItems]))
        case .disabled, .unavailable:
            items.append(DiagnosticItem(id: "login", state: .info, title: t(.diagLoginOff),
                                        detail: t(.diagLoginOffDetail), fixes: [.enableLoginItem]))
        }

        // Where the water goes.
        if status.accessibility, let dock = DockLocator.items(), !dock.items.isEmpty {
            let edge: String
            switch DockLocator.preferences().edge {
            case .bottom: edge = t(.dockBottom)
            case .left: edge = t(.dockLeft)
            case .right: edge = t(.dockRight)
            }
            items.append(DiagnosticItem(id: "dock", state: .ok, title: f(.diagDockOK, edge), detail: nil))
        } else {
            items.append(DiagnosticItem(id: "dock", state: .info, title: t(.diagDockEstimated),
                                        detail: t(.diagDockEstimatedDetail)))
        }

        items.append(DiagnosticItem(id: "displays", state: .info, title: f(.diagDisplays, NSScreen.screens.count), detail: nil))

        // Tools: other apps with the same features, shortcuts that are taken, macOS tiling.
        for app in CompetingApp.runningConflicts(settings) {
            items.append(DiagnosticItem(id: "conflict-\(app.rawValue)", state: .warning, title: f(.diagConflict, app.name),
                                        detail: t(.diagConflictDetail),
                                        fixes: [.quitApp(bundleID: app.rawValue, name: app.name)]))
        }
        for (owner, combos) in status.toolShortcutFailures.sorted(by: { $0.key < $1.key }) where !combos.isEmpty {
            items.append(DiagnosticItem(id: "hotkey-\(owner)", state: .warning,
                                        title: f(.diagHotkeyFailed, combos.joined(separator: ", ")),
                                        detail: t(.diagHotkeyFailedDetail)))
        }
        if settings.snapEnabled && settings.snapDragEnabled && ToolsController.systemEdgeTilingEnabled {
            items.append(DiagnosticItem(id: "tiling", state: .warning, title: t(.diagSystemTiling),
                                        detail: t(.diagSystemTilingDetail), fixes: [.openDesktopSettings]))
        }

        let errors = AppLog.shared.entries.filter { $0.level == .error }.count
        if errors == 0 {
            items.append(DiagnosticItem(id: "errors", state: .ok, title: t(.diagErrorsNone), detail: nil))
        } else {
            items.append(DiagnosticItem(id: "errors", state: .warning, title: f(.diagErrorsSome, errors),
                                        detail: t(.diagErrorsSomeDetail)))
        }
        return items
    }

    /// Code signature of the running app; nil when not running from an .app bundle.
    static func signature() -> Signature? {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else { return nil }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess, let code = staticCode else {
            return nil
        }
        let valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        var info: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(code, flags, &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return Signature(valid: valid, adhoc: true)
        }
        let codeFlags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = codeFlags & SecCodeSignatureFlags.adhoc.rawValue != 0
        return Signature(valid: valid, adhoc: adhoc)
    }

    /// All installed copies (by bundle identifier), except those in the Trash and the
    /// build output of the source project.
    static func installedCopies() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        task.arguments = ["kMDItemCFBundleIdentifier == '\(AppInfo.bundleIdentifier)'"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            logWarning("mdfind failed: \(error.liquidDescription)")
            return [Bundle.main.bundlePath]
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let paths = String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .map(String.init)
            .filter { !$0.contains("/.Trash/") && !isBuildOutput($0) }
        return paths.isEmpty ? [Bundle.main.bundlePath] : paths
    }

    private static func isBuildOutput(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let buildDir = url.deletingLastPathComponent()
        guard buildDir.lastPathComponent == "build" else { return false }
        let project = buildDir.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: project.appendingPathComponent("Package.swift").path)
    }

    /// Plain-text report (always English) to paste into an e-mail or issue.
    static func report(settings: AppSettings, status: AppStatus, copies: [String]) -> String {
        var lines: [String] = []
        lines.append("\(AppInfo.name) \(AppInfo.version) – diagnostic report")
        lines.append("Date: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("Hardware: \(hardwareModel()) (\(machineArchitecture()))")
        lines.append("App path: \(Bundle.main.bundlePath)")
        lines.append("Language: \(Localizer.shared.language.rawValue) (system: \(Localizer.shared.systemLanguage.rawValue))")
        lines.append("Settings: systemWide=\(settings.systemWideEnabled) minimize=\(settings.minimizeEffectEnabled) "
                     + "close=\(settings.closeEffectEnabled) speed=\(settings.speed) strength=\(settings.colorStrength) "
                     + "reduceMotionRespected=\(settings.respectReduceMotion)")
        lines.append("Tools: snap=\(settings.snapEnabled) (\(settings.snapModifiers.display), drag=\(settings.snapDragEnabled)) "
                     + "launcher=\(settings.launcherEnabled) (\(settings.launcherHotkey.combo.display)) "
                     + "shelf=\(settings.shelfEnabled) (\(settings.shelfHotkey.combo.display), edge=\(settings.shelfEdgeReveal))")
        lines.append("")
        for item in run(settings: settings, status: status, copies: copies, language: .english) {
            lines.append("[\(item.state.rawValue)] \(item.title)" + (item.detail.map { " – \($0)" } ?? ""))
        }
        lines.append("")
        lines.append("Log:")
        lines.append(AppLog.shared.text)
        return lines.joined(separator: "\n")
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }

    private static func machineArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
