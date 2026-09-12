import MorselData
import Observation
import SwiftUI

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

    @ObservationIgnored private let store: MealStore?

    private static let accentKey = "accent_color"
    private static let themeKey = "theme_mode"

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
    }

    func setAccent(_ color: Color) {
        accent = color
        let hex = color.hexString
        Task { try? await store?.setSetting(Self.accentKey, to: hex) }
    }

    func setThemeMode(_ mode: ThemeMode) {
        themeMode = mode
        Task { try? await store?.setSetting(Self.themeKey, to: mode.rawValue) }
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
