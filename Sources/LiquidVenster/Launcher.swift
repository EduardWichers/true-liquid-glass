import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Search building blocks (pure, testable)

/// Scores how well `query` matches `candidate`: higher is better, nil = no match.
/// Prefix > start of a word > initials ("vsc" → "Visual Studio Code") > anywhere > in order.
enum FuzzyMatcher {
    static func score(query rawQuery: String, candidate rawCandidate: String) -> Double? {
        let query = normalize(rawQuery)
        let candidate = normalize(rawCandidate)
        guard !query.isEmpty, !candidate.isEmpty else { return nil }
        if candidate == query { return 1000 }
        if candidate.hasPrefix(query) { return 800 - Double(candidate.count - query.count) }
        let words = candidate.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if words.contains(where: { $0.hasPrefix(query) }) { return 600 - Double(candidate.count - query.count) }
        let initials = String(words.compactMap(\.first))
        if initials.hasPrefix(query) { return 500 - Double(initials.count - query.count) }
        if candidate.contains(query) { return 300 - Double(candidate.count - query.count) }
        // Characters in the right order ("sfr" → "Safari").
        var index = candidate.startIndex
        for character in query {
            guard let found = candidate[index...].firstIndex(of: character) else { return nil }
            index = candidate.index(after: found)
        }
        return 100 - Double(candidate.count)
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Small, safe calculator (no NSExpression: that can crash on bad input).
/// Supports + − × ÷ ^ %, parentheses, decimals with . or , and unary minus.
enum Calculator {
    static func evaluate(_ input: String) -> Double? {
        let text = input.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: " ", with: "")
        guard !text.isEmpty, text.count <= 200,
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789.+-*/^%()").inverted) == nil,
              text.rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/^%")) != nil
                || text.contains("(") else { return nil }
        var parser = Parser(Array(text))
        guard let value = parser.expression(), parser.atEnd, value.isFinite else { return nil }
        return value
    }

    static func format(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 10
        formatter.usesGroupingSeparator = abs(value) >= 10_000
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private struct Parser {
        let chars: [Character]
        var index = 0
        var depth = 0
        init(_ chars: [Character]) { self.chars = chars }
        var atEnd: Bool { index == chars.count }

        mutating func peek() -> Character? { index < chars.count ? chars[index] : nil }

        mutating func expression() -> Double? {
            guard var value = term() else { return nil }
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                guard let rhs = term() else { return nil }
                value = op == "+" ? value + rhs : value - rhs
            }
            return value
        }

        mutating func term() -> Double? {
            guard var value = power() else { return nil }
            while let op = peek(), op == "*" || op == "/" || op == "%" {
                index += 1
                if op == "%" {
                    // "50%" alone means 0.5; "a % b" is the remainder.
                    if let next = peek(), next.isNumber || next == "(" || next == "." {
                        guard let rhs = power(), rhs != 0 else { return nil }
                        value = value.truncatingRemainder(dividingBy: rhs)
                    } else {
                        value /= 100
                    }
                    continue
                }
                guard let rhs = power() else { return nil }
                if op == "/" { guard rhs != 0 else { return nil } }
                value = op == "*" ? value * rhs : value / rhs
            }
            return value
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if peek() == "^" {
                index += 1
                guard let exponent = power() else { return nil }   // right associative
                return pow(base, exponent)
            }
            return base
        }

        mutating func unary() -> Double? {
            if peek() == "-" { index += 1; return unary().map { -$0 } }
            if peek() == "+" { index += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            if peek() == "(" {
                depth += 1
                guard depth < 40 else { return nil }
                index += 1
                guard let value = expression(), peek() == ")" else { return nil }
                index += 1
                depth -= 1
                return value
            }
            let start = index
            while let c = peek(), c.isNumber || c == "." { index += 1 }
            guard index > start else { return nil }
            return Double(String(chars[start..<index]))
        }
    }
}

// MARK: - Results

struct LauncherItem: Identifiable {
    enum Kind {
        case app(URL)
        case file(URL)
        case calculation(String)
        case web(String)
        case command(() -> Void)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let score: Double

    var isWeb: Bool {
        if case .web = kind { return true }
        return false
    }
}

/// Searching Google: the query only leaves the Mac when the user picks the Google row.
enum WebSearch {
    /// "https://www.google.com/search?q=…", with everything except unreserved ASCII percent-encoded
    /// (so "c++" stays "c++" instead of becoming "c  ").
    static func googleURL(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !trimmed.isEmpty, trimmed.count <= 2000,
              let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        return URL(string: "https://www.google.com/search?q=" + encoded)
    }

    /// "g weather" or "google weather" searches Google straight away; returns the search text.
    static func prefixedQuery(_ text: String) -> String? {
        for prefix in ["g ", "google "] where text.lowercased().hasPrefix(prefix) {
            let rest = text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        return nil
    }
}

/// Index of installed applications, refreshed in the background.
final class AppIndex {
    struct Entry {
        let name: String
        let url: URL
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var lastRefresh: Date = .distantPast

    var all: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }

    func refreshIfNeeded() {
        guard Date().timeIntervalSince(lastRefresh) > 60 else { return }
        lastRefresh = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = AppIndex.scan()
            self?.lock.lock()
            self?.entries = found
            self?.lock.unlock()
            logDebug("Launcher: \(found.count) apps indexed")
        }
    }

    static func scan() -> [Entry] {
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        var seen = Set<String>()
        var result: [Entry] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for item in items {
                let path = (root as NSString).appendingPathComponent(item)
                if item.hasSuffix(".app") {
                    let name = (fm.displayName(atPath: path) as NSString).deletingPathExtension
                    if seen.insert(name.lowercased()).inserted {
                        result.append(Entry(name: name, url: URL(fileURLWithPath: path)))
                    }
                } else if !item.hasPrefix("."),
                          let sub = try? fm.contentsOfDirectory(atPath: path) {   // e.g. /Applications/Microsoft Office
                    for child in sub where child.hasSuffix(".app") {
                        let childPath = (path as NSString).appendingPathComponent(child)
                        let name = (fm.displayName(atPath: childPath) as NSString).deletingPathExtension
                        if seen.insert(name.lowercased()).inserted {
                            result.append(Entry(name: name, url: URL(fileURLWithPath: childPath)))
                        }
                    }
                }
            }
        }
        return result
    }
}

/// Searches the user's files with Spotlight (only when the query is long enough).
@MainActor
final class FileSearch {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?

    func search(_ text: String, completion: @escaping ([URL]) -> Void) {
        stop()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { completion([]); return }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(trimmed)*")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                          object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                var scored: [(URL, Double)] = []
                for case let item as NSMetadataItem in query.results {
                    guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          !FileSearch.isNoise(path) else { continue }
                    let url = URL(fileURLWithPath: path)
                    guard let score = FuzzyMatcher.score(query: text, candidate: url.lastPathComponent) else { continue }
                    scored.append((url, score))
                    if scored.count >= 200 { break }
                }
                // Best name match first; Spotlight already ordered by recent change for ties.
                let urls = scored.enumerated()
                    .sorted { ($0.element.1, -$0.offset) > ($1.element.1, -$1.offset) }
                    .prefix(12).map(\.element.0)
                self.stop()
                completion(urls)
            }
        }
        self.query = query
        if !query.start() {
            logWarning("Launcher: Spotlight search could not start")
            stop()
            completion([])
        }
    }

