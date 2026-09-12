import MorselData
import SwiftUI

struct HistoryScreen: View {
    @Environment(\.mealStore) private var store
    @Environment(MealTimerModel.self) private var timer

    @State private var meals: [MealHistoryEntry] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if meals.isEmpty && loaded {
                    ContentUnavailableView(
                        "No meals yet",
                        systemImage: "fork.knife",
                        description: Text("Start one from the Timer tab.")
                    )
                } else {
                    List(meals) { meal in
                        MealRow(meal: meal)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Meal history")
            .background(Palette.bg)
            .refreshable { await load() }
        }
        .task { await load() }
        // A meal finishing is the one thing that adds a row, so reload when the
        // timer falls back to idle rather than polling.
        .onChange(of: timer.state.phase) { _, phase in
            if phase == .idle { Task { await load() } }
        }
    }

    private func load() async {
        guard let store else { loaded = true; return }
        meals = (try? await store.listMeals()) ?? []
        loaded = true
    }
}

private struct MealRow: View {
    let meal: MealHistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(Date(timeIntervalSince1970: Double(meal.startedAt) / 1000)
                    .formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(.headline)
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(mmss(meal.durationMs))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Palette.dim)
            }

            HStack(spacing: 0) {
                stat("\(meal.biteCount)", "bites")
                stat(meal.meanRestMs.map { "\(Int(($0 / 1000).rounded()))s" } ?? "—", "avg pace")
                stat("\(meal.earlyBites)", "early")
                stat(meal.fullness.map { "\($0)/10" } ?? "—", "fullness")
            }
        }
        .padding(.vertical, 6)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(Palette.text)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
