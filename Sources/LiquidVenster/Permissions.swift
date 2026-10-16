import AppKit
import ApplicationServices
import CoreGraphics

/// TCC permissions the system-wide mode needs.
///  - Accessibility: to intercept clicks (active event tap) and talk to other apps' windows.
///  - Screen Recording: to take a snapshot of the window and the screen behind it.
enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt (only once per app version) and returns the current state.
    @discardableResult
    static func requestAccessibility() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func requestScreenCapture() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openScreenCaptureSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    /// Removes this app's own entry for a TCC service ("Accessibility", "ScreenCapture").
    /// Only called after the user confirmed it in the troubleshooting tab.
    static func resetWithTccutil(service: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, AppInfo.bundleIdentifier]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do {
            try task.run()
        } catch {
            logError("tccutil could not start: \(error.liquidDescription)")
            return false
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        task.waitUntilExit()
        let ok = task.terminationStatus == 0
        let message = "tccutil reset \(service): exit \(task.terminationStatus)\(output.isEmpty ? "" : " – \(output)")"
        if ok { logInfo(message) } else { logError(message) }
        return ok
    }

    private static func open(_ string: String) {
        guard let url = URL(string: string) else {
            logError("Invalid settings URL: \(string)")
            return
        }
        if !NSWorkspace.shared.open(url) {
            logError("Could not open System Settings (\(string))")
        }
    }
}
