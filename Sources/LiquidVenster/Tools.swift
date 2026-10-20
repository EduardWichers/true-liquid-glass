import AppKit
import Combine
import SwiftUI

/// Other apps with the same features: their shortcuts can clash with ours.
enum CompetingApp: String, CaseIterable {
    case magnet = "com.crowdcafe.windowmagnet"
    case rectangle = "com.knollsoft.Rectangle"
    case alfred = "com.runningwithcrayons.Alfred"
    case dropzone = "com.aptonic.Dropzone4"
    case yoink = "at.EternalStorms.Yoink"

    var name: String {
        switch self {
        case .magnet: return "Magnet"
        case .rectangle: return "Rectangle"
        case .alfred: return "Alfred"
        case .dropzone: return "Dropzone"
        case .yoink: return "Yoink"
        }
    }

    /// Does the matching feature of True Liquid Glass run?
    func overlaps(_ settings: AppSettings) -> Bool {
        switch self {
        case .magnet, .rectangle: return settings.snapEnabled
        case .alfred: return settings.launcherEnabled
        case .dropzone, .yoink: return settings.shelfEnabled
        }
    }

    var runningInstance: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).first
            ?? NSWorkspace.shared.runningApplications.first { app in
                // Dropzone 3/4 and Alfred 4/5 use slightly different identifiers.
                guard let id = app.bundleIdentifier else { return false }
                return id.hasPrefix(rawValue.replacingOccurrences(of: "4", with: ""))
            }
    }

    static func runningConflicts(_ settings: AppSettings) -> [CompetingApp] {
        allCases.filter { $0.overlaps(settings) && $0.runningInstance != nil }
    }
}

/// Registers the shortcuts and monitors of the tools whenever their settings change.
@MainActor
final class ToolsController {
    static let shared = ToolsController()

    private var cancellable: AnyCancellable?
    private weak var status: AppStatus?
    var openSettings: () -> Void = {}

    func start(settings: AppSettings, status: AppStatus) {
        self.status = status
        Launcher.shared.model.openSettings = { [weak self] in self?.openSettings() }
        Launcher.shared.model.openShelf = { FileShelf.shared.show(near: nil) }
        apply(settings)
        cancellable = settings.objectWillChange
            .debounce(for: .milliseconds(150), scheduler: DispatchQueue.main)
            .sink { [weak self, weak settings] _ in
                guard let settings else { return }
                MainActor.assumeIsolated { self?.apply(settings) }
            }
    }

    func apply(_ settings: AppSettings) {
        let center = HotKeyCenter.shared
        center.unregisterAll(owner: "snap")
        center.unregisterAll(owner: "launcher")
        center.unregisterAll(owner: "shelf")

        if settings.snapEnabled {
            WindowSnapper.shared.registerShortcuts(modifiers: settings.snapModifiers.flags)
        }
        WindowSnapper.shared.dragSnappingEnabled = settings.snapEnabled && settings.snapDragEnabled

        if settings.launcherEnabled {
            center.register(settings.launcherHotkey.combo, owner: "launcher") { Launcher.shared.toggle() }
        } else {
            Launcher.shared.hide()
        }
        if settings.shelfEnabled {
            center.register(settings.shelfHotkey.combo, owner: "shelf") { FileShelf.shared.toggle() }
        } else {
            FileShelf.shared.hide()
        }
        FileShelf.shared.setEdgeRevealEnabled(settings.shelfEnabled && settings.shelfEdgeReveal)

        var failures: [String: [String]] = [:]
        for owner in ["snap", "launcher", "shelf"] {
            if let combos = center.failures[owner], !combos.isEmpty { failures[owner] = combos.map(\.display) }
        }
        if status?.toolShortcutFailures != failures { status?.toolShortcutFailures = failures }
    }

