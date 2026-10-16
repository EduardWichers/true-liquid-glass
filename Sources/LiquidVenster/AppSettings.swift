import Foundation

/// An sRGB colour with components in 0...1. Invalid input (NaN, out of range) is repaired.
struct WaterColor: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    static let `default` = WaterColor(red: 0.62, green: 0.84, blue: 0.98)

    init(red: Double, green: Double, blue: Double) {
        func fix(_ v: Double, _ fallback: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : fallback }
        self.red = fix(red, 0.62)
        self.green = fix(green, 0.84)
        self.blue = fix(blue, 0.98)
    }

    /// Reads `[r, g, b]` from the preferences; nil for anything else.
    init?(stored: Any?) {
        guard let values = stored as? [NSNumber], values.count == 3 else { return nil }
        let d = values.map(\.doubleValue)
        guard d.allSatisfy({ $0.isFinite }) else { return nil }
        self.init(red: d[0], green: d[1], blue: d[2])
    }

    var stored: [Double] { [red, green, blue] }

    func isClose(to other: WaterColor) -> Bool {
        abs(red - other.red) < 0.01 && abs(green - other.green) < 0.01 && abs(blue - other.blue) < 0.01
    }
}

struct WaterPreset: Identifiable {
    let key: L
    let color: WaterColor
    let strength: Double
    var id: String { key.rawValue }
    /// Name in the current language.
    var name: String { tr(key) }
}

/// User preferences, persisted in UserDefaults. Every value is validated on
/// load and on write so a corrupt preference can never produce NaN timings or colours.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static let speedRange: ClosedRange<Double> = 0.5...2.0
    static let strengthRange: ClosedRange<Double> = 0.0...1.0
    static let defaultStrength = 0.45

    static let presets: [WaterPreset] = [
        WaterPreset(key: .presetClear, color: WaterColor(red: 0.62, green: 0.84, blue: 0.98), strength: 0.45),
        WaterPreset(key: .presetSea, color: WaterColor(red: 0.16, green: 0.45, blue: 0.82), strength: 0.75),
        WaterPreset(key: .presetLagoon, color: WaterColor(red: 0.20, green: 0.82, blue: 0.78), strength: 0.65),
        WaterPreset(key: .presetGlacier, color: WaterColor(red: 0.80, green: 0.95, blue: 1.00), strength: 0.30),
        WaterPreset(key: .presetLemonade, color: WaterColor(red: 1.00, green: 0.84, blue: 0.30), strength: 0.60),
        WaterPreset(key: .presetRaspberry, color: WaterColor(red: 0.95, green: 0.30, blue: 0.52), strength: 0.70),
        WaterPreset(key: .presetCola, color: WaterColor(red: 0.42, green: 0.20, blue: 0.08), strength: 0.95),
    ]

    private enum Key {
        static let systemWide = "systemWideEnabled"
        static let speed = "animationSpeed"
        static let color = "waterColorRGB"
        static let strength = "waterColorStrength"
        static let reduceMotion = "respectReduceMotion"
        static let minimizeEffect = "minimizeEffectEnabled"
        static let closeEffect = "closeEffectEnabled"
    }

    private let defaults: UserDefaults

    /// Apply the effect to minimize buttons of all apps (needs permissions).
    @Published var systemWideEnabled: Bool {
        didSet { defaults.set(systemWideEnabled, forKey: Key.systemWide) }
    }

    /// Playback speed multiplier (1 = normal, 2 = twice as fast).
    @Published var speed: Double {
        didSet {
            let clamped = AppSettings.clamp(speed, to: AppSettings.speedRange, fallback: 1.0)
            if clamped != speed { speed = clamped; return }
            defaults.set(speed, forKey: Key.speed)
        }
    }

    /// Colour of the water (sRGB).
    @Published var waterColor: WaterColor {
        didSet { defaults.set(waterColor.stored, forKey: Key.color) }
    }

    /// How deeply coloured the water is: 0 = almost clear, 1 = strongly coloured (like syrup).
    @Published var colorStrength: Double {
        didSet {
            let clamped = AppSettings.clamp(colorStrength, to: AppSettings.strengthRange, fallback: AppSettings.defaultStrength)
            if clamped != colorStrength { colorStrength = clamped; return }
            defaults.set(colorStrength, forKey: Key.strength)
        }
    }

    /// Water effect for the yellow (minimize) button.
    @Published var minimizeEffectEnabled: Bool {
        didSet { defaults.set(minimizeEffectEnabled, forKey: Key.minimizeEffect) }
    }

    /// Evaporation effect for the red (close) button.
    @Published var closeEffectEnabled: Bool {
        didSet { defaults.set(closeEffectEnabled, forKey: Key.closeEffect) }
    }

    /// Skip the effect when "Reduce motion" is enabled in Accessibility settings.
    @Published var respectReduceMotion: Bool {
        didSet { defaults.set(respectReduceMotion, forKey: Key.reduceMotion) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.systemWide: true,
            Key.speed: 1.0,
            Key.strength: AppSettings.defaultStrength,
            Key.reduceMotion: true,
            Key.minimizeEffect: true,
            Key.closeEffect: true,
        ])
        systemWideEnabled = defaults.bool(forKey: Key.systemWide)
        speed = AppSettings.number(defaults, Key.speed, range: AppSettings.speedRange, fallback: 1.0)
        waterColor = WaterColor(stored: defaults.object(forKey: Key.color)) ?? .default
        colorStrength = AppSettings.number(defaults, Key.strength, range: AppSettings.strengthRange,
                                           fallback: AppSettings.defaultStrength)
        respectReduceMotion = defaults.bool(forKey: Key.reduceMotion)
        minimizeEffectEnabled = defaults.bool(forKey: Key.minimizeEffect)
        closeEffectEnabled = defaults.bool(forKey: Key.closeEffect)
    }

    func apply(_ preset: WaterPreset) {
        waterColor = preset.color
        colorStrength = preset.strength
    }

    /// The preset that matches the current colour, if any.
    var activePreset: WaterPreset? {
        AppSettings.presets.first { $0.color.isClose(to: waterColor) }
    }

    /// Reads a number; anything that is not a number (e.g. a hand-edited string) gives the fallback.
    private static func number(_ defaults: UserDefaults, _ key: String, range: ClosedRange<Double>, fallback: Double) -> Double {
        guard let value = defaults.object(forKey: key) as? NSNumber else { return fallback }
        return clamp(value.doubleValue, to: range, fallback: fallback)
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