    /// Developer folders, library internals and generated files are not what people look for.
    nonisolated static func isNoise(_ path: String) -> Bool {
        let blocked = ["/Library/", "/node_modules/", "/.git/", "/.build/", "/build/", "/DerivedData/", "/Pods/",
                       "/vendor/", "/.Trash/", ".app/", ".lrlibrary/", ".photoslibrary/", ".xcodeproj/", ".bundle/",
                       ".framework/", "/site-packages/", "/__pycache__/"]
        if path.hasSuffix(".app") || path.contains("/.") || blocked.contains(where: path.contains) { return true }
        let name = (path as NSString).lastPathComponent
        // Hash-like names (previews, caches): long, no spaces, digits and letters mixed.
        let stem = (name as NSString).deletingPathExtension
        if stem.count > 28 && !stem.contains(" ") && stem.rangeOfCharacter(from: .decimalDigits) != nil
            && stem.rangeOfCharacter(from: .letters) != nil { return true }
        return false
    }

    func stop() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

// MARK: - Model

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = "" { didSet { update() } }
    @Published private(set) var results: [LauncherItem] = []
    @Published var selection = 0

    let apps = AppIndex()
    private let files = FileSearch()
    private var fileWork: DispatchWorkItem?
    private var usage: [String: Int]
    private let usageKey = "launcherUsage"
    var onClose: () -> Void = {}
    var openSettings: () -> Void = {}
    var openShelf: () -> Void = {}
    /// Opens web links; replaced by the tools demo so it does not open a browser.
    var openURL: (URL) -> Void = { url in
        if !NSWorkspace.shared.open(url) { logError("Launcher: could not open \(url.host ?? "the browser")") }
    }

