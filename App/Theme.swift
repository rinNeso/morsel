import SwiftUI
import UIKit

/// Colour carries state: the accent means permission to eat, amber means
/// resting, grey means paused. Never red — the app reports, it does not scold.
/// (The accent itself becomes user-customisable; resting and paused stay fixed
/// because they carry meaning the app relies on, not personalisation.)
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

    static let bg = dynamic(light: 0xFBF8F4, dark: 0x12100E)
    static let card = dynamic(light: 0xFFFFFF, dark: 0x1E1B18)
    static let text = dynamic(light: 0x22201D, dark: 0xF2EEE8)
    static let dim = dynamic(light: 0x7A736B, dark: 0x9A9187)
    static let track = dynamic(light: 0xEAE3D9, dark: 0x2C2823)
    static let resting = Color(rgb: 0xC98B3A)
    static let paused = dynamic(light: 0xB5ADA2, dark: 0x5A544C)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(uiColor: UIColor(rgb: rgb))
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// mm:ss for durations held in milliseconds.
func mmss(_ ms: Int) -> String {
    let total = Int((Double(ms) / 1000).rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}
