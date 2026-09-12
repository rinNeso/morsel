import MorselData
import Observation
import SwiftUI

/// Kilograms are what get stored; this is purely how they are shown.
enum WeightUnit: String, CaseIterable, Identifiable {
    case kg, lb

    var id: String { rawValue }
    var label: String { self == .kg ? "Kilograms" : "Pounds" }
    var suffix: String { rawValue }

    private static let poundsPerKilogram = 2.20462262

    func convert(_ kilograms: Double) -> Double {
        self == .kg ? kilograms : kilograms * Self.poundsPerKilogram
    }

    func toKilograms(_ value: Double) -> Double {
        self == .kg ? value : value / Self.poundsPerKilogram
    }

    func format(_ kilograms: Double) -> String {
        String(format: "%.1f %@", convert(kilograms), suffix)
    }
}

enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    /// Nil hands the decision back to the OS.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// User-facing personalisation, persisted in the `setting` table.
///
/// The accent is the "ready" colour — permission to eat — and is deliberately
/// unrestricted: the owner explicitly chose to allow any colour including red,
/// which the app itself never uses. Resting (amber) and paused (grey) stay
/// fixed, because those carry meaning rather than taste.
@MainActor
@Observable
final class AppSettings {
    private(set) var accent: Color = Palette.defaultAccent
    private(set) var themeMode: ThemeMode = .system

    /// Nil means "follow the accent", which is the default. Set it to break the
    /// resting ring out into its own colour.
    private(set) var restingColor: Color?

    private(set) var weightUnit: WeightUnit = .lb

    /// Where you're headed. Nil until set — milestones and a goal date have
    /// nothing to say without it.
    private(set) var goalKg: Double?
    /// The rate you're aiming for, as opposed to the one you're achieving.
    private(set) var commitmentKgPerWeek: Double?
    private(set) var milestoneCount: Int = 10

    /// Post-meal check-in. On by default, but permission is only requested at
    /// the first meal's end, so nothing is asked for before it is useful.
    private(set) var checkInEnabled = true
    /// ~45 min sits near the peak of satiety signalling; see CheckInScheduler.
    private(set) var checkInMinutes = 45

    /// What the resting ring actually draws with.
    var resolvedRestingColor: Color { restingColor ?? accent }

    @ObservationIgnored private let store: MealStore?

    private static let accentKey = "accent_color"
    private static let themeKey = "theme_mode"
    private static let restingKey = "resting_color"
    private static let weightUnitKey = "weight_unit"
    private static let goalKey = "goal_kg"
    private static let commitmentKey = "commitment_kg_per_week"
    private static let milestoneCountKey = "milestone_count"
    private static let checkInKey = "check_in_enabled"
    private static let checkInMinutesKey = "check_in_minutes"
    /// Sentinel for "follow the accent", so the stored value distinguishes
    /// "deliberately following" from "never set".
    private static let matchAccent = "match"

    init(store: MealStore?) {
        self.store = store
    }

    func load() async {
        guard let store else { return }
        if let hex = try? await store.setting(Self.accentKey), let color = Color(hexString: hex) {
            accent = color
        }
        if let raw = try? await store.setting(Self.themeKey), let mode = ThemeMode(rawValue: raw) {
            themeMode = mode
        }
        if let raw = try? await store.setting(Self.restingKey), raw != Self.matchAccent {
            restingColor = Color(hexString: raw)
        }
        if let raw = try? await store.setting(Self.weightUnitKey), let unit = WeightUnit(rawValue: raw) {
            weightUnit = unit
        }
        if let raw = try? await store.setting(Self.goalKey) { goalKg = Double(raw) }
        if let raw = try? await store.setting(Self.commitmentKey) { commitmentKgPerWeek = Double(raw) }
        if let raw = try? await store.setting(Self.milestoneCountKey), let count = Int(raw) {
            milestoneCount = count
        }
        if let raw = try? await store.setting(Self.checkInKey) { checkInEnabled = raw == "1" }
        if let raw = try? await store.setting(Self.checkInMinutesKey), let minutes = Int(raw) {
            checkInMinutes = minutes
        }
    }

    func setAccent(_ color: Color) {
        accent = color
        let hex = color.hexString
        Task { try? await store?.setSetting(Self.accentKey, to: hex) }
    }

    func setThemeMode(_ mode: ThemeMode) {
        // 0.3s to sit with the system's own trait-change fade rather than
        // alongside it — the status bar clock crossfading is the visible
        // reference. Apple does not publish that duration as a constant, so
        // this is matched by eye against the convention.
        //
        // Only carries views whose colours SwiftUI resolves and interpolates;
        // the window-level change `.preferredColorScheme` drives belongs to the
        // system, so some chrome switches on its own schedule regardless.
        withAnimation(.easeInOut(duration: 0.3)) {
            themeMode = mode
        }
        Task { try? await store?.setSetting(Self.themeKey, to: mode.rawValue) }
    }

    func setGoal(kg: Double?, commitmentKgPerWeek: Double?, milestoneCount: Int) {
        goalKg = kg
        self.commitmentKgPerWeek = commitmentKgPerWeek
        self.milestoneCount = max(1, milestoneCount)
        let count = self.milestoneCount
        Task { [weak self] in
            guard let store = self?.store else { return }
            try? await store.setSetting(Self.goalKey, to: kg.map { "\($0)" } ?? "")
            try? await store.setSetting(Self.commitmentKey, to: commitmentKgPerWeek.map { "\($0)" } ?? "")
            try? await store.setSetting(Self.milestoneCountKey, to: "\(count)")
        }
    }

    func setCheckIn(enabled: Bool, minutes: Int) {
        checkInEnabled = enabled
        checkInMinutes = minutes
        Task { [weak self] in
            guard let store = self?.store else { return }
            try? await store.setSetting(Self.checkInKey, to: enabled ? "1" : "0")
            try? await store.setSetting(Self.checkInMinutesKey, to: "\(minutes)")
        }
    }

    func setWeightUnit(_ unit: WeightUnit) {
        weightUnit = unit
        Task { try? await store?.setSetting(Self.weightUnitKey, to: unit.rawValue) }
    }

    /// Pass nil to go back to following the accent.
    func setRestingColor(_ color: Color?) {
        restingColor = color
        let stored = color?.hexString ?? Self.matchAccent
        Task { try? await store?.setSetting(Self.restingKey, to: stored) }
    }
}

extension Color {
    /// `#RRGGBB`, the same shape the React Native build stored, so old rows
    /// stay readable.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return Palette.defaultAccentHex
        }
        return String(
            format: "#%02X%02X%02X",
            Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())
        )
    }

    init?(hexString: String) {
        var text = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(rgb: value)
    }
}
