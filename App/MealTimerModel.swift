import Foundation
import MorselCore
import MorselData
import Observation
import UIKit

/// Thin observable shell around `MorselCore.MealState`. All the logic lives in
/// the pure reducer; this owns only the things a reducer can't: the clock, the
/// haptics, keeping the screen awake, and writing to the store.
@MainActor
@Observable
final class MealTimerModel {
    private(set) var state = MealState()

    /// The rest interval chosen on the idle screen, remembered across meals.
    var restSeconds: Int = 30

    /// Fullness given on the end-of-meal screen, cleared with the meal.
    private(set) var fullness: Int?

    /// What was eaten. A flat total and free text until v3 brings real food
    /// logging — but recorded now, because a meal eaten without it is
    /// incomplete forever.
    var kcalText: String = ""
    var mealNotes: String = ""


    @ObservationIgnored private let store: MealStore?
    @ObservationIgnored private var mealID: Int64?
    /// How many of `state.bites` are already on disk.
    @ObservationIgnored private var persistedBites = 0
    /// Persistence runs off the main thread, but the writes are order-
    /// dependent — a bite can't be inserted before its meal row exists, and
    /// `bite_count` is last-writer-wins — so they're chained rather than fired
    /// off independently.
    @ObservationIgnored private var lastWrite: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(store: MealStore?) {
        self.store = store
    }

    var isActive: Bool {
        switch state.phase {
        case .ready, .resting, .paused: true
        case .idle, .ended: false
        }
    }

    static func nowMillis() -> Millis {
        Millis(Date().timeIntervalSince1970 * 1000)
    }

    func send(_ event: MealEvent) {
        let before = state.phase
        state = state.reduced(by: event, now: Self.nowMillis())
        handle(transitionFrom: before)
    }

    /// Re-derive everything from the wall clock. Called on foreground, where an
    /// arbitrary amount of time may have passed with no timer running at all.
    func refresh() {
        send(.tick)
    }

    /// Pick up a meal that was started and never ended.
    ///
    /// Without this, killing the app mid-meal stranded the row: history could
    /// show it but nothing could finish it, and the owner was left with a meal
    /// they could not interact with. Restoring it into the live timer means a
    /// meal row always has a timer behind it, so the stranded state stops
    /// existing rather than merely becoming visible.
    ///
    /// Deliberately not a prompt. The timer is the thing to interact with, and
    /// End meal is already right there if the meal is stale.
    func restoreInProgressMeal() async {
        guard let store, state.phase == .idle,
              let resumed = try? await store.resumableMeal()
        else { return }

        mealID = resumed.id
        persistedBites = resumed.state.bites.count
        restSeconds = max(1, resumed.state.restMs / 1000)
        // Straight to the tick so the wall clock decides whether the rest
        // window already elapsed while the app was gone.
        state = resumed.state.reduced(by: .tick, now: Self.nowMillis())

        UIApplication.shared.isIdleTimerDisabled = isActive
        scheduleNextTick()
    }

    func confirmBite() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        send(.confirmBite)
    }

    /// Rated on the end-of-meal screen, and re-rateable until the meal is
    /// dismissed — a second thought a minute later is a better reading than
    /// the first tap, not worse.
    func setFullness(_ rating: Int) {
        fullness = rating
        UISelectionFeedbackGenerator().selectionChanged()
        guard let store else { return }
        enqueueWrite { [weak self] in
            guard let id = self?.mealID else { return }
            try? await store.setFullness(rating, mealID: id)
        }
    }

    /// Set when a meal ends, so the check-in can be scheduled against it. Held
    /// separately from `mealID`, which is cleared once the meal is dismissed.
    private(set) var justEndedMealID: Int64?

    /// Called as the fields are edited on the end-of-meal screen.
    func saveNutrition() {
        guard let store else { return }
        let kcal = Int(kcalText.trimmingCharacters(in: .whitespaces))
        let notes = mealNotes.trimmingCharacters(in: .whitespaces)
        enqueueWrite { [weak self] in
            guard let id = self?.mealID else { return }
            try? await store.setNutrition(kcal: kcal, notes: notes, mealID: id)
        }
    }

    private func handle(transitionFrom before: Phase) {
        // Fire the cue exactly once per resting -> ready transition.
        if before == .resting, state.phase == .ready {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        // The phone sits on the table for the whole meal; a screen that sleeps
        // mid-meal is worse than no timer.
        UIApplication.shared.isIdleTimerDisabled = isActive

        persist(transitionFrom: before)
        scheduleNextTick()
    }

    // MARK: Persistence

    /// Written as the meal progresses rather than only at the end, so a crash
    /// or force-quit mid-meal still leaves the bites taken so far on disk.
    private func persist(transitionFrom before: Phase) {
        guard let store else { return }

        // idle -> ready is only ever produced by `.start`; every other arrival
        // in `.ready` is a normal resting -> ready cue.
        if before == .idle, state.phase == .ready, let startedAt = state.startedAt {
            let restMs = state.restMs
            persistedBites = 0
            enqueueWrite { [weak self] in
                self?.mealID = try? await store.createMeal(startedAt: startedAt, restMs: restMs)
            }
        }

        // Keyed on the bite count rather than a phase transition. An early bite
        // is confirmed while already resting, so resting -> resting never
        // registered as a transition and those bites were silently never
        // written — losing exactly the impatience the app sets out to record.
        if state.bites.count > persistedBites, let bite = state.bites.last {
            persistedBites = state.bites.count
            enqueueWrite { [weak self] in
                guard let id = self?.mealID else { return }
                try? await store.insert(bite: bite, mealID: id)
            }
        }

        if before != .ended, state.phase == .ended, let endedAt = state.endedAt {
            let pausedMs = state.pausedTotalMs
            enqueueWrite { [weak self] in
                guard let id = self?.mealID else { return }
                try? await store.endMeal(id: id, endedAt: endedAt, pausedMs: pausedMs)
                self?.justEndedMealID = id
            }
        }

        if state.phase == .idle {
            mealID = nil
            fullness = nil
            persistedBites = 0
            kcalText = ""
            mealNotes = ""
        }
    }

    private func enqueueWrite(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastWrite
        lastWrite = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    // MARK: Ticking

    /// Only RESTING has an implicit transition to wait for, and we know exactly
    /// when it lands — so schedule one wake-up for that instant rather than
    /// polling. If the app is suspended before it fires, `refresh()` on
    /// foreground recomputes from the wall clock and nothing is lost.
    private func scheduleNextTick() {
        tickTask?.cancel()
        guard state.phase == .resting else { return }

        let remaining = state.remainingRest(now: Self.nowMillis())
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(max(remaining, 1)))
            guard !Task.isCancelled else { return }
            self?.send(.tick)
        }
    }
}
