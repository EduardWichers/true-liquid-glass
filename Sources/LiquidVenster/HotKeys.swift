import AppKit
import Carbon.HIToolbox

/// A keyboard shortcut: virtual key code + modifiers.
struct KeyCombo: Hashable {
    let keyCode: UInt32
    let modifiers: NSEvent.ModifierFlags

    init(_ keyCode: Int, _ modifiers: NSEvent.ModifierFlags) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = modifiers.intersection([.command, .option, .control, .shift])
    }

    static func == (a: KeyCombo, b: KeyCombo) -> Bool { a.keyCode == b.keyCode && a.modifiers == b.modifiers }
    func hash(into hasher: inout Hasher) {
        hasher.combine(keyCode)
        hasher.combine(modifiers.rawValue)
    }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifiers.contains(.command) { flags |= UInt32(cmdKey) }
        if modifiers.contains(.option) { flags |= UInt32(optionKey) }
        if modifiers.contains(.control) { flags |= UInt32(controlKey) }
        if modifiers.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// e.g. "⌃⌥←" (Apple's order: ⌃ ⌥ ⇧ ⌘).
    var display: String { KeyCombo.symbols(for: modifiers) + KeyCombo.keyName(keyCode) }

    static func symbols(for modifiers: NSEvent.ModifierFlags) -> String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Return: return "↩"
        case kVK_Delete: return "⌫"
        case kVK_Space: return "Space"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        default: return "#\(code)"
        }
    }
}

/// Shortcut choices offered for the launcher and the file shelf.
enum HotkeyPreset: String, CaseIterable, Identifiable {
    case commandSpace, optionSpace, controlSpace, controlOptionSpace, optionShiftSpace, shiftCommandSpace, controlOptionCommandD

    var id: String { rawValue }

    var combo: KeyCombo {
        switch self {
        case .commandSpace: return KeyCombo(kVK_Space, [.command])
        case .optionSpace: return KeyCombo(kVK_Space, [.option])
        case .controlSpace: return KeyCombo(kVK_Space, [.control])
        case .controlOptionSpace: return KeyCombo(kVK_Space, [.control, .option])
        case .optionShiftSpace: return KeyCombo(kVK_Space, [.option, .shift])
        case .shiftCommandSpace: return KeyCombo(kVK_Space, [.shift, .command])
        case .controlOptionCommandD: return KeyCombo(kVK_ANSI_D, [.control, .option, .command])
        }
    }

    /// Preferred defaults, best first: ⌘Space for the launcher when Spotlight does not use it.
    static let launcherOrder: [HotkeyPreset] = [.commandSpace, .optionSpace, .optionShiftSpace, .shiftCommandSpace, .controlOptionCommandD]
    static let shelfOrder: [HotkeyPreset] = [.controlOptionSpace, .optionShiftSpace, .shiftCommandSpace, .controlOptionCommandD]

    /// The first preset in `order` that macOS (or the other tool) does not already use.
    static func firstFree(_ order: [HotkeyPreset], taken: Set<KeyCombo>) -> HotkeyPreset {
        order.first { !taken.contains($0.combo) } ?? order[0]
    }
}

/// Shortcuts that macOS itself reserves (System Settings › Keyboard › Keyboard Shortcuts…).
/// They win over RegisterEventHotKey, so a clash means our shortcut silently does nothing.
enum SystemShortcut: Int, CaseIterable {
    case previousInputSource = 60, nextInputSource = 61, spotlight = 64, finderSearch = 65

    var label: L {
        switch self {
        case .previousInputSource, .nextInputSource: return .sysInputSource
        case .spotlight: return .sysSpotlight
        case .finderSearch: return .sysFinderSearch
        }
    }

    /// The macOS default, used when the entry is missing from the preferences.
    var defaultCombo: KeyCombo {
        switch self {
        case .previousInputSource: return KeyCombo(kVK_Space, [.control])
        case .nextInputSource: return KeyCombo(kVK_Space, [.control, .option])
        case .spotlight: return KeyCombo(kVK_Space, [.command])
        case .finderSearch: return KeyCombo(kVK_Space, [.option, .command])
        }
    }
}