    init() {
        usage = UserDefaults.standard.dictionary(forKey: usageKey) as? [String: Int] ?? [:]
    }

    func reset() {
        query = ""
        selection = 0
        apps.refreshIfNeeded()
    }

    private func update() {
        let text = query.trimmingCharacters(in: .whitespaces)
        selection = 0
        fileWork?.cancel()
        files.stop()
        guard !text.isEmpty else { results = []; return }
        if let googleQuery = WebSearch.prefixedQuery(text) {
            results = [googleItem(googleQuery)]
            return
        }

        var items: [LauncherItem] = []
        if let value = Calculator.evaluate(text) {
            let formatted = Calculator.format(value, locale: Localizer.shared.language.locale)
            items.append(LauncherItem(id: "calc", kind: .calculation(formatted), title: "= \(formatted)",
                                      subtitle: tr(.launcherCopyResult), score: 2000))
        }
        for entry in apps.all {
            guard var score = FuzzyMatcher.score(query: text, candidate: entry.name) else { continue }
            score += Double(min(usage[entry.url.path] ?? 0, 50)) * 8
            items.append(LauncherItem(id: entry.url.path, kind: .app(entry.url), title: entry.name,
                                      subtitle: tr(.launcherApplication), score: score + 200))
        }
        let commands: [(L, () -> Void)] = [(.launcherCommandSettings, { [weak self] in self?.openSettings() }),
                                           (.launcherCommandShelf, { [weak self] in self?.openShelf() })]
        for (key, action) in commands {
            if let score = FuzzyMatcher.score(query: text, candidate: tr(key)) {
                items.append(LauncherItem(id: key.rawValue, kind: .command(action), title: tr(key),
                                          subtitle: AppInfo.name, score: score))
            }
        }
        items.sort { $0.score > $1.score }
        items = Array(items.prefix(8))
        items.append(googleItem(text))   // always last: the view pins it below the list
        results = items

        // Files arrive a moment later (Spotlight), debounced while typing.
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
            self.files.search(text) { [weak self] urls in
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == text, !urls.isEmpty else { return }
                let fileItems = urls.prefix(6).map { url in
                    LauncherItem(id: url.path, kind: .file(url), title: url.lastPathComponent,
                                 subtitle: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                                 score: 0)
                }
                var merged = self.results
                let webIndex = merged.firstIndex(where: \.isWeb) ?? merged.count
                merged.insert(contentsOf: fileItems, at: webIndex)
                self.results = merged
            }
        }
        fileWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func googleItem(_ text: String) -> LauncherItem {
        LauncherItem(id: "web", kind: .web(text), title: tr(.launcherWebSearch, text), subtitle: "google.com  ·  ⌥↩", score: -1)
    }

    /// ⌥↩: search Google for what was typed, whatever row is selected.
    func searchGoogle() {
        let text = results.last.flatMap { item -> String? in
            if case .web(let text) = item.kind { return text }
            return nil
        } ?? query
        guard let url = WebSearch.googleURL(for: text) else { return }
        openURL(url)
        onClose()
    }

