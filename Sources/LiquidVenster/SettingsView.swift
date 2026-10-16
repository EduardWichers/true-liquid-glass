import AppKit
import SwiftUI

enum SettingsTab: Hashable {
    case settings
    case troubleshooting
}

/// Live state shown in the settings window and the menu bar.
final class AppStatus: ObservableObject {
    @Published var accessibility = false
    @Published var screenCapture = false
    @Published var interceptorRunning = false
    @Published var interceptorError: InterceptorError?
    /// Technical (English) description of a GPU problem.
    @Published var rendererError: String?
    @Published var reduceMotion = false
    @Published var loginItem: LoginItem.State = .disabled
    @Published var selectedTab: SettingsTab = .settings

    /// Everything needed for other apps is in place.
    var isFullyConfigured: Bool { accessibility && screenCapture && rendererError == nil }

    func summary(settings: AppSettings, language: AppLanguage? = nil) -> (text: String, isProblem: Bool, isActive: Bool) {
        let l = Localizer.shared
        func t(_ key: L) -> String { l.string(key, in: language) }
        func f(_ key: L, _ arg: String) -> String { l.format(key, [arg], in: language) }

        if let error = rendererError { return (f(.statusRendererError, error), true, false) }
        if !settings.systemWideEnabled { return (t(.statusSystemWideOff), false, false) }
        if !accessibility { return (t(.statusWaitingAccessibility), true, false) }
        if !screenCapture { return (t(.statusWaitingScreenRecording), true, false) }
        if let error = interceptorError { return (f(.statusInterceptorError, error.reason(in: language)), true, false) }
        if reduceMotion && settings.respectReduceMotion { return (t(.statusReduceMotion), true, false) }
        if interceptorRunning { return (t(.statusActive), false, true) }
        return (t(.statusStarting), false, false)
    }
}

extension InterceptorError {
    func reason(in language: AppLanguage? = nil) -> String {
        switch self {
        case .notTrusted: return Localizer.shared.string(.interceptorNotTrusted, in: language)
        case .tapCreationFailed: return Localizer.shared.string(.interceptorTapFailed, in: language)
        case .runLoopSourceFailed: return Localizer.shared.string(.interceptorRunLoopFailed, in: language)
        }
    }
}

struct SettingsActions {
    var openDemo: () -> Void
    var testEffect: () -> Void
    var requestAccessibility: () -> Void
    var requestScreenCapture: () -> Void
    var openAccessibilitySettings: () -> Void
    var openScreenCaptureSettings: () -> Void
    var resetPermissions: () -> Void
    var relaunch: () -> Void
    var showInFinder: () -> Void
    var refresh: () -> Void
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    @ObservedObject var log: AppLog
    @ObservedObject var localizer: Localizer
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 10)
            TabView(selection: $status.selectedTab) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        statusSection
                        generalSection
                        effectSection
                        permissionSection
                        logSection
                        credits
                    }
                    .padding(20)
                }
                .tabItem { Text(tr(.tabSettings)) }
                .tag(SettingsTab.settings)

                TroubleshootingView(settings: settings, status: status, log: log, localizer: localizer, actions: actions)
                    .tabItem { Text(tr(.tabTroubleshooting)) }
                    .tag(SettingsTab.troubleshooting)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 740)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "drop.fill")
                .font(.system(size: 34))
                .foregroundStyle(LinearGradient(colors: [.cyan, .blue], startPoint: .top, endPoint: .bottom))
            VStack(alignment: .leading, spacing: 2) {
                Text(AppInfo.name).font(.title2.bold())
                Text(tr(.appTagline))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var credits: some View {
        HStack(spacing: 6) {
            Spacer()
            if let url = AppInfo.authorURL {
                Link(tr(.creditsMadeBy, AppInfo.author), destination: url)
            } else {
                Text(tr(.creditsMadeBy, AppInfo.author))
            }
            Text("·")
            Text(tr(.versionLabel, AppInfo.version))
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var statusSection: some View {
        let summary = status.summary(settings: settings)
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(tr(.toggleSystemWide), isOn: $settings.systemWideEnabled)
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(summary.isActive ? Color.green : (summary.isProblem ? Color.orange : Color.secondary))
                        .frame(width: 9, height: 9)
                        .padding(.top, 4)
                    Text(summary.text).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(tr(.sectionStatus)).font(.headline)
        }
    }

    private var generalSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Toggle(tr(.toggleLoginItem), isOn: loginBinding)
                if status.loginItem == .requiresApproval {
                    HStack {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(tr(.loginItemNeedsApproval)).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr(.fixOpenLoginItems)) { LoginItem.openSettings() }
                    }
                }
                Text(tr(.loginItemHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text(tr(.sectionLanguage))
                    Spacer()
                    Picker(tr(.sectionLanguage), selection: languageBinding) {
                        Text(Localizer.shared.format(.languageSystem, [localizer.systemLanguage.nativeName]))
                            .tag(AppLanguage?.none)
                        Divider()
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.nativeName).tag(AppLanguage?.some(language))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
                Text(tr(.languageHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(tr(.sectionGeneral)).font(.headline)
        }
    }

    private var effectSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Toggle(tr(.toggleMinimizeEffect), isOn: $settings.minimizeEffectEnabled)
                Toggle(tr(.toggleCloseEffect), isOn: $settings.closeEffectEnabled)
                Divider()
                HStack(alignment: .center, spacing: 14) {
                    WaterPreview(color: settings.waterColor, strength: settings.colorStrength)
                        .frame(width: 96, height: 68)
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(tr(.waterColor))
                            Spacer()
                            ColorPicker(tr(.waterColor), selection: colorBinding, supportsOpacity: false)
                                .labelsHidden()
                        }
                        presetRow
                        Text(settings.activePreset.map { tr(.presetLabel, $0.name) } ?? tr(.customColor))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(tr(.colorDepth))
                    Slider(value: $settings.colorStrength, in: AppSettings.strengthRange)
                    Text(percent(settings.colorStrength))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Text(tr(.colorDepthHelp))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                HStack {
                    Text(tr(.speed))
                    Slider(value: $settings.speed, in: AppSettings.speedRange)
                    Text(String(format: "%.1f×", locale: localizer.language.locale, settings.speed))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
                Toggle(tr(.reduceMotionToggle), isOn: $settings.respectReduceMotion)
                HStack {
                    Button(tr(.openTestWindow), action: actions.openDemo)
                    Button(tr(.playEffect), action: actions.testEffect)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(tr(.sectionEffect)).font(.headline)
        }
    }

    private var permissionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                PermissionRow(title: tr(.permAccessibilityTitle), detail: tr(.permAccessibilityDetail),
                              granted: status.accessibility, action: actions.requestAccessibility)
                PermissionRow(title: tr(.permScreenTitle), detail: tr(.permScreenDetail),
                              granted: status.screenCapture, action: actions.requestScreenCapture)
                Text(tr(.permHint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr(.buttonRestart), action: actions.relaunch)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(tr(.sectionPermissions)).font(.headline)
        }
    }

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.entries) { entry in
                                Text(entry.line)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(6)
                    }
                    .frame(height: 150)
                    .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: log.entries.count) {
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                HStack {
                    Button(tr(.copyLog)) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }
                    Button(tr(.clearLog)) { log.clear() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(tr(.sectionLog)).font(.headline)
        }
    }

    private var presetRow: some View {
        HStack(spacing: 9) {
            ForEach(AppSettings.presets) { preset in
                let selected = settings.activePreset?.id == preset.id
                Button {
                    settings.apply(preset)
                } label: {
                    Circle()
                        .fill(preset.color.swiftUIColor)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                        .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-4).opacity(selected ? 1 : 0))
                        .padding(4)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(preset.name)
                .accessibilityLabel(preset.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { status.loginItem == .enabled || status.loginItem == .requiresApproval },
            set: { enabled in
                LoginItem.setEnabled(enabled)
                status.loginItem = LoginItem.state
            })
    }

    private var languageBinding: Binding<AppLanguage?> {
        Binding(get: { localizer.override }, set: { localizer.setOverride($0) })
    }

    /// The colour picker works with SwiftUI colours; settings store sRGB components.
    private var colorBinding: Binding<Color> {
        Binding(
            get: { settings.waterColor.swiftUIColor },
            set: { newValue in
                guard let srgb = NSColor(newValue).usingColorSpace(.sRGB) else {
                    logWarning("Chosen colour could not be converted to sRGB")
                    return
                }
                settings.waterColor = WaterColor(red: Double(srgb.redComponent),
                                                 green: Double(srgb.greenComponent),
                                                 blue: Double(srgb.blueComponent))
            })
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)).locale(localizer.language.locale))
    }

    private func color(for level: AppLog.Level) -> Color {
        switch level {
        case .error: return .red
        case .warning: return .orange
        case .info: return .primary
        case .debug: return .secondary
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).bold()
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if granted {
                Text(tr(.permGranted)).font(.caption).foregroundStyle(.secondary)
            } else {
                Button(tr(.permAllow), action: action)
            }
        }
    }
}

