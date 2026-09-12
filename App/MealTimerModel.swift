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

    @ObservationIgnored private let store: MealStore?
    @ObservationIgnored private var mealID: Int64?
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
            enqueueWrite { [weak self] in
                self?.mealID = try? await store.createMeal(startedAt: startedAt, restMs: restMs)
            }
        }

        if state.phase == .resting, before != .resting, let bite = state.bites.last {
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
            }
        }

        if state.phase == .idle {
            mealID = nil
            fullness = nil
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
