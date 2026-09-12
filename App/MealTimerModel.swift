import Foundation
import MorselCore
import Observation
import UIKit

/// Thin observable shell around `MorselCore.MealState`. All the logic lives in
/// the pure reducer; this owns only the things a reducer can't: the clock, the
/// haptics, and keeping the screen awake.
@MainActor
@Observable
final class MealTimerModel {
    private(set) var state = MealState()

    /// The rest interval chosen on the idle screen, remembered across meals.
    var restSeconds: Int = 30

    @ObservationIgnored private var tickTask: Task<Void, Never>?

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

    private func handle(transitionFrom before: Phase) {
        // Fire the cue exactly once per resting -> ready transition.
        if before == .resting, state.phase == .ready {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }

        // The phone sits on the table for the whole meal; a screen that sleeps
        // mid-meal is worse than no timer.
        UIApplication.shared.isIdleTimerDisabled = isActive

        scheduleNextTick()
    }

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