    func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func activate(revealInFinder: Bool = false) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        switch item.kind {
        case .app(let url):
            if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting([url]); break }
            usage[url.path, default: 0] += 1
            UserDefaults.standard.set(usage, forKey: usageKey)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { logError("Launcher: could not open \(url.lastPathComponent): \(error.localizedDescription)") }
            }
        case .file(let url):
            if revealInFinder {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } else if !NSWorkspace.shared.open(url) {
                logError("Launcher: could not open \(url.lastPathComponent)")
            }
        case .calculation(let result):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result, forType: .string)
        case .web(let text):
            if let url = WebSearch.googleURL(for: text) { openURL(url) }
        case .command(let action):
            action()
        }
        onClose()
    }

    func icon(for item: LauncherItem) -> NSImage {
        switch item.kind {
        case .app(let url), .file(let url): return NSWorkspace.shared.icon(forFile: url.path)
        case .calculation: return NSImage(systemSymbolName: "equal.circle.fill", accessibilityDescription: nil) ?? NSImage()
        case .web: return NSImage(systemSymbolName: "magnifyingglass.circle.fill", accessibilityDescription: nil) ?? NSImage()
        case .command: return NSImage(systemSymbolName: "drop.fill", accessibilityDescription: nil) ?? NSImage()
        }
    }
}

// MARK: - Panel

@MainActor
final class Launcher {
    static let shared = Launcher()

    let model = LauncherModel()
    private var panel: GlassPanel?
    private var resignObserver: NSObjectProtocol?
    private var keyMonitor: Any?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.reset()
        guard let screen = GlassPanel.screenWithMouse else { return }
        let size = NSSize(width: 680, height: 420)
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height,
                              width: size.width, height: size.height), display: false)
        panel.fadeIn()
        panel.makeKey()
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.fadeOut()
    }

    private func makePanel() -> GlassPanel {
        let panel = GlassPanel(size: NSSize(width: 680, height: 420), canBecomeKey: true, level: .modalPanel)
        panel.hasShadow = false
        model.onClose = { [weak self] in self?.hide() }
        panel.setContent(LauncherView(model: model, localizer: Localizer.shared))
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
                                                                object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        return panel
    }

    /// For the tools demo: sends a key press to the launcher through the normal event queue.
    func postTestKey(_ keyCode: Int, modifiers: NSEvent.ModifierFlags = []) {
        guard let panel else { return }
        let characters = keyCode == kVK_Return ? "\r" : keyCode == kVK_DownArrow ? "\u{F701}" : ""
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: UInt16(keyCode)) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// ↑ ↓ choose, ↩ opens, ⌘↩ shows in Finder, ⌥↩ searches Google, Esc closes.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let panel, panel.isVisible, event.window === panel else { return false }
        // Leave keys alone while an input method (Japanese, Chinese …) is composing text.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case kVK_DownArrow: model.moveSelection(1)
        case kVK_UpArrow: model.moveSelection(-1)
        case kVK_Escape: hide()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if modifiers.contains(.option) {
                model.searchGoogle()
            } else {
                model.activate(revealInFinder: modifiers.contains(.command))
            }
        default: return false
        }
        return true
    }
}

private struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @ObservedObject var localizer: Localizer
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField(tr(.launcherPlaceholder), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .regular))
                    .focused($focused)
            }
            .padding(.horizontal, 20)
            .frame(height: 64)
            .liquidGlass(cornerRadius: 22)

            if !model.results.isEmpty {
                // Apps, files and calculations scroll; the Google row stays visible below them.
                let local = model.results.filter { !$0.isWeb }
                VStack(spacing: 0) {
                    if !local.isEmpty {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 2) {
                                    ForEach(Array(local.enumerated()), id: \.element.id) { index, item in
                                        row(item, selected: index == model.selection)
                                            .id(index)
                                            .onTapGesture { choose(index) }
                                    }
                                }
                                .padding(8)
                            }
                            .frame(height: min(CGFloat(local.count) * 50 + 16, 266))
                            .onChange(of: model.selection) {
                                if model.selection < local.count { proxy.scrollTo(model.selection, anchor: .center) }
                            }
                        }
                        Divider().padding(.horizontal, 16)
                    }
                    if let web = model.results.last, web.isWeb {
                        row(web, selected: model.selection == model.results.count - 1)
                            .onTapGesture { choose(model.results.count - 1) }
                            .padding(8)
                    }
                }
                .liquidGlass(cornerRadius: 22)
            }
            Spacer(minLength: 0)
        }
        .padding(6)
        .onAppear { focused = true }
    }

    private func choose(_ index: Int) {
        model.selection = index
        model.activate()
    }

    private func row(_ item: LauncherItem, selected: Bool) -> some View {
        HStack(spacing: 12) {
            Image(nsImage: model.icon(for: item))
                .resizable()
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
    }
}
