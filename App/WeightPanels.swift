import MorselCore
import SwiftUI

/// Which rate drives the forecasts. Three different questions: what my recent
/// pace implies, what my whole history implies, and what I said I was aiming
/// for. Borrowed from Happy Scale, which gets this right — one control,
/// three genuinely distinct answers.
enum ForecastBasis: String, CaseIterable, Identifiable {
    case current, overall, commitment

    var id: String { rawValue }

    var label: String {
        switch self {
        case .current: "Current"
        case .overall: "Overall"
        case .commitment: "Commitment"
        }
    }
}

// MARK: - Predictions

struct PredictionsPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    let points: [WeightPoint]
    let trendKg: Double?
    @Binding var basis: ForecastBasis

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("PREDICTIONS")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            Picker("Basis", selection: $basis) {
                ForEach(ForecastBasis.allCases) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)

            if let rate = ratePerWeek {
                Text(String(
                    format: "At %.2f %@/week:",
                    abs(settings.weightUnit.convert(rate)), settings.weightUnit.suffix
                ))
                .font(.subheadline)
                .foregroundStyle(theme.dim)

                forecastRow("In 7 days", weight: forecast(days: 7))
                forecastRow("In 30 days", weight: forecast(days: 30))
                if let goal = settings.goalKg {
                    goalRow(goalKg: goal, ratePerWeek: rate)
                }
            } else {
                Text(unavailableReason)
                    .font(.subheadline)
                    .foregroundStyle(theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    private var unavailableReason: String {
        switch basis {
        case .commitment: "Set a target rate to forecast against it."
        default: "A few more weigh-ins and a forecast becomes meaningful."
        }
    }

    private var ratePerWeek: Double? {
        switch basis {
        case .current: rateOfChange(points, windowDays: 30)?.kgPerWeek
        case .overall: rateOfChange(points, windowDays: 100_000)?.kgPerWeek
        case .commitment: settings.commitmentKgPerWeek
        }
    }

    /// Forecasts run forward from today's trend at the chosen rate, rather than
    /// using the fitted intercept — so "in 7 days" is relative to where you
    /// actually are now.
    private func forecast(days: Int) -> Double? {
        guard let trendKg, let rate = ratePerWeek else { return nil }
        return trendKg + (rate / 7) * Double(days)
    }

    private func forecastRow(_ label: String, weight: Double?) -> some View {
        HStack {
            Text(label).foregroundStyle(theme.dim)
            Spacer()
            Text(weight.map { settings.weightUnit.format($0) } ?? "—")
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(theme.text)
        }
        .font(.subheadline)
    }

    /// A range rather than a single day. Two weeks of bathroom-scale noise
    /// cannot support a specific date, and `projectToGoal` returns the cone the
    /// data actually earns.
    @ViewBuilder
    private func goalRow(goalKg: Double, ratePerWeek: Double) -> some View {
        let projection = projectToGoal(points, goalKg: goalKg, windowDays: 30)
        HStack(alignment: .firstTextBaseline) {
            Text("Goal").foregroundStyle(theme.dim)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(settings.weightUnit.format(goalKg))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
                if let earliest = projection.earliest, let latest = projection.latest {
                    Text("\(Self.pretty(earliest)) – \(Self.pretty(latest))")
                        .font(.caption)
                        .foregroundStyle(theme.dim)
                } else if let reason = projection.reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(theme.dim)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
    }

    private static func pretty(_ day: String) -> String {
        guard let number = dayNumber(day) else { return day }
        return Date(timeIntervalSince1970: Double(number) * 86_400)
            .formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Milestones

struct MilestonePanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    let startKg: Double
    let goalKg: Double
    let currentKg: Double

    private var all: [Milestone] {
        milestones(startKg: startKg, goalKg: goalKg, count: settings.milestoneCount, currentKg: currentKg)
    }

    @State private var swept = false

    private var next: Milestone? { all.first { !$0.reached } }
    private var reachedCount: Int { all.filter(\.reached).count }

    /// Progress toward the *next* milestone, not toward the goal. Proximity is
    /// the motivating part — "0.4 to go" lands where "9 to goal" doesn't.
    private var progress: Double {
        guard let next else { return 1 }
        let previous = all.first { $0.index == next.index - 1 }?.targetKg ?? startKg
        let span = next.targetKg - previous
        guard span != 0 else { return 1 }
        return min(max((currentKg - previous) / span, 0), 1)
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("PROGRESS")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                // The rotation goes on the arcs individually, never on the
                // stack: rotating the container turns the label on its side
                // along with it.
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(theme.track, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(135))
                Circle()
                    .trim(from: 0, to: 0.75 * (swept ? progress : 0))
                    .stroke(theme.accent, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                    .rotationEffect(.degrees(135))
                    .onScrollVisibilityChange(threshold: 0.3) { visible in
                        guard visible, !swept else { return }
                        // Slightly longer than the panel fade, so the arc is
                        // still filling once the card has settled.
                        withAnimation(.smooth(duration: 0.9)) { swept = true }
                    }
                    .task {
                        try? await Task.sleep(for: .milliseconds(700))
                        if !swept { withAnimation(.smooth(duration: 0.9)) { swept = true } }
                    }

                VStack(spacing: 2) {
                    if let next {
                        Text("MILESTONE \(next.index)")
                            .font(.caption.weight(.semibold))
                            .kerning(1)
                            .foregroundStyle(theme.dim)
                        Text(settings.weightUnit.format(next.targetKg))
                            .font(.system(size: 34, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(theme.text)
                    } else {
                        Text("Goal reached")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .containerRelativeFrame(.horizontal) { width, _ in min(width * 0.62, 280) }

            if let next {
                let remaining = abs(currentKg - next.targetKg)
                HStack {
                    stat(settings.weightUnit.format(currentKg), "now")
                    stat("\(Int((progress * 100).rounded()))%", "of the way")
                    stat(settings.weightUnit.format(remaining), "to go")
                }
            }

            HStack(spacing: 6) {
                ForEach(all, id: \.index) { milestone in
                    Circle()
                        .fill(milestone.reached ? theme.accent : theme.track)
                        .frame(height: 8)
                }
            }

            Text("\(reachedCount) OF \(all.count) MILESTONES")
                .font(.caption.weight(.semibold))
                .kerning(0.8)
                .foregroundStyle(theme.dim)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(theme.text)
            Text(label)
                .font(.caption2)
                .foregroundStyle(theme.dim)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Trend tiles

struct TrendTilesPanel: View {
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    let points: [WeightPoint]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WEIGHT TRENDS")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            HStack(spacing: 8) {
                tile(trendChange(points, overDays: 7), "in 7 days")
                tile(trendChange(points, overDays: 30), "in 30 days")
                tile(trendChange(points, overDays: 90), "in 90 days")
                tile(trendChangeAllTime(points), "all time")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    /// Green for down, red for up — an explicit owner decision, recorded in
    /// CLAUDE.md. It holds up here because these are *trend* deltas: a gain
    /// shown in red is a real direction rather than one heavy dinner.
    private func tile(_ change: Double?, _ label: String) -> some View {
        let losing = (change ?? 0) < 0
        let colour: Color = change == nil ? theme.dim : (losing ? .green : .red)

        return VStack(spacing: 4) {
            OdometerNumber(value: change.map { abs(settings.weightUnit.convert($0)) })
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(change == nil ? "no data" : (losing ? "lost" : "gained"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
            Text(label)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(colour.opacity(0.85), in: .rect(cornerRadius: 12))
    }
}

// MARK: - Reveal

/// Eases a panel in the first time it is meaningfully on screen, and never
/// again — scrolling past repeatedly should not keep replaying it.
///
/// Deliberately gentle: a short fade and a small rise. These panels are read
/// every morning, and something showy on the first viewing becomes something
/// tiresome by the tenth.
struct RevealOnScroll: ViewModifier {
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 14)
            .onScrollVisibilityChange(threshold: 0.2) { visible in
                guard visible, !shown else { return }
                withAnimation(.smooth(duration: 0.5)) { shown = true }
            }
            // Safety net. If the panel never registers a visibility change —
            // content shorter than the screen, or a scroll view that never
            // reports — it must still end up visible rather than invisible
            // forever.
            .task {
                try? await Task.sleep(for: .milliseconds(700))
                if !shown { withAnimation(.smooth(duration: 0.5)) { shown = true } }
            }
    }
}

extension View {
    func revealOnScroll() -> some View { modifier(RevealOnScroll()) }
}

/// Counts up from zero the first time the tile is seen.
///
/// `contentTransition(.numericText:)` was the obvious tool and the wrong one:
/// it animates the transition *between two strings*, so 0.0 to 5.6 is a single
/// roll lasting a frame or two and reads as a cross-fade. The mechanical part
/// of an odometer is passing through everything in between.
///
/// `Animatable` gets that: SwiftUI interpolates `animatableData` once per
/// frame, so the text is re-rendered the whole way up and the tenths digit
/// visibly spins while the units climb.
///
/// Eased out rather than linear, so it decelerates into its final value the way
/// a real dial settles instead of stopping dead. Monospaced digits are not
/// optional — proportional figures change width as they count, and the tile
/// would jitter sideways the entire time.
private struct CountingNumber: View, Animatable {
    var value: Double

    // nonisolated because SwiftUI drives this from its animation machinery
    // rather than the main actor, and it touches nothing isolated.
    nonisolated var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(String(format: "%.1f", value))
            .monospacedDigit()
    }
}

private struct OdometerNumber: View {
    let value: Double?

    @State private var displayed: Double = 0

    var body: some View {
        Group {
            if value == nil {
                Text("—").monospacedDigit()
            } else {
                CountingNumber(value: displayed)
            }
        }
        .onScrollVisibilityChange(threshold: 0.3) { visible in
            guard visible, let value, displayed == 0 else { return }
            withAnimation(.easeOut(duration: 1.2)) { displayed = value }
        }
        .task {
            try? await Task.sleep(for: .milliseconds(700))
            guard let value, displayed == 0 else { return }
            withAnimation(.easeOut(duration: 1.2)) { displayed = value }
        }
    }
}
