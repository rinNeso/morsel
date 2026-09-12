import SwiftUI
import UIKit

/// Concrete colours for one appearance, rather than dynamic `UIColor`s that
/// resolve from the trait environment.
///
/// That distinction is the whole point: a dynamic colour's *value* never
/// changes when the appearance flips — only the way it resolves — so SwiftUI
/// has nothing to interpolate and the switch can only ever snap or crossfade.
/// Building the palette from an explicit `dark` flag means flipping that flag
/// inside `withAnimation` gives a real interpolation, passing through the
/// intermediate shades on the way.
///
/// Colour carries state: the accent means permission to eat, the resting colour
/// means waiting, grey means paused. The app reports; it does not scold.
struct Theme: Equatable {
    let bg: Color
    let card: Color
    let text: Color
    let dim: Color
    let track: Color
    /// Fixed grey regardless of accent — "nothing is happening" is not a
    /// matter of taste.
    let paused: Color
    /// The user's chosen accent: permission to eat.
    let accent: Color
    /// Waiting between bites. Follows the accent unless set separately.
    let resting: Color

    init(dark: Bool, accent: Color, resting: Color) {
        bg = dark ? Color(rgb: 0x12100E) : Color(rgb: 0xFBF8F4)
        card = dark ? Color(rgb: 0x1E1B18) : Color(rgb: 0xFFFFFF)
        text = dark ? Color(rgb: 0xF2EEE8) : Color(rgb: 0x22201D)
        dim = dark ? Color(rgb: 0x9A9187) : Color(rgb: 0x7A736B)
        track = dark ? Color(rgb: 0x2C2823) : Color(rgb: 0xEAE3D9)
        paused = dark ? Color(rgb: 0x5A544C) : Color(rgb: 0xB5ADA2)
        self.accent = accent
        self.resting = resting
    }
}

extension EnvironmentValues {
    @Entry var theme = Theme(
        dark: false,
        accent: Palette.defaultAccent,
        resting: Palette.defaultAccent
    )
}

enum Palette {
    /// The original "ready" green — the intuitive default before any customising.
    static let defaultAccent = Color(rgb: 0x4C9A5E)
    static let defaultAccentHex = "#4C9A5E"

    /// Starting points offered in Settings, not a limit — the picker takes any
    /// colour at all.
    static let accentPresets: [Color] = [
        defaultAccent,
        Color(rgb: 0x3B82C4), // blue
        Color(rgb: 0x7C5CBF), // purple
        Color(rgb: 0x2E9E96), // teal
        Color(rgb: 0xD97B29), // orange
        Color(rgb: 0xC4527A), // pink
        Color(rgb: 0xC0392B), // red
    ]
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

/// mm:ss for durations held in milliseconds.
func mmss(_ ms: Int) -> String {
    let total = Int((Double(ms) / 1000).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
