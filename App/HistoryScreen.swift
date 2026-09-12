import MorselData
import SwiftUI

struct HistoryScreen: View {
    @Environment(\.mealStore) private var store
    @Environment(MealTimerModel.self) private var timer

    @State private var meals: [MealHistoryEntry] = []
    @State private var loaded = false
    @State private var pending: PendingDelete?
    @State private var selection = Set<Int64>()
    @State private var editMode: EditMode = .inactive

    /// A deleted meal is gone for good — no backend, no trash — so deletes are
    /// held for a few seconds rather than confirmed up front. HIG prefers undo
    /// to a confirmation dialog, and holding means the rows are only really
    /// removed once the window closes. If the app dies first the meals survive,
    /// which is the right way for this to fail.
    private struct PendingDelete {
        /// Kept with their original positions so undo puts them back where
        /// they were rather than at the end.
        let entries: [(meal: MealHistoryEntry, index: Int)]
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
                    List(selection: $selection) {
                        ForEach(meals) { meal in
                            MealRow(meal: meal)
                        }
                        .onDelete(perform: deleteSwiped)
                    }
                    .listStyle(.insetGrouped)
                    .environment(\.editMode, $editMode)
                }
            }
            .navigationTitle("Meal history")
            .background(Palette.bg)
            .refreshable { await load() }
            .toolbar {
                if !meals.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
                if editMode.isEditing && !selection.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Delete (\(selection.count))", role: .destructive) {
                            deleteSelected()
                        }
                    }
                }
            }
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
            Text(pending?.entries.count == 1 ? "Meal deleted" : "\(pending?.entries.count ?? 0) meals deleted")
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

    // MARK: Deleting

    private func deleteSwiped(at offsets: IndexSet) {
        hold(offsets.sorted())
    }

    private func deleteSelected() {
        let indices = meals.indices.filter { selection.contains(meals[$0].id) }
        hold(indices)
        selection.removeAll()
        editMode = .inactive
    }

    /// Pull the rows out of the list now, commit them to the store once the
    /// undo window closes.
    private func hold(_ indices: [Int]) {
        guard !indices.isEmpty else { return }

        // Only one batch can be in flight; starting another commits the first
        // rather than silently dropping it.
        commitPending()

        let entries = indices.map { (meal: meals[$0], index: $0) }
        withAnimation {
            // Remove from the back so earlier indices stay valid.
            for index in indices.sorted(by: >) {
                meals.remove(at: index)
            }
            pending = PendingDelete(entries: entries)
        }

        pending?.task = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await commit(entries.map(\.meal))
        }
    }

    private func undo() {
        guard let pending else { return }
        pending.task?.cancel()
        withAnimation {
            // Front to back, so each index lands where it originally sat.
            for entry in pending.entries.sorted(by: { $0.index < $1.index }) {
                meals.insert(entry.meal, at: min(entry.index, meals.count))
            }
            self.pending = nil
        }
    }

    /// Flush a still-pending batch straight through, without waiting out the
    /// rest of its window.
    private func commitPending() {
        guard let pending else { return }
        pending.task?.cancel()
        let meals = pending.entries.map(\.meal)
        self.pending = nil
        Task { await commit(meals) }
    }

    private func commit(_ deleted: [MealHistoryEntry]) async {
        for meal in deleted {
            try? await store?.deleteMeal(id: meal.id)
        }
        withAnimation { pending = nil }
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
