import AppKit
import SwiftUI

/// "Troubleshooting" tab: automatic checks with fix buttons, common problems and a report.
struct TroubleshootingView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var status: AppStatus
    @ObservedObject var log: AppLog
    @ObservedObject var localizer: Localizer
    let actions: SettingsActions

    @State private var copies: [String] = []
    @State private var tick = 0
    @State private var reportCopied = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let faq: [(L, L)] = [(.faqQ1, .faqA1), (.faqQ2, .faqA2), (.faqQ7, .faqA7), (.faqQ8, .faqA8),
                                 (.faqQ3, .faqA3), (.faqQ4, .faqA4), (.faqQ5, .faqA5), (.faqQ6, .faqA6)]

    var body: some View {
        // `tick` forces a periodic re-check while the tab is visible.
        let items = tick >= 0 ? Diagnostics.run(settings: settings, status: status, copies: copies) : []
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr(.tsIntro))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(items) { item in
                            DiagnosticRow(item: item, perform: perform)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Text(tr(.tsDiagnosisTitle)).font(.headline)
                }

                HStack {
                    Button(tr(.tsCheckAgain)) { recheck() }
                    Button(tr(.tsCopyReport)) { copyReport() }
                    if reportCopied {
                        Text(tr(.tsReportCopied)).font(.caption).foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(faq, id: \.0) { question, answer in
                            DisclosureGroup {
                                Text(tr(answer))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 4)
                                    .textSelection(.enabled)
                            } label: {
                                Text(tr(question)).fontWeight(.medium)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                } label: {
                    Text(tr(.faqTitle)).font(.headline)
                }
            }
            .padding(20)
        }
        .onAppear { recheck() }
        .onReceive(timer) { _ in tick &+= 1 }
    }

    private func recheck() {
        copies = Diagnostics.installedCopies()
        actions.refresh()
        tick &+= 1
    }

    private func copyReport() {
        let report = Diagnostics.report(settings: settings, status: status, copies: copies)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        reportCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { reportCopied = false }
    }

    private func perform(_ fix: DiagnosticItem.Fix) {
        switch fix {
        case .openAccessibility: actions.openAccessibilitySettings()
        case .openScreenCapture: actions.openScreenCaptureSettings()
        case .resetPermissions: actions.resetPermissions()
        case .restart: actions.relaunch()
        case .showInFinder: actions.showInFinder()
        case .enableSystemWide: settings.systemWideEnabled = true
        case .ignoreReduceMotion: settings.respectReduceMotion = false
        case .enableLoginItem:
            LoginItem.setEnabled(true)
            status.loginItem = LoginItem.state
        case .openLoginItems: LoginItem.openSettings()
        case .quitApp(let bundleID, _):
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).forEach { $0.terminate() }
        case .openDesktopSettings:
            if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
        actions.refresh()
        tick &+= 1
    }
}

private struct DiagnosticRow: View {
    let item: DiagnosticItem
    let perform: (DiagnosticItem.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .font(.title3)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).fontWeight(.medium)
                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !item.fixes.isEmpty {
                    HStack {
                        ForEach(item.fixes, id: \.self) { fix in
                            Button(label(for: fix)) { perform(fix) }
                                .controlSize(.small)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch item.state {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch item.state {
        case .ok: return .green
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private func label(for fix: DiagnosticItem.Fix) -> String {
        switch fix {
        case .openAccessibility, .openScreenCapture: return tr(.fixOpenSettings)
        case .resetPermissions: return tr(.fixResetPermissions)
        case .restart: return tr(.fixRestart)
        case .showInFinder: return tr(.fixShowInFinder)
        case .enableSystemWide, .enableLoginItem: return tr(.fixTurnOn)
        case .ignoreReduceMotion: return tr(.fixIgnoreReduceMotion)
        case .openLoginItems: return tr(.fixOpenLoginItems)
        case .quitApp(_, let name): return tr(.quitOtherApp, name)
        case .openDesktopSettings: return tr(.fixOpenDesktopSettings)
        }
    }
}
