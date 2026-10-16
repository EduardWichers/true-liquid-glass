import Foundation

/// Product identity. The bundle identifier and signing identity stay the same as in the
/// first versions so existing settings and permissions keep working.
enum AppInfo {
    static let name = "True Liquid Glass"
    static let author = "Eduard Wichers"
    static let authorURL = URL(string: "https://github.com/EduardWichers")
    static let bundleIdentifier = "nl.liquidvenster.app"

    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(short) (\(build))"
    }
}

/// The ten supported languages.
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case dutch = "nl"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case portuguese = "pt-BR"
    case italian = "it"
    case russian = "ru"
    case chinese = "zh-Hans"
    case japanese = "ja"

    var id: String { rawValue }

    /// The language's name in that language (shown in the language menu).
    var nativeName: String {
        switch self {
        case .english: return "English"
        case .dutch: return "Nederlands"
        case .german: return "Deutsch"
        case .french: return "Français"
        case .spanish: return "Español"
        case .portuguese: return "Português (Brasil)"
        case .italian: return "Italiano"
        case .russian: return "Русский"
        case .chinese: return "简体中文"
        case .japanese: return "日本語"
        }
    }

    var table: [L: String] {
        switch self {
        case .english: return Strings.en
        case .dutch: return Strings.nl
        case .german: return Strings.de
        case .french: return Strings.fr
        case .spanish: return Strings.es
        case .portuguese: return Strings.ptBR
        case .italian: return Strings.it
        case .russian: return Strings.ru
        case .chinese: return Strings.zhHans
        case .japanese: return Strings.ja
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    /// Best match for a list of preferred language identifiers (e.g. ["nl-NL", "en-US"]);
    /// English when none of them is supported. Traditional Chinese is not mapped to
    /// Simplified Chinese.
    static func best(for preferred: [String]) -> AppLanguage {
        for identifier in preferred {
            let lower = identifier.replacingOccurrences(of: "_", with: "-").lowercased()
            if let exact = allCases.first(where: { $0.rawValue.lowercased() == lower }) { return exact }
            guard let base = lower.split(separator: "-").first.map(String.init) else { continue }
            switch base {
            case "zh":
                let traditional = lower.contains("hant") || lower.hasSuffix("-tw") || lower.hasSuffix("-hk") || lower.hasSuffix("-mo")
                if !traditional { return .chinese }
            case "pt":
                return .portuguese
            default:
                if let match = allCases.first(where: { $0.rawValue == base }) { return match }
            }
        }
        return .english
    }
}

extension Notification.Name {
    static let appLanguageChanged = Notification.Name("nl.liquidvenster.languageChanged")
}

/// Chooses the language and looks up strings. Follows macOS unless the user picked a
/// language in the app.
final class Localizer: ObservableObject {
    static let shared = Localizer()

    private static let overrideKey = "appLanguage"
    private let defaults: UserDefaults
    private let systemPreferred: () -> [String]

    /// nil = follow macOS.
    @Published private(set) var override: AppLanguage?
    @Published private(set) var language: AppLanguage

    init(defaults: UserDefaults = .standard, systemPreferred: @escaping () -> [String] = Localizer.systemLanguages) {
        self.defaults = defaults
        self.systemPreferred = systemPreferred
        let stored = defaults.string(forKey: Localizer.overrideKey).flatMap(AppLanguage.init(rawValue:))
        override = stored
        language = stored ?? AppLanguage.best(for: systemPreferred())
    }

    /// The language macOS would choose (ignoring the in-app choice).
    var systemLanguage: AppLanguage { AppLanguage.best(for: systemPreferred()) }

    /// The user's global language list. Read from the global domain because our own
    /// `AppleLanguages` (set for an in-app choice) would otherwise hide it.
    static func systemLanguages() -> [String] {
        let global = CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication,
                                            kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String]
        return global ?? Locale.preferredLanguages
    }

    func setOverride(_ choice: AppLanguage?) {
        override = choice
        language = choice ?? systemLanguage
        if let choice {
            defaults.set(choice.rawValue, forKey: Localizer.overrideKey)
            // macOS's own parts (colour panel, standard alerts) follow this after a restart.
            defaults.set([choice.rawValue], forKey: "AppleLanguages")
        } else {
            defaults.removeObject(forKey: Localizer.overrideKey)
            defaults.removeObject(forKey: "AppleLanguages")
        }
        NotificationCenter.default.post(name: .appLanguageChanged, object: self)
    }

    /// Switch language for this run only, without saving it (used for screenshots).
    func useForThisSession(_ choice: AppLanguage) {
        override = choice
        language = choice
        NotificationCenter.default.post(name: .appLanguageChanged, object: self)
    }

    func string(_ key: L, in language: AppLanguage? = nil) -> String {
        let chosen = language ?? self.language
        if let text = chosen.table[key], !text.isEmpty { return text }
        return Strings.en[key] ?? key.rawValue
    }

    func format(_ key: L, _ arguments: [CVarArg], in language: AppLanguage? = nil) -> String {
        let chosen = language ?? self.language
        return String(format: string(key, in: chosen), locale: chosen.locale, arguments: arguments)
    }
}