enum SystemShortcuts {
    /// The enabled system shortcuts we could clash with, read from com.apple.symbolichotkeys.
    static func current() -> [KeyCombo: SystemShortcut] {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        let hotkeys = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
        return reserved(from: hotkeys, keyboardInputSources: keyboardInputSourceCount)
    }

    /// Pure parser (self-tested). Switching input sources only matters with more than one source.
    static func reserved(from hotkeys: [String: Any]?, keyboardInputSources: Int) -> [KeyCombo: SystemShortcut] {
        var result: [KeyCombo: SystemShortcut] = [:]
        for shortcut in SystemShortcut.allCases {
            if (shortcut == .previousInputSource || shortcut == .nextInputSource) && keyboardInputSources < 2 { continue }
            guard let entry = hotkeys?[String(shortcut.rawValue)] as? [String: Any] else {
                result[shortcut.defaultCombo] = shortcut
                continue
            }
            if let enabled = entry["enabled"] as? NSNumber, !enabled.boolValue { continue }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3 else {
                result[shortcut.defaultCombo] = shortcut
                continue
            }
            let keyCode = parameters[1].intValue
            guard keyCode != 65535 else { continue }   // no key assigned
            let flags = NSEvent.ModifierFlags(rawValue: UInt(truncatingIfNeeded: parameters[2].intValue))
            result[KeyCombo(keyCode, flags)] = shortcut
        }
        return result
    }

    /// Keyboard layouts and input methods the user can switch between.
    static var keyboardInputSourceCount: Int {
        let filter = [kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
                      kTISPropertyInputSourceIsSelectCapable as String: true] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return 1 }
        return list.count
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Modifier sets offered for arranging windows.
enum SnapModifierPreset: String, CaseIterable, Identifiable {
    case controlOption, controlCommand, optionCommand, controlOptionCommand

    var id: String { rawValue }

    var flags: NSEvent.ModifierFlags {
        switch self {
        case .controlOption: return [.control, .option]
        case .controlCommand: return [.control, .command]
        case .optionCommand: return [.option, .command]
        case .controlOptionCommand: return [.control, .option, .command]
        }
    }

    var display: String { KeyCombo.symbols(for: flags) }
}

/// System-wide shortcuts via Carbon's RegisterEventHotKey: no permission needed and the
/// key press is not passed on to the frontmost app.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Registration {
        let ref: EventHotKeyRef
        let combo: KeyCombo
        let owner: String
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    /// Shortcuts that could not be registered (taken by another app), per owner.
    private(set) var failures: [String: [KeyCombo]] = [:]
    private static let signature: OSType = 0x544C_474B   // "TLGK"

    /// Registers a shortcut; returns false (and remembers the failure) when it is not available.
    @discardableResult
    func register(_ combo: KeyCombo, owner: String, handler: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()
        if registrations.values.contains(where: { $0.combo == combo }) {
            logWarning("Shortcut \(combo.display) is already used inside the app (\(owner))")
            failures[owner, default: []].append(combo)
            return false
        }
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers,
                                         EventHotKeyID(signature: HotKeyCenter.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            logWarning("Shortcut \(combo.display) could not be registered (status \(status)); probably used by another app")
            failures[owner, default: []].append(combo)
            return false
        }
        registrations[id] = Registration(ref: ref, combo: combo, owner: owner, handler: handler)
        return true
    }

    func unregisterAll(owner: String) {
        for (id, registration) in registrations where registration.owner == owner {
            UnregisterEventHotKey(registration.ref)
            registrations[id] = nil
        }
        failures[owner] = nil
    }

    func registeredCombos(owner: String) -> [KeyCombo] {
        registrations.values.filter { $0.owner == owner }.map(\.combo)
    }

    fileprivate func fire(_ id: UInt32) {
        registrations[id]?.handler()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), hotKeyEventHandler, 1, &spec, nil, nil)
        if status == noErr {
            handlerInstalled = true
        } else {
            logError("Could not install the shortcut handler (status \(status))")
        }
    }
}

/// C callback for Carbon hot key events.
private func hotKeyEventHandler(_ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return status }
    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated { HotKeyCenter.shared.fire(id) }
    }
    return noErr
}
