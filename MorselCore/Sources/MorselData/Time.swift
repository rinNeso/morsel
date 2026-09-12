import Foundation
import MorselCore

/// Timestamps are ISO8601 UTC with fractional seconds, matching
/// `docs/schema.sql` and the format the React Native build already wrote, so
/// existing rows stay readable.
///
/// `ISO8601FormatStyle` rather than `ISO8601DateFormatter`: the formatter is a
/// reference type with shared mutable state, which Swift 6 rightly refuses to
/// let us hold in a global. The format style is a Sendable value type.
private let secondStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt)
private let fractionalStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)

/// The milliseconds are split off with integer arithmetic and appended by hand
/// rather than handed to the format style. Going through
/// `Date(timeIntervalSince1970: ms / 1000)` means the sub-second part lands on
/// a binary double that can't represent it exactly (…862 becomes …8619999…),
/// and the style truncates rather than rounds — quietly shaving a millisecond
/// off a stored timestamp. Integer math can't drift.
func iso(from millis: Millis) -> String {
    let seconds = millis >= 0 ? millis / 1000 : -((-millis + 999) / 1000)
    let subMs = millis - seconds * 1000

    var text = Date(timeIntervalSince1970: Double(seconds)).formatted(secondStyle)
    text.removeLast() // the trailing "Z"
    return text + String(format: ".%03dZ", subMs)
}

func millis(fromISO string: String) -> Millis? {
    guard let date = try? Date(string, strategy: fractionalStyle) else { return nil }
    // Rounding here is safe in the other direction: parsing ".862" yields
    // 1800000000.8619999…, which rounds back to the millisecond we wrote.
    return Millis((date.timeIntervalSince1970 * 1000).rounded())
}
