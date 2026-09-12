/// Meal timer state machine.
///
/// The loop is self-pacing rather than metronomic:
///
///     READY  ──(you tap: bite taken, food down)──▶  RESTING
///       ▲                                              │
///       └─────────(minimum rest elapsed, haptic)───────┘
///
/// The rest interval starts when you confirm a bite, not when the cue fires.
/// A metronome would keep cueing while you were still chewing, so a slow chew
/// would eat into its own rest period — punishing the exact behaviour the app
/// exists to encourage. Here the timer waits for you, and meal duration emerges
/// from real chewing speed instead of being imposed.
///
/// Two implementation rules that matter more than they look:
///
///  1. ALL TIME IS DERIVED FROM WALL-CLOCK TIMESTAMPS, never accumulated by
///     counting ticks. iOS suspends timers when the app backgrounds or the
///     screen locks, so a tick counter silently loses time and the meal's
///     record becomes fiction. Deriving from a passed-in `now` means
///     backgrounding costs nothing: on resume the state is simply recomputed.
///
///  2. THE REDUCER IS PURE AND TAKES `now` AS AN ARGUMENT. No `Date()` inside.
///     That keeps it fully testable without fake clocks, lets this whole module
///     run under `swift test` on Linux with no Xcode, and lets the UI replay or
///     rehydrate a meal from storage.
///
/// Durations are milliseconds throughout, matching `docs/schema.sql`'s
/// convention of storing durations in ms internally and converting only at the
/// display or persistence boundary.

public typealias Millis = Int

public enum Phase: String, Sendable, Equatable, CaseIterable {
    case idle, ready, resting, paused, ended
}

public struct BiteRecord: Sendable, Equatable, Identifiable {
    public var id: Int { seq }

    public let seq: Int
    /// When the app said you could take this bite.
    public let cuedAt: Millis
    /// When you confirmed the food went back down.
    public let takenAt: Millis
    /// Time from cue to confirmation — how long the bite itself took.
    public let biteMs: Millis
    /// Actual rest before this bite, pause time excluded. Nil for the first bite.
    public let restMs: Millis?
    /// Confirmed before the rest interval had elapsed.
    public let early: Bool

    public init(seq: Int, cuedAt: Millis, takenAt: Millis, biteMs: Millis, restMs: Millis?, early: Bool) {
        self.seq = seq
        self.cuedAt = cuedAt
        self.takenAt = takenAt
        self.biteMs = biteMs
        self.restMs = restMs
        self.early = early
    }
}

public enum MealEvent: Sendable, Equatable {
    case start(restMs: Millis? = nil)
    case confirmBite
    case tick
    case pause
    case resume
    case setRest(Millis)
    case end
    case reset
}

public let defaultRestMs: Millis = 30_000

public struct MealState: Sendable, Equatable {
    public var phase: Phase
    /// Configured minimum rest between bites.
    public var restMs: Millis
    public var startedAt: Millis?
    public var endedAt: Millis?
    /// Start of the current rest window; nil unless resting.
    public var restStartedAt: Millis?
    /// Start of the current ready window, for measuring time-to-confirm.
    public var readyAt: Millis?
    public var pausedAt: Millis?
    public var phaseBeforePause: Phase?
    /// Paused milliseconds across the whole meal.
    public var pausedTotalMs: Millis
    /// Paused milliseconds inside the current rest window only.
    public var restPausedMs: Millis
    public var bites: [BiteRecord]

    public init(restMs: Millis = defaultRestMs) {
        self.phase = .idle
        self.restMs = restMs
        self.startedAt = nil
        self.endedAt = nil
        self.restStartedAt = nil
        self.readyAt = nil
        self.pausedAt = nil
        self.phaseBeforePause = nil
        self.pausedTotalMs = 0
        self.restPausedMs = 0
        self.bites = []
    }
}

// MARK: - Selectors

extension MealState {
    /// Milliseconds left in the current rest window. Zero when resting is
    /// complete, and zero in every other phase. Paused time is excluded, so
    /// pausing genuinely suspends the countdown rather than letting it run
    /// down in the background.
    public func remainingRest(now: Millis) -> Millis {
        if phase == .resting, let restStartedAt {
            let elapsed = now - restStartedAt - restPausedMs
            return max(0, restMs - elapsed)
        }
        if phase == .paused, phaseBeforePause == .resting,
           let restStartedAt, let pausedAt {
            let elapsed = pausedAt - restStartedAt - restPausedMs
            return max(0, restMs - elapsed)
        }
        return 0
    }

    /// 0...1 progress through the current rest window, for the countdown ring.
    public func restProgress(now: Millis) -> Double {
        guard restMs > 0 else { return 1 }
        let effective = phase == .paused ? phaseBeforePause : phase
        guard effective == .resting else { return 1 }
        return 1 - Double(remainingRest(now: now)) / Double(restMs)
    }

