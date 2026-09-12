import Testing
@testable import MorselCore

private let t0: Millis = 1_800_000_000_000

/// Drive the machine through (event, timeOffsetMs) pairs.
private func run(_ state: MealState, _ steps: [(MealEvent, Millis)]) -> MealState {
    steps.reduce(state) { $0.reduced(by: $1.0, now: t0 + $1.1) }
}

@Suite("Rest begins on confirmation, not on the cue")
struct RestStartsOnConfirmation {
    @Test("first bite needs no rest, and a slow chew doesn't eat its own rest window")
    func restStartsOnConfirm() {
        var s = run(MealState(restMs: 30_000), [(.start(), 0)])
        #expect(s.phase == .ready, "starts READY — first bite needs no rest")

        // Chew for 12s before putting the food down.
        s = run(s, [(.confirmBite, 12_000)])
        #expect(s.phase == .resting, "confirming moves to RESTING")
        #expect(s.remainingRest(now: t0 + 12_000) == 30_000, "full rest remains at moment of confirm")

        // The 12s chew must NOT have counted against the rest window.
        #expect(s.remainingRest(now: t0 + 30_000) == 12_000, "slow chew did not consume rest")
        #expect(s.bites[0].biteMs == 12_000, "time-to-confirm recorded")

        #expect(run(s, [(.tick, 41_999)]).phase == .resting, "still RESTING 1ms early")
        #expect(run(s, [(.tick, 42_000)]).phase == .ready, "READY exactly when rest elapses")
    }
}

@Suite("Backgrounding: no ticks for 5 minutes")
struct Backgrounding {
    @Test("recovers from the wall clock alone")
    func recoversFromWallClock() {
        var s = run(MealState(restMs: 30_000), [(.start(), 0), (.confirmBite, 1_000)])
        // Screen locks; timers stop. Next tick arrives 5 minutes later.
        s = run(s, [(.tick, 301_000)])
        #expect(s.phase == .ready, "recovers to READY from wall clock alone")
        #expect(s.activeDuration(now: t0 + 301_000) == 301_000, "no time lost from the meal")
    }
}

@Suite("Pause genuinely suspends the countdown")
struct Pausing {
    @Test("a 60s conversation does not drain the rest window")
    func pauseSuspendsCountdown() {
        var s = run(MealState(restMs: 30_000), [(.start(), 0), (.confirmBite, 0), (.pause, 10_000)])
        #expect(s.remainingRest(now: t0 + 10_000) == 20_000, "20s left when paused")
        #expect(s.remainingRest(now: t0 + 70_000) == 20_000, "paused countdown does not drain")

        s = run(s, [(.resume, 70_000)])
        #expect(s.remainingRest(now: t0 + 70_000) == 20_000, "resumes with 20s still owed")
        #expect(run(s, [(.tick, 89_999)]).phase == .resting, "not ready 1ms early post-pause")

        s = run(s, [(.tick, 90_000)])
        #expect(s.phase == .ready, "ready after full rest served")
        #expect(s.pausedTotalMs == 60_000, "paused time tracked separately")
        #expect(s.activeDuration(now: t0 + 90_000) == 30_000, "paused time excluded from duration")
    }
}

@Suite("Early bites are recorded, not silently dropped")
struct EarlyBites {
    @Test("impatience becomes data rather than a blocked button")
    func earlyBiteRecorded() {
        // Impatient: 5s into a 30s rest.
        let s = run(MealState(restMs: 30_000), [(.start(), 0), (.confirmBite, 0), (.confirmBite, 5_000)])
        #expect(s.bites.count == 2 && s.bites[1].early, "early bite captured")
        #expect(s.bites[1].restMs == 5_000, "actual rest served recorded")
        #expect(s.remainingRest(now: t0 + 5_000) == 30_000, "rest window restarts from the early bite")
        #expect(!s.bites[0].early, "first bite not flagged early")
    }
}