    /// The macOS setting "Drag windows to screen edges to tile" (on by default since macOS 15).
    static var systemEdgeTilingEnabled: Bool {
        let value = CFPreferencesCopyAppValue("EnableTilingByEdgeDrag" as CFString, "com.apple.WindowManager" as CFString)
        if let number = value as? NSNumber { return number.boolValue }
        return ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15
    }
}

/// "Tools" tab: window arranging, launcher and file shelf, as Liquid Glass cards.
struct ToolsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    @ObservedObject var localizer: Localizer
    @State private var conflicts: [CompetingApp] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(conflicts, id: \.self) { app in
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(tr(.otherAppRunning, app.name)).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr(.quitOtherApp, app.name)) {
                            app.runningInstance?.terminate()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshConflicts() }
                        }
                    }
                    .padding(12)
                    .liquidGlass(cornerRadius: 16, tint: .orange.opacity(0.15))
                }

                card(icon: "rectangle.split.2x1", title: .sectionSnap) {
                    Toggle(tr(.toggleSnap), isOn: $settings.snapEnabled)
                    HStack {
                        Text(tr(.snapModifiers))
                        Spacer()
                        Picker(tr(.snapModifiers), selection: $settings.snapModifiers) {
                            ForEach(SnapModifierPreset.allCases) { Text($0.display).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 260)
                    }
                    .disabled(!settings.snapEnabled)
                    failure(owner: "snap")
                    Toggle(tr(.toggleSnapDrag), isOn: $settings.snapDragEnabled)
                        .disabled(!settings.snapEnabled)
                    cheatSheet
                        .opacity(settings.snapEnabled ? 1 : 0.4)
                    Text(tr(.snapHint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                card(icon: "magnifyingglass", title: .sectionLauncher) {
                    Toggle(tr(.toggleLauncher), isOn: $settings.launcherEnabled)
                    shortcutPicker(selection: $settings.launcherHotkey).disabled(!settings.launcherEnabled)
                    failure(owner: "launcher")
                    Button(tr(.openLauncher)) { Launcher.shared.show() }.disabled(!settings.launcherEnabled)
                    Text(tr(.launcherHint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }

                card(icon: "tray.full", title: .sectionShelf) {
                    Toggle(tr(.toggleShelf), isOn: $settings.shelfEnabled)
                    shortcutPicker(selection: $settings.shelfHotkey).disabled(!settings.shelfEnabled)
                    failure(owner: "shelf")
                    Toggle(tr(.toggleShelfEdge), isOn: $settings.shelfEdgeReveal).disabled(!settings.shelfEnabled)
                    Button(tr(.showShelf)) { FileShelf.shared.show(near: nil) }.disabled(!settings.shelfEnabled)
                    Text(tr(.shelfHint)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .onAppear { refreshConflicts() }
    }

    private func refreshConflicts() {
        conflicts = CompetingApp.runningConflicts(settings)
    }

    private func card<Content: View>(icon: String, title: L, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(tr(title), systemImage: icon).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .liquidGlass(cornerRadius: 20)
    }

    private func shortcutPicker(selection: Binding<HotkeyPreset>) -> some View {
        HStack {
            Text(tr(.shortcutLabel))
            Spacer()
            Picker(tr(.shortcutLabel), selection: selection) {
                ForEach(HotkeyPreset.allCases) { Text($0.combo.display).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 160)
        }
    }

    @ViewBuilder
    private func failure(owner: String) -> some View {
        if let failed = status.toolShortcutFailures[owner], !failed.isEmpty {
            Label("\(failed.joined(separator: ", ")) — \(tr(.shortcutInUse))", systemImage: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cheatSheet: some View {
        let modifiers = settings.snapModifiers.flags
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                         alignment: .leading, spacing: 6) {
            ForEach(SnapKeys.ordered) { action in
                HStack(spacing: 8) {
                    Text(SnapKeys.combo(action, modifiers: modifiers)?.display ?? "")
                        .font(.system(.caption, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    Text(tr(action.label)).font(.caption)
                }
            }
        }
    }
}