    /// Elapsed meal time excluding pauses.
    public func activeDuration(now: Millis) -> Millis {
        guard let startedAt else { return 0 }
        let end = endedAt ?? now
        let pausedNow = (phase == .paused && pausedAt != nil) ? now - pausedAt! : 0
        return max(0, end - startedAt - pausedTotalMs - pausedNow)
    }
}

// MARK: - Reducer

extension MealState {
    public func reduced(by event: MealEvent, now: Millis) -> MealState {
        var next = self

        switch event {
        case .start(let newRestMs):
            guard phase == .idle else { return self }
            // The first bite is available immediately — nothing to rest from.
            next = MealState(restMs: newRestMs ?? restMs)
            next.phase = .ready
            next.startedAt = now
            next.readyAt = now
            return next

        case .confirmBite:
            guard phase == .ready || phase == .resting else { return self }

            let early = phase == .resting
            // While resting, `readyAt` is nil — an early bite was never cued, so
            // its cue and confirmation collapse onto the same instant. That
            // identity is what history reads back as "early".
            let cuedAt = readyAt ?? now
            let servedRest: Millis? = (bites.last != nil && restStartedAt != nil)
                ? max(0, now - restStartedAt! - restPausedMs)
                : nil

            next.bites.append(
                BiteRecord(
                    seq: bites.count + 1,
                    cuedAt: cuedAt,
                    takenAt: now,
                    biteMs: early ? 0 : max(0, now - (readyAt ?? now)),
                    restMs: servedRest,
                    early: early
                )
            )
            next.phase = .resting
            next.restStartedAt = now
            next.restPausedMs = 0
            next.readyAt = nil
            return next

        case .tick:
            // The only implicit transition: rest completing promotes resting -> ready.
            guard phase == .resting, remainingRest(now: now) <= 0 else { return self }
            next.phase = .ready
            next.readyAt = now
            return next

        case .pause:
            guard phase == .ready || phase == .resting else { return self }
            next.phase = .paused
            next.phaseBeforePause = phase
            next.pausedAt = now
            return next

        case .resume:
            guard phase == .paused, let pausedAt else { return self }
            let delta = max(0, now - pausedAt)
            let back = phaseBeforePause ?? .ready
            next.phase = back
            next.pausedAt = nil
            next.phaseBeforePause = nil
            next.pausedTotalMs += delta
            next.restPausedMs += (back == .resting ? delta : 0)
            // Resuming into READY restarts the time-to-confirm clock; the paused
            // stretch was not you deciding to take a bite.
            next.readyAt = (back == .ready) ? now : readyAt
            return next

        case .setRest(let value):
            guard value > 0 else { return self }
            next.restMs = value
            return next

        case .reset:
            // Clear back to idle, keeping the chosen rest interval as the default.
            return MealState(restMs: restMs)

        case .end:
            guard phase != .idle, phase != .ended else { return self }
            let pausedNow = (phase == .paused && pausedAt != nil) ? now - pausedAt! : 0
            next.phase = .ended
            next.endedAt = now
            next.pausedAt = nil
            next.phaseBeforePause = nil
            next.pausedTotalMs += pausedNow
            return next
        }
    }
}

// MARK: - Summary

public struct MealSummary: Sendable, Equatable {
    public let biteCount: Int
    public let durationMs: Millis
    public let pausedMs: Millis
    public let earlyBites: Int
    public let meanRestMs: Double?
    public let meanBiteMs: Double?
    /// Change in mean time-to-confirm from the first third of the meal to the
    /// last third, as a ratio. Below 1 means you sped up as the meal went on,
    /// which is the failure mode the app exists to surface. Nil when there are
    /// too few bites to split meaningfully.
    public let paceDrift: Double?
}

extension MealState {
    public func summary(now: Millis) -> MealSummary {
        let rests = bites.compactMap(\.restMs)
        let cued = bites.filter { !$0.early }

        func mean(_ xs: [Millis]) -> Double? {
            guard !xs.isEmpty else { return nil }
            return Double(xs.reduce(0, +)) / Double(xs.count)
        }

        var paceDrift: Double?
        // Needs at least two bites per third for the comparison to mean anything.
        if cued.count >= 6 {
            let third = cued.count / 3
            let first = mean(cued.prefix(third).map(\.biteMs))
            let last = mean(cued.suffix(third).map(\.biteMs))
            if let first, let last, first > 0, last != 0 {
                paceDrift = last / first
            }
        }

        return MealSummary(
            biteCount: bites.count,
            durationMs: activeDuration(now: now),
            pausedMs: pausedTotalMs,
            earlyBites: bites.filter(\.early).count,
            meanRestMs: mean(rests),
            meanBiteMs: mean(cued.map(\.biteMs)),
            paceDrift: paceDrift
        )
    }
}
