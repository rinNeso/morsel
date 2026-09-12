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
    @State private var syncing = false
    @State private var syncMessage: String?
    @State private var basis: ForecastBasis = .current
    @State private var editingGoal = false

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
                            summary.revealOnScroll()
                            PredictionsPanel(points: points, trendKg: trend.last?.trend, basis: $basis)
                                .revealOnScroll()
                            if let goal = settings.goalKg, let start = points.first?.kg,
                               let current = trend.last?.trend {
                                MilestonePanel(startKg: start, goalKg: goal, currentKg: current)
                                    .revealOnScroll()
                            }
                            TrendTilesPanel(points: points).revealOnScroll()
                            chart.revealOnScroll()
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
                    Menu {
                        Button("Add weigh-in", systemImage: "plus") { entering = true }
                        Button("Goal and milestones", systemImage: "flag") { editingGoal = true }
                        if HealthKitWeights.isAvailable {
                            Button("Import from Apple Health", systemImage: "heart") {
                                Task { await syncHealth() }
                            }
                            .disabled(syncing)
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .alert("Apple Health", isPresented: syncAlert) {
                Button("OK") { syncMessage = nil }
            } message: {
                Text(syncMessage ?? "")
            }
            .sheet(isPresented: $editingGoal) { GoalSheet() }
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

    private var syncAlert: Binding<Bool> {
        Binding(get: { syncMessage != nil }, set: { if !$0 { syncMessage = nil } })
    }

    private func syncHealth() async {
        guard let store else { return }
        syncing = true
        defer { syncing = false }
        do {
            let result = try await HealthKitWeights().sync(into: store)
            await load()
            syncMessage = result.added == 0 && result.skipped == 0
                ? "No weight samples found in Health."
                : "Imported \(result.added) weigh-in\(result.added == 1 ? "" : "s")."
                    + (result.skipped > 0 ? " \(result.skipped) day\(result.skipped == 1 ? "" : "s") already recorded, left alone." : "")
        } catch {
            syncMessage = error.localizedDescription
        }
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

/// Goal, target rate and how many waypoints to break the journey into.
private struct GoalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var goalText = ""
    @State private var rateText = ""
    @State private var count = 10

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Goal weight", text: $goalText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text(settings.weightUnit.suffix).foregroundStyle(.secondary)
                    }
                    Stepper("Milestones: \(count)", value: $count, in: 1...20)
                } footer: {
                    Text("Milestones are evenly spaced between your first weigh-in and your goal. The next one is usually closer than the goal, which is the point of them.")
                }

                Section {
                    HStack {
                        TextField("Target rate", text: $rateText)
                            .keyboardType(.decimalPad)
                            .monospacedDigit()
                        Text("\(settings.weightUnit.suffix)/week").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Optional. The rate you are aiming for, so forecasts can be run against it as well as against the rate you are actually achieving.")
                }
            }
            .navigationTitle("Goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .onAppear {
            if let goal = settings.goalKg {
                goalText = String(format: "%.1f", settings.weightUnit.convert(goal))
            }
            if let rate = settings.commitmentKgPerWeek {
                rateText = String(format: "%.2f", settings.weightUnit.convert(rate))
            }
            count = settings.milestoneCount
        }
    }

    private func save() {
        let goal = Double(goalText.replacingOccurrences(of: ",", with: ".")).map {
            settings.weightUnit.toKilograms($0)
        }
        // A rate is a difference, so it converts by scale alone.
        let rate = Double(rateText.replacingOccurrences(of: ",", with: ".")).map {
            settings.weightUnit.toKilograms($0)
        }
        settings.setGoal(kg: goal, commitmentKgPerWeek: rate.map { -abs($0) }, milestoneCount: count)
        dismiss()
    }
}
