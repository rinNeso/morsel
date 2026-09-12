import Charts
import MorselCore
import MorselData
import SwiftUI

struct WeightScreen: View {
    @Environment(\.mealStore) private var store
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    @State private var points: [WeightPoint] = []
    @State private var trend: [TrendPoint] = []
    @State private var rate: Rate?
    @State private var loaded = false
    @State private var entering = false

    var body: some View {
        NavigationStack {
            Group {
                if points.isEmpty && loaded {
                    ContentUnavailableView(
                        "No weigh-ins yet",
                        systemImage: "scalemass",
                        description: Text("Add one to start the trend.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            summary
                            chart
                        }
                        .padding(16)
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationTitle("Weight")
            .background(theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add", systemImage: "plus") { entering = true }
                }
            }
            .sheet(isPresented: $entering) {
                WeighInSheet { weighIn in
                    Task {
                        try? await store?.recordWeight(weighIn)
                        await load()
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TREND")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            if let latest = trend.last {
                Text(settings.weightUnit.format(latest.trend))
                    .font(.system(size: 44, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.text)
            }

            // Reported, never judged: a rate is a rate, and a plateau is the
            // confidence interval straddling zero rather than a verdict.
            Text(rateDescription)
                .font(.subheadline)
                .foregroundStyle(theme.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    private var rateDescription: String {
        guard let rate else {
            return "A few more weigh-ins and a rate becomes meaningful."
        }
        if rate.plateau {
            // Straight from the maths: the interval includes zero, so no
            // direction is distinguishable from flat.
            return "Holding steady — the last \(rate.n) weigh-ins can't tell a direction from flat."
        }
        let perWeek = settings.weightUnit.convert(abs(rate.kgPerWeek))
        let direction = rate.kgPerWeek < 0 ? "down" : "up"
        return String(
            format: "%@ %.2f %@/week over the last %d weigh-ins.",
            direction, perWeek, settings.weightUnit.suffix, rate.n
        )
    }

    // MARK: Chart

    private var chart: some View {
        Chart {
            // Raw readings stay visible: the trend is the smoothing, not a
            // replacement for what was actually measured.
            ForEach(trend, id: \.date) { point in
                if let date = Self.date(point.date) {
                    PointMark(
                        x: .value("Day", date),
                        y: .value("Weight", settings.weightUnit.convert(point.kg))
                    )
                    .foregroundStyle(theme.dim.opacity(0.45))
                    .symbolSize(24)
                }
            }
            ForEach(trend, id: \.date) { point in
                if let date = Self.date(point.date) {
                    LineMark(
                        x: .value("Day", date),
                        y: .value("Trend", settings.weightUnit.convert(point.trend)),
                        series: .value("Series", "trend")
                    )
                    .foregroundStyle(theme.accent)
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.5))
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: false))
        .frame(height: 240)
        .padding(16)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    private static func date(_ day: String) -> Date? {
        dayNumber(day).map { Date(timeIntervalSince1970: Double($0) * 86_400) }
    }

    private func load() async {
        guard let store else { loaded = true; return }
        points = (try? await store.weightPoints()) ?? []
        trend = ewmaTrend(points)
        rate = rateOfChange(points)
        loaded = true
    }
}

/// Entry is deliberately its own sheet rather than an inline field: a weigh-in
/// is a deliberate act, and the date matters as much as the number.
private struct WeighInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    let onSave: (WeighIn) -> Void

    @State private var day = Date()
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $day, in: ...Date(), displayedComponents: .date)
                HStack {
                    TextField("Weight", text: $text)
                        .keyboardType(.decimalPad)
                        .monospacedDigit()
                    Text(settings.weightUnit.suffix)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("New weigh-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(parsed == nil)
                }
            }
        }
        .presentationDetents([.height(220)])
    }

    private var parsed: Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return settings.weightUnit.toKilograms(value)
    }

    private func save() {
        guard let kg = parsed else { return }
        // Stored against the local day, because "which day did I weigh in" is a
        // calendar question rather than an instant.
        let components = Calendar.current.dateComponents([.year, .month, .day], from: day)
        let measuredOn = String(
            format: "%04d-%02d-%02d",
            components.year ?? 0, components.month ?? 0, components.day ?? 0
        )
        onSave(WeighIn(measuredOn: measuredOn, kg: kg))
        dismiss()
    }
}