/// Localised text in the current language.
func tr(_ key: L) -> String { Localizer.shared.string(key) }
func tr(_ key: L, _ arguments: CVarArg...) -> String { Localizer.shared.format(key, arguments) }

/// Every user-visible text. The English table (`Strings.en`) is the reference; the
/// self-test checks that every language has every key with the same placeholders.
enum L: String, CaseIterable {
    case appTagline, tabSettings, tabTroubleshooting
    case sectionStatus, toggleSystemWide
    case statusRendererError, statusSystemWideOff, statusWaitingAccessibility, statusWaitingScreenRecording
    case statusInterceptorError, statusReduceMotion, statusActive, statusStarting
    case interceptorNotTrusted, interceptorTapFailed, interceptorRunLoopFailed
    case sectionPermissions, permAccessibilityTitle, permAccessibilityDetail, permScreenTitle, permScreenDetail
    case permGranted, permAllow, permHint, buttonRestart
    case sectionEffect, waterColor, presetLabel, customColor, colorDepth, colorDepthHelp, speed
    case reduceMotionToggle, openTestWindow, playEffect
    case presetClear, presetSea, presetLagoon, presetGlacier, presetLemonade, presetRaspberry, presetCola
    case sectionLanguage, languageSystem, languageHint
    case sectionLog, copyLog, clearLog
    case menuAbout, menuSettings, menuHide, menuQuit, menuEdit, menuCopy, menuSelectAll, menuWindow
    case menuMinimize, menuZoom, menuNewTestWindow, menuCloseWindow, menuTroubleshooting
    case menuEffectAllApps, menuPlayEffect
    case testWindowTitle, demoBody
    case tsIntro, tsCheckAgain, tsCopyReport, tsReportCopied, tsDiagnosisTitle, faqTitle
    case diagMacOS, diagMacOSDetail
    case diagLocationOK, diagLocationTranslocated, diagLocationTranslocatedDetail, diagLocationOther, diagLocationOtherDetail
    case diagSignatureOK, diagSignatureOKDetail, diagSignatureAdhoc, diagSignatureAdhocDetail
    case diagSignatureInvalid, diagSignatureInvalidDetail
    case diagCopiesOne, diagCopiesMultiple, diagCopiesMultipleDetail
    case diagAXOK, diagAXMissing, diagAXMissingDetail, diagSCOK, diagSCMissing, diagSCMissingDetail
    case diagTapOK, diagTapOff, diagTapOffDetail, diagTapError
    case diagGPUOK, diagGPUError, diagGPUErrorDetail
    case diagReduceMotion, diagReduceMotionDetail
    case diagDockOK, diagDockEstimated, diagDockEstimatedDetail, dockBottom, dockLeft, dockRight
    case diagDisplays, diagErrorsNone, diagErrorsSome, diagErrorsSomeDetail
    case fixOpenSettings, fixResetPermissions, fixRestart, fixShowInFinder, fixTurnOn, fixIgnoreReduceMotion
    case resetTitle, resetMessage, resetConfirm, cancel, resetDone, resetFailed
    case faqQ1, faqA1, faqQ2, faqA2, faqQ3, faqA3, faqQ4, faqA4, faqQ5, faqA5, faqQ6, faqA6
    case instWelcomeIntro, instRequirements, instAfterTitle, instAfter1, instAfter2, instPrivacy
    case instDoneTitle, instDone1, instDone2, instDone3, instDoneHelp
    case toggleMinimizeEffect, toggleCloseEffect
    case sectionGeneral, toggleLoginItem, loginItemHint, loginItemNeedsApproval
    case diagLoginOK, diagLoginOff, diagLoginOffDetail, diagLoginApproval, fixOpenLoginItems
    case faqQ7, faqA7, faqQ8, faqA8
    case creditsMadeBy, versionLabel
}

/// Translation tables; one file per language (Strings+xx.swift).
enum Strings {}