extension WaterColor {
    var swiftUIColor: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: 1) }
}

/// Small preview: a drop of the chosen water over light and dark stripes, using the
/// same absorption model as the shader (thick water filters light towards its colour).
private struct WaterPreview: View {
    let color: WaterColor
    let strength: Double

    var body: some View {
        Canvas { context, size in
            let stripes = 6
            let stripeWidth = size.width / CGFloat(stripes)
            for i in 0..<stripes {
                let rect = CGRect(x: CGFloat(i) * stripeWidth, y: 0, width: stripeWidth + 0.5, height: size.height)
                context.fill(Path(rect), with: .color(i % 2 == 0 ? Color(white: 0.93) : Color(white: 0.32)))
            }
            let dropRect = CGRect(x: size.width * 0.1, y: size.height * 0.16, width: size.width * 0.8, height: size.height * 0.68)
            let drop = Path(roundedRect: dropRect, cornerRadius: dropRect.height * 0.5)
            // Beer–Lambert: transmittance = colour ^ (absorption * depth), as in the shader.
            let exponent = (0.3 + 2.2 * strength) * (0.5 + 1.5 * strength)
            func transmit(_ c: Double) -> Double { pow(max(c, 0.03), exponent) }
            let t = (transmit(color.red), transmit(color.green), transmit(color.blue))
            var multiply = context
            multiply.blendMode = .multiply
            multiply.fill(drop, with: .color(Color(.sRGB, red: t.0, green: t.1, blue: t.2, opacity: 1)))
            var add = context
            add.blendMode = .plusLighter
            add.fill(drop, with: .color(Color(.sRGB, red: color.red * (1 - t.0) * 0.25, green: color.green * (1 - t.1) * 0.25,
                                               blue: color.blue * (1 - t.2) * 0.25, opacity: 1)))
            context.stroke(drop, with: .color(.black.opacity(0.22)), lineWidth: 1.5)
            let glint = CGRect(x: dropRect.minX + dropRect.width * 0.14, y: dropRect.minY + dropRect.height * 0.14,
                               width: dropRect.width * 0.28, height: dropRect.height * 0.2)
            context.fill(Path(ellipseIn: glint), with: .color(.white.opacity(0.75)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15)))
        .accessibilityHidden(true)
    }
}
