import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Files parked on the shelf and the folders they can be dropped into. Persisted.
@MainActor
final class ShelfStore: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let url: URL
        static func == (a: Item, b: Item) -> Bool { a.url == b.url }
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var destinations: [URL] = []
    @Published var status: String?

    private let defaults: UserDefaults
    private let itemsKey = "shelfItems"
    private let destinationsKey = "shelfDestinations"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let fm = FileManager.default
        // Files that were moved or deleted in the meantime are dropped silently.
        items = (defaults.stringArray(forKey: itemsKey) ?? [])
            .filter { fm.fileExists(atPath: $0) }
            .map { Item(url: URL(fileURLWithPath: $0)) }
        if let stored = defaults.stringArray(forKey: destinationsKey) {
            destinations = stored.filter { fm.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        } else {
            destinations = [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory, .documentDirectory]
                .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
        }
    }

    func add(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls where url.isFileURL && fm.fileExists(atPath: url.path) && !items.contains(where: { $0.url == url }) {
            items.append(Item(url: url))
        }
        save()
    }

    func remove(_ item: Item) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        items.removeAll()
        save()
    }

    func addDestination(_ url: URL) {
        guard !destinations.contains(url) else { return }
        destinations.append(url)
        save()
    }

    func removeDestination(_ url: URL) {
        destinations.removeAll { $0 == url }
        save()
    }

    /// Copies (or moves) files into a folder. Never overwrites: "name 2.ext", "name 3.ext" …
    @discardableResult
    func transfer(_ urls: [URL], to folder: URL, move: Bool) -> Bool {
        let fm = FileManager.default
        var failures: [String] = []
        var movedSources: [URL] = []
        for source in urls {
            let target = ShelfStore.uniqueDestination(for: source.lastPathComponent, in: folder)
            do {
                if move {
                    try fm.moveItem(at: source, to: target)
                    movedSources.append(source)
                } else {
                    try fm.copyItem(at: source, to: target)
                }
            } catch {
                failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                logError("Shelf: \(move ? "moving" : "copying") \(source.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
        if move {
            items.removeAll { movedSources.contains($0.url) }
            save()
        }
        let folderName = FileManager.default.displayName(atPath: folder.path)
        if failures.isEmpty {
            status = tr(move ? .shelfStatusMoved : .shelfStatusCopied, folderName)
            logInfo("Shelf: \(urls.count) file(s) \(move ? "moved" : "copied") to \(folder.path)")
        } else {
            status = tr(.shelfStatusFailed, failures.joined(separator: ", "))
        }
        return failures.isEmpty
    }

    static func uniqueDestination(for name: String, in folder: URL) -> URL {
        let fm = FileManager.default
        var candidate = folder.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var counter = 2
        repeat {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        } while fm.fileExists(atPath: candidate.path) && counter < 10_000
        return candidate
    }

    private func save() {
        defaults.set(items.map(\.url.path), forKey: itemsKey)
        defaults.set(destinations.map(\.path), forKey: destinationsKey)
    }
}

/// The shelf panel at the right edge of the screen.
@MainActor
final class FileShelf {
    static let shared = FileShelf()

    let store = ShelfStore()
    private var panel: GlassPanel?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var dragChangeCount = NSPasteboard(name: .drag).changeCount
    private var openedByEdge = false
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel?.isVisible ?? false }
    static let size = NSSize(width: 300, height: 480)

    func toggle() { isVisible ? hide() : show(near: nil) }

    func show(near screen: NSScreen?) {
        hideWork?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        guard let screen = screen ?? GlassPanel.screenWithMouse else { return }
        let v = screen.visibleFrame
        let size = FileShelf.size
        panel.setFrame(NSRect(x: v.maxX - size.width - 12, y: v.midY - size.height / 2,
                              width: size.width, height: size.height), display: false)
        if !panel.isVisible { panel.fadeIn() }
    }

    func hide() {
        hideWork?.cancel()
        openedByEdge = false
        guard let panel, panel.isVisible else { return }
        panel.fadeOut()
    }

    /// Shows the shelf when files are dragged to the right edge of a screen (like Dropzone/Yoink).
    func setEdgeRevealEnabled(_ enabled: Bool) {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil
        upMonitor = nil
        guard enabled else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.draggedOutside() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.dragEnded() }
        }
    }

    private func draggedOutside() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }),
              mouse.x >= screen.frame.maxX - 3 else { return }
        let pasteboard = NSPasteboard(name: .drag)
        // Only a drag that started after the last one and carries files.
        guard pasteboard.changeCount != dragChangeCount,
              pasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else { return }
        if !isVisible {
            openedByEdge = true
            show(near: screen)
        }
    }

    private func dragEnded() {
        dragChangeCount = NSPasteboard(name: .drag).changeCount
        guard openedByEdge else { return }
        // Opened only for this drag: close again unless the pointer is on the shelf.
        let work = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.panel, self.openedByEdge else { return }
            if !NSMouseInRect(NSEvent.mouseLocation, panel.frame, false) { self.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    private func makePanel() -> GlassPanel {
        let panel = GlassPanel(size: FileShelf.size, canBecomeKey: true, level: .floating)
        panel.setContent(ShelfView(store: store, localizer: Localizer.shared, close: { [weak self] in self?.hide() }))
        return panel
    }
}

private struct ShelfView: View {
    @ObservedObject var store: ShelfStore
    @ObservedObject var localizer: Localizer
    let close: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "tray.full.fill").foregroundStyle(.secondary)
                Text(tr(.menuShelf)).font(.headline)
                Spacer()
                if !store.items.isEmpty {
                    Button(tr(.shelfClear)) { store.clear() }.buttonStyle(.borderless).font(.caption)
                }
                Button { close() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            Group {
                if store.items.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text(tr(.shelfEmpty)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                            ForEach(store.items) { item in tile(item) }
                        }
                        .padding(4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(targeted ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                ShelfView.loadURLs(providers) { store.add($0) }
                return true
            }

            if !store.items.isEmpty {
                Text(tr(.shelfItemsCount, store.items.count)).font(.caption).foregroundStyle(.secondary)
            }

            Text(tr(.shelfDestinations)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                ForEach(store.destinations, id: \.self) { folder in
                    DestinationRow(folder: folder, store: store)
                }
                Button {
                    addFolder()
                } label: {
                    Label(tr(.shelfAddFolder), systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            if let status = store.status {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(16)
        .liquidGlass(cornerRadius: 26)
        .padding(4)
        .onKeyPress(.escape) { close(); return .handled }
    }

    private func tile(_ item: ShelfStore.Item) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 44, height: 44)
            Text(item.url.lastPathComponent)
                .font(.system(size: 10))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.url.lastPathComponent)
        }
        .frame(width: 76, height: 82)
        .contentShape(Rectangle())
        .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(item.url) }
        .contextMenu {
            Button(tr(.shelfOpen)) { NSWorkspace.shared.open(item.url) }
            Button(tr(.shelfReveal)) { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
            Button(tr(.shelfCopyClipboard)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([item.url as NSURL])
            }
            Menu(tr(.shelfCopyTo)) {
                ForEach(store.destinations, id: \.self) { folder in
                    Button(FileManager.default.displayName(atPath: folder.path)) { store.transfer([item.url], to: folder, move: false) }
                }
            }
            Menu(tr(.shelfMoveTo)) {
                ForEach(store.destinations, id: \.self) { folder in
                    Button(FileManager.default.displayName(atPath: folder.path)) { store.transfer([item.url], to: folder, move: true) }
                }
            }
            Button(tr(.shelfAirDrop)) {
                NSSharingService(named: .sendViaAirDrop)?.perform(withItems: [item.url])
            }
            Divider()
            Button(tr(.shelfRemove)) { store.remove(item) }
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { store.addDestination(url) }
    }

    static func loadURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}

/// A folder on the shelf: dropping files on it copies them there (⌥ moves them).
private struct DestinationRow: View {
    let folder: URL
    @ObservedObject var store: ShelfStore
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: folder.path))
                .resizable()
                .frame(width: 20, height: 20)
            Text(FileManager.default.displayName(atPath: folder.path)).lineLimit(1)
            Spacer()
            if !store.items.isEmpty {
                Button {
                    store.transfer(store.items.map(\.url), to: folder, move: false)
                } label: {
                    Image(systemName: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.borderless)
                .help(tr(.shelfCopyTo))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(targeted ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            let move = NSEvent.modifierFlags.contains(.option)
            ShelfView.loadURLs(providers) { store.transfer($0, to: folder, move: move) }
            return true
        }
        .contextMenu {
            Button(tr(.shelfReveal)) { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
            Button(tr(.shelfRemoveFolder)) { store.removeDestination(folder) }
        }
    }
}