@Suite("Ring progress")
struct RingProgress {
    @Test("progress runs 0...1 and clamps")
    func progressClamps() {
        let s = run(MealState(restMs: 30_000), [(.start(), 0), (.confirmBite, 0)])
        #expect(s.restProgress(now: t0) == 0, "0% at start of rest")
        #expect(s.restProgress(now: t0 + 15_000) == 0.5, "50% halfway")
        #expect(s.restProgress(now: t0 + 30_000) == 1, "100% at completion")
        #expect(s.restProgress(now: t0 + 99_000) == 1, "clamped past completion")

        let ready = run(s, [(.tick, 30_000)])
        #expect(ready.restProgress(now: t0 + 30_000) == 1, "full ring while READY")
    }
}

@Suite("Pace drift detection (the failure mode we care about)")
struct PaceDrift {
    @Test("drift below 1 flags speeding up through the meal")
    func driftDetectsSpeedUp() {
        // Nine bites: chews slow at first (8s), collapsing to 2s by the end.
        let chews: [Millis] = [8000, 8000, 8000, 5000, 5000, 5000, 2000, 2000, 2000]
        var s = run(MealState(restMs: 1_000), [(.start(), 0)])
        var t: Millis = 0
        for chew in chews {
            t += chew
            s = s.reduced(by: .confirmBite, now: t0 + t)
            t += 1_000
            s = s.reduced(by: .tick, now: t0 + t)
        }
        s = s.reduced(by: .end, now: t0 + t)

        let summary = s.summary(now: t0 + t)
        #expect(summary.biteCount == 9, "all bites counted")
        #expect(summary.earlyBites == 0, "no early bites")
        #expect((summary.paceDrift ?? 1) < 1, "drift < 1 flags speeding up")
        #expect(abs((summary.paceDrift ?? 0) - 0.25) < 1e-9, "drift is the 2s/8s ratio")
    }
}

@Suite("Guards and degenerate transitions")
struct Guards {
    @Test("invalid transitions are ignored rather than corrupting state")
    func guardsHold() {
        let idle = MealState()
        #expect(idle.restMs == defaultRestMs, "default rest is 30s")
        #expect(idle.reduced(by: .confirmBite, now: t0).phase == .idle, "CONFIRM before START ignored")
        #expect(idle.reduced(by: .resume, now: t0).phase == .idle, "RESUME while unpaused ignored")
        #expect(idle.reduced(by: .end, now: t0).phase == .idle, "END while idle ignored")

        let started = idle.reduced(by: .start(), now: t0)
        #expect(started.reduced(by: .start(), now: t0 + 5).startedAt == t0, "double START ignored")
        #expect(started.reduced(by: .setRest(0), now: t0).restMs == defaultRestMs, "SET_REST rejects zero")
        #expect(started.reduced(by: .setRest(45_000), now: t0).restMs == 45_000, "SET_REST accepts positive")

        let ended = started.reduced(by: .end, now: t0 + 1_000)
        #expect(ended.reduced(by: .confirmBite, now: t0 + 2_000).bites.isEmpty, "ENDed meal is frozen")
        #expect(ended.activeDuration(now: t0 + 999_000) == 1_000, "ended duration stops accruing")
        #expect(ended.summary(now: t0 + 1_000).meanRestMs == nil, "empty meal summarises safely")
    }
}

@Suite("RESET returns to idle, keeping the chosen interval")
struct Reset {
    @Test("reset clears the meal but keeps the configured rest")
    func resetKeepsInterval() {
        let s = run(MealState(restMs: 45_000), [
            (.start(), 0),
            (.confirmBite, 1_000),
            (.end, 60_000),
            (.reset, 61_000),
        ])
        #expect(s.phase == .idle, "back to idle")
        #expect(s.bites.isEmpty, "bites cleared")
        #expect(s.restMs == 45_000, "chosen rest interval retained")
        #expect(s.startedAt == nil && s.endedAt == nil, "timestamps cleared")
    }
}
