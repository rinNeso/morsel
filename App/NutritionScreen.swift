import Charts
import MorselCore
import MorselData
import SwiftUI

/// Daily energy intake: today, the trailing week, and the history behind them.
///
/// Built on `meal.kcal`, which the end-of-meal prompt has been collecting since
/// before there was anywhere to look at it. Nothing here waits on the food
/// database — that makes logging easier, not charting possible.
struct NutritionScreen: View {
    @Environment(\.mealStore) private var store
    @Environment(\.theme) private var theme
    @Environment(AppSettings.self) private var settings

    @State private var days: [DayIntake] = []
    @State private var loaded = false
    @State private var editingGoal = false
    @State private var addingMeal = false

    var body: some View {
        NavigationStack {
            Group {
                if days.isEmpty && loaded {
                    ContentUnavailableView {
                        Label("Nothing logged yet", systemImage: "flame")
                    } description: {
                        Text("Calories are recorded at the end of a meal. You can also add a meal you ate without the timer.")
                    } actions: {
                        Button("Add a meal") { addingMeal = true }
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            todayPanel.revealOnScroll()
                            averagePanel.revealOnScroll()
                            chart.revealOnScroll()
                            recentDays.revealOnScroll()
                        }
                        .padding(16)
                        .padding(.bottom, 60)
                    }
                }
            }
            .navigationTitle("Calories")
            .background(theme.bg)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a meal", systemImage: "plus") { addingMeal = true }
                        Button("Daily goal", systemImage: "flag") { editingGoal = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $editingGoal) { KcalGoalSheet() }
            .sheet(isPresented: $addingMeal) {
                ManualMealSheet { startedAt, kcal, notes, fullness in
                    Task {
                        _ = try? await store?.recordManualMeal(
                            startedAt: startedAt, kcal: kcal, notes: notes, fullness: fullness
                        )
                        await load()
                    }
                }
            }
        }
        .task { await load() }
    }

    // MARK: Today

    private var todayPanel: some View {
        let entry = days.last(where: { $0.date == Self.localDay() })

        return VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            if let entry {
                Text("\(entry.kcal.formatted()) kcal")
                    .font(.system(size: 44, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(goalColour(entry.kcal) ?? theme.text)

                Text("\(entry.meals) meal\(entry.meals == 1 ? "" : "s") logged\(goalSuffix(entry.kcal))")
                    .font(.subheadline)
                    .foregroundStyle(theme.dim)
            } else {
                // Not "0 kcal". Nothing logged today is an absence, and printing
                // a zero would be the app asserting something it does not know.
                Text("Nothing logged")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(theme.dim)
                Text("Calories are entered at the end of a meal.")
                    .font(.subheadline)
                    .foregroundStyle(theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    // MARK: Trailing week

    private var averagePanel: some View {
        let average = trailingAverage(days, endingOn: Self.localDay(), windowDays: 7)

        return VStack(alignment: .leading, spacing: 10) {
            Text("LAST 7 DAYS")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            if let average {
                Text("\(Int(average.kcal.rounded()).formatted()) kcal/day")
                    .font(.system(size: 30, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(goalColour(Int(average.kcal.rounded())) ?? theme.text)

                // The mean is only as good as the days behind it, so it says how
                // many there were rather than implying a full week.
                Text(average.isComplete
                     ? "Every day logged."
                     : "Averaged over the \(average.daysLogged) day\(average.daysLogged == 1 ? "" : "s") that were logged, not all 7.")
                    .font(.subheadline)
                    .foregroundStyle(theme.dim)
            } else {
                Text("No days logged this week.")
                    .font(.subheadline)
                    .foregroundStyle(theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    // MARK: Chart

    private var chart: some View {
        let series = rollingMean(days, windowDays: 7)

        return VStack(alignment: .leading, spacing: 10) {
            Text("INTAKE OVER TIME")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            Chart {
                ForEach(series, id: \.date) { point in
                    if let date = Self.date(point.date) {
                        // Bars, not a line: a line between logged days would
                        // draw straight through the unlogged ones and invent
                        // intake for days nobody recorded.
                        BarMark(
                            x: .value("Day", date, unit: .day),
                            y: .value("Calories", point.kcal)
                        )
                        .foregroundStyle(theme.accent.opacity(0.35))
                    }
                }
                ForEach(series, id: \.date) { point in
                    if let date = Self.date(point.date) {
                        LineMark(
                            x: .value("Day", date, unit: .day),
                            y: .value("7-day average", point.mean),
                            series: .value("Series", "mean")
                        )
                        .foregroundStyle(theme.accent)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5))
                    }
                }
                if let goal = settings.goalKcal {
                    RuleMark(y: .value("Goal", goal))
                        .foregroundStyle(theme.dim.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .frame(minHeight: 200, idealHeight: 240, maxHeight: 340)

            Text("Bars are each day; the line is the 7-day average.")
                .font(.caption2)
                .foregroundStyle(theme.dim)
        }
        .padding(16)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    // MARK: History

    private var recentDays: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("HISTORY")
                .font(.caption.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(theme.dim)

            ForEach(days.reversed().prefix(14), id: \.date) { day in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.date(day.date)?.formatted(.dateTime.weekday(.wide).month().day()) ?? day.date)
                            .font(.subheadline)
                            .foregroundStyle(theme.text)
                        Text("\(day.meals) meal\(day.meals == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(theme.dim)
                    }
                    Spacer()
                    Text("\(day.kcal.formatted()) kcal")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(goalColour(day.kcal) ?? theme.text)
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(theme.card, in: .rect(cornerRadius: 16))
    }

    // MARK: Goal colour

    /// Green under the goal, red over it — the owner's second explicit override
    /// of "the app never chooses red on its own", recorded in CLAUDE.md and
    /// matching the weight tiles. Nil when no goal is set, which leaves every
    /// figure in the ordinary text colour: without a target there is no
    /// direction to report, and inventing one would be the app having an
    /// opinion about what the number should be.
    private func goalColour(_ kcal: Int) -> Color? {
        guard let goal = settings.goalKcal else { return nil }
        return kcal <= goal ? .green : .red
    }

    /// States the gap and stops. No "over budget", no verdict.
    private func goalSuffix(_ kcal: Int) -> String {
        guard let goal = settings.goalKcal else { return "" }
        let delta = kcal - goal
        if delta == 0 { return " · exactly on goal" }
        return delta < 0
            ? " · \((-delta).formatted()) under goal"
            : " · \(delta.formatted()) over goal"
    }

    // MARK: Dates

    /// Today as the store writes days: local `YYYY-MM-DD`.
    private static func localDay(_ moment: Date = Date()) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: moment)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(_ day: String) -> Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return Calendar.current.date(from: components)
    }

    private func load() async {
        guard let store else { return }
        days = (try? await store.dailyIntake()) ?? []
        loaded = true
    }
}

/// Records a meal that happened without the timer.
///
/// Only what was actually observed: when, how much, what it was, and optionally
/// how full it left you. No bites, no duration, no rest interval — those were
/// never measured, and offering fields for them would invite guesses into the
/// one table the pace analysis reads.
private struct ManualMealSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    let onSave: (Millis, Int?, String?, Int?) -> Void

    @State private var eatenAt = Date()
    @State private var kcalText = ""
    @State private var notes = ""
    @State private var fullness: Int?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("When", selection: $eatenAt, in: ...Date())
                } footer: {
                    Text("The day it lands on is the day it counts toward.")
                }

                Section("What you ate") {
                    HStack {
                        TextField("Calories", text: $kcalText)
                            .keyboardType(.numberPad)
                            .monospacedDigit()
                        Text("kcal")
                            .foregroundStyle(theme.dim)
                    }
                    TextField("Sandwich, coffee…", text: $notes, axis: .vertical)
                        .lineLimit(1...3)
                }

                Section {
                    Picker("How full afterwards", selection: $fullness) {
                        Text("Not rated").tag(Int?.none)
                        ForEach(1...10, id: \.self) { value in
                            Text("\(value)").tag(Int?.some(value))
                        }
                    }
                } footer: {
                    // Same stance the end-of-meal prompt takes: an unrated meal
                    // is honest, a guessed one is noise in the column that is
                    // supposed to mean something. Recalling it hours later is
                    // closer to guessing, so nothing is pre-selected.
                    Text("Optional. Leave it unrated rather than guessing.")
                }
            }
            .navigationTitle("Add a meal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(
                            Millis(eatenAt.timeIntervalSince1970 * 1000),
                            Int(kcalText),
                            notes.isEmpty ? nil : notes,
                            fullness
                        )
                        dismiss()
                    }
                }
            }
        }
    }
}

/// A single number, and the ability to clear it again. Deliberately plain:
/// the goal is the owner's business, and the app has no recommendation to make
/// about what it should be.
private struct KcalGoalSheet: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("2000", text: $text)
                            .keyboardType(.numberPad)
                            .monospacedDigit()
                        Text("kcal/day")
                            .foregroundStyle(theme.dim)
                    }
                } footer: {
                    Text("Days at or under the goal read green, days over read red. Leave it empty for no goal, and the figures stay plain.")
                }

                if settings.goalKcal != nil {
                    Button("Remove goal", role: .destructive) {
                        settings.setGoal(kcal: nil)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Daily goal")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        settings.setGoal(kcal: Int(text))
                        dismiss()
                    }
                }
            }
            .onAppear { text = settings.goalKcal.map { "\($0)" } ?? "" }
        }
    }
}
