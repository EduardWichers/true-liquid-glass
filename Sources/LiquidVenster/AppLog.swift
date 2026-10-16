import Foundation
import os

/// Central log: writes to the unified system log (Console.app), keeps a small
/// in-memory history for the settings window and optionally echoes to stderr.
final class AppLog: ObservableObject {
    static let shared = AppLog()

    enum Level: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let level: Level
        let message: String

        private static let formatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss.SSS"
            return f
        }()

        var line: String { "\(Entry.formatter.string(from: date)) [\(level.rawValue)] \(message)" }
    }

    @Published private(set) var entries: [Entry] = []

    /// Echo every line to stderr (enabled with `--verbose`, `LIQUID_VERBOSE=1` or in self-test mode).
    var echoToStderr: Bool = ProcessInfo.processInfo.environment["LIQUID_VERBOSE"] != nil
        || CommandLine.arguments.contains("--verbose")

    private let osLog = Logger(subsystem: "nl.liquidvenster.app", category: "app")
    private var nextID = 0
    private let maxEntries = 400

    func log(_ level: Level, _ message: String) {
        switch level {
        case .debug: osLog.debug("\(message, privacy: .public)")
        case .info: osLog.info("\(message, privacy: .public)")
        case .warning: osLog.warning("\(message, privacy: .public)")
        case .error: osLog.error("\(message, privacy: .public)")
        }
        if echoToStderr || level == .error {
            let line = "[TrueLiquidGlass] [\(level.rawValue)] \(message)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
        // Debug lines only end up in the UI history when verbose logging is on.
        if level == .debug && !echoToStderr { return }

        let append = { [weak self] in
            guard let self else { return }
            self.entries.append(Entry(id: self.nextID, date: Date(), level: level, message: message))
            self.nextID += 1
            if self.entries.count > self.maxEntries {
                self.entries.removeFirst(self.entries.count - self.maxEntries)
            }
        }
        if Thread.isMainThread { append() } else { DispatchQueue.main.async(execute: append) }
    }

    func clear() {
        if Thread.isMainThread { entries.removeAll() } else { DispatchQueue.main.async { self.entries.removeAll() } }
    }

    var text: String { entries.map(\.line).joined(separator: "\n") }
}

func logDebug(_ message: @autoclosure () -> String) {
    guard AppLog.shared.echoToStderr else { return }
    AppLog.shared.log(.debug, message())
}
func logInfo(_ message: String) { AppLog.shared.log(.info, message) }
func logWarning(_ message: String) { AppLog.shared.log(.warning, message) }
func logError(_ message: String) { AppLog.shared.log(.error, message) }

extension Error {
    /// Human readable description that includes the domain/code for NSErrors.
    var liquidDescription: String {
        let ns = self as NSError
        if let localized = (self as? LocalizedError)?.errorDescription { return localized }
        return "\(ns.localizedDescription) (\(ns.domain) \(ns.code))"
    }
}
