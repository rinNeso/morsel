import MorselData
import SwiftUI

struct HistoryScreen: View {
    @Environment(\.mealStore) private var store
    @Environment(MealTimerModel.self) private var timer

    @State private var meals: [MealHistoryEntry] = []
    @State private var loaded = false
    @State private var pending: PendingDelete?

    /// A deleted meal is gone for good — no backend, no trash — so the delete
    /// is held for a few seconds rather than confirmed up front. HIG prefers
    /// undo to a confirmation dialog, and holding it means the row is only
    /// really removed once the window closes. If the app dies first the meal
    /// survives, which is the right way for this to fail.
    private struct PendingDelete {
        let meal: MealHistoryEntry
        let index: Int
        var task: Task<Void, Never>?
    }

    private static let undoWindow: Duration = .seconds(5)

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
                    List {
                        ForEach(meals) { meal in
                            MealRow(meal: meal)
                        }
                        .onDelete(perform: delete)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Meal history")
            .background(Palette.bg)
            .refreshable { await load() }
            .overlay(alignment: .bottom) {
                if pending != nil { undoBanner }
            }
        }
        .task { await load() }
        // A meal finishing is the one thing that adds a row, so reload when the
        // timer falls back to idle rather than polling.
        .onChange(of: timer.state.phase) { _, phase in
            if phase == .idle { Task { await load() } }
        }
    }

    private var undoBanner: some View {
        HStack {
            Text("Meal deleted")
                .font(.subheadline)
                .foregroundStyle(Palette.text)
            Spacer()
            Button("Undo") { undo() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func load() async {
        guard let store else { loaded = true; return }
        meals = (try? await store.listMeals()) ?? []
        loaded = true
    }

    private func delete(at offsets: IndexSet) {
        guard let index = offsets.first, index < meals.count else { return }

        // Only one delete can be in flight; a second swipe commits the first
        // rather than silently dropping it.
        commitPending()

        let meal = meals[index]
        withAnimation {
            meals.remove(at: index)
            pending = PendingDelete(meal: meal, index: index)
        }

        pending?.task = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await commit(meal)
        }
    }

    private func undo() {
        guard let pending else { return }
        pending.task?.cancel()
        withAnimation {
            meals.insert(pending.meal, at: min(pending.index, meals.count))
            self.pending = nil
        }
    }

    /// Flush a still-pending delete straight through, without waiting out the
    /// rest of its window.
    private func commitPending() {
        guard let pending else { return }
        pending.task?.cancel()
        let meal = pending.meal
        self.pending = nil
        Task { await commit(meal) }
    }

    private func commit(_ meal: MealHistoryEntry) async {
        try? await store?.deleteMeal(id: meal.id)
        if pending?.meal.id == meal.id {
            withAnimation { pending = nil }
        }
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
