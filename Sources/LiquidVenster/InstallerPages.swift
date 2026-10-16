import Foundation

/// Writes the welcome and conclusion pages of the installer package in all ten languages,
/// from the same translation tables as the app (`--installer-pages <folder>`).
enum InstallerPages {
    static func write(to directory: URL) throws {
        for language in AppLanguage.allCases {
            let folder = directory.appendingPathComponent("\(language.rawValue).lproj", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try welcome(language).write(to: folder.appendingPathComponent("welcome.html"), atomically: true, encoding: .utf8)
            try conclusion(language).write(to: folder.appendingPathComponent("conclusion.html"), atomically: true, encoding: .utf8)
        }
    }

    static func welcome(_ language: AppLanguage) -> String {
        func t(_ key: L) -> String { escape(Localizer.shared.string(key, in: language)) }
        let body = """
        <h1>\(escape(AppInfo.name))</h1>
        <p class="tag">\(t(.appTagline))</p>
        <p>\(t(.instWelcomeIntro))</p>
        <p><strong>\(t(.instRequirements))</strong></p>
        <h2>\(t(.instAfterTitle))</h2>
        <ul>
          <li>\(t(.instAfter1))</li>
          <li>\(t(.instAfter2))</li>
        </ul>
        <p class="note">\(t(.instPrivacy))</p>
        """
        return page(language: language, body: body)
    }

    static func conclusion(_ language: AppLanguage) -> String {
        func t(_ key: L) -> String { escape(Localizer.shared.string(key, in: language)) }
        let body = """
        <h1>\(t(.instDoneTitle))</h1>
        <ol>
          <li>\(t(.instDone1))</li>
          <li>\(t(.instDone2))</li>
          <li>\(t(.instDone3))</li>
        </ol>
        <p class="note">\(t(.instDoneHelp))</p>
        """
        return page(language: language, body: body)
    }

    private static func page(language: AppLanguage, body: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(language.rawValue)">
        <head>
        <meta charset="utf-8">
        <style>
          :root { color-scheme: light dark; }
          body { font: 13px -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; line-height: 1.45; margin: 16px 20px; }
          h1 { font-size: 20px; margin: 0 0 4px; }
          h2 { font-size: 14px; margin: 18px 0 6px; }
          .tag { color: #6b7280; margin: 0 0 14px; }
          ul, ol { padding-left: 20px; margin: 6px 0; }
          li { margin: 5px 0; }
          .note { margin-top: 18px; padding: 10px 12px; border-radius: 8px; background: rgba(0, 122, 255, 0.08); }
          @media (prefers-color-scheme: dark) {
            .tag { color: #9ca3af; }
            .note { background: rgba(10, 132, 255, 0.18); }
          }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
