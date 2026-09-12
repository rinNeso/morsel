/**
 * Meal timer state machine.
 *
 * The loop is self-pacing rather than metronomic:
 *
 *   READY  ──(you tap: bite taken, utensil down)──▶  RESTING
 *     ▲                                                 │
 *     └──────────(minimum rest elapsed, haptic)─────────┘
 *
 * The rest interval starts when you CONFIRM a bite, not when the cue fires.
 * A metronome would keep cueing while you were still chewing, so a slow chew
 * would eat into its own rest period — punishing the exact behaviour the app
 * exists to encourage. Here the timer waits for you, and meal duration emerges
 * from real chewing speed instead of being imposed.
 *
 * Two implementation rules that matter more than they look:
 *
 *  1. ALL TIME IS DERIVED FROM WALL-CLOCK TIMESTAMPS, never accumulated by
 *     counting ticks. iOS suspends JS timers when the app backgrounds or the
 *     screen locks, so a tick counter silently loses time and the meal's
 *     record becomes fiction. Deriving from Date.now() means backgrounding
 *     costs nothing: on resume the state is simply recomputed.
 *
 *  2. THE REDUCER IS PURE AND TAKES `now` AS AN ARGUMENT. No Date.now() inside.
 *     That keeps it fully testable without fake timers, and lets the UI replay
 *     or rehydrate a meal from storage.
 */

export type Phase = "idle" | "ready" | "resting" | "paused" | "ended";

export interface BiteRecord {
  seq: number;
  /** When the app said you could take this bite. */
  cuedAt: number;
  /** When you confirmed the utensil was down. */
  takenAt: number;
  /** Time from cue to confirmation — how long the bite itself took. */
  biteMs: number;
  /** Actual rest before this bite, pause time excluded. Null for the first bite. */
  restMs: number | null;
  /** Confirmed before the rest interval had elapsed. */
  early: boolean;
}

export interface MealState {
  phase: Phase;
  /** Configured minimum rest between bites. */
  restMs: number;
  startedAt: number | null;
  endedAt: number | null;
  /** Start of the current rest window; null unless resting. */
  restStartedAt: number | null;
  /** Start of the current ready window, for measuring time-to-confirm. */
  readyAt: number | null;
  pausedAt: number | null;
  phaseBeforePause: Phase | null;
  /** Paused milliseconds across the whole meal. */
  pausedTotalMs: number;
  /** Paused milliseconds inside the current rest window only. */
  restPausedMs: number;
  bites: BiteRecord[];
}

export type Event =
  | { type: "START"; restMs?: number }
  | { type: "CONFIRM_BITE" }
  | { type: "TICK" }
  | { type: "PAUSE" }
  | { type: "RESUME" }
  | { type: "SET_REST"; restMs: number }
  | { type: "END" };

export const DEFAULT_REST_MS = 30_000;

export function initialState(restMs: number = DEFAULT_REST_MS): MealState {
  return {
    phase: "idle",
    restMs,
    startedAt: null,
    endedAt: null,
    restStartedAt: null,
    readyAt: null,
    pausedAt: null,
    phaseBeforePause: null,
    pausedTotalMs: 0,
    restPausedMs: 0,
    bites: [],
  };
}

/**
 * Milliseconds left in the current rest window. Zero when resting is complete,
 * and zero in every other phase. Paused time is excluded, so pausing genuinely
 * suspends the countdown rather than letting it run down in the background.
 */
export function remainingRestMs(s: MealState, now: number): number {
  if (s.phase === "resting" && s.restStartedAt !== null) {
    const elapsed = now - s.restStartedAt - s.restPausedMs;
    return Math.max(0, s.restMs - elapsed);
  }
  if (s.phase === "paused" && s.phaseBeforePause === "resting" && s.restStartedAt !== null && s.pausedAt !== null) {
    const elapsed = s.pausedAt - s.restStartedAt - s.restPausedMs;
    return Math.max(0, s.restMs - elapsed);
  }
  return 0;
}

/** 0..1 progress through the current rest window, for the countdown ring. */
export function restProgress(s: MealState, now: number): number {
  if (s.restMs <= 0) return 1;
  const phase = s.phase === "paused" ? s.phaseBeforePause : s.phase;
  if (phase !== "resting") return 1;
  return 1 - remainingRestMs(s, now) / s.restMs;
}

/** Elapsed meal time excluding pauses. */
export function activeDurationMs(s: MealState, now: number): number {
  if (s.startedAt === null) return 0;
  const end = s.endedAt ?? now;
  const pausedNow =
    s.phase === "paused" && s.pausedAt !== null ? now - s.pausedAt : 0;
  return Math.max(0, end - s.startedAt - s.pausedTotalMs - pausedNow);
}

export function reduce(s: MealState, e: Event, now: number): MealState {
  switch (e.type) {
    case "START": {
      if (s.phase !== "idle") return s;
      // The first bite is available immediately — there is nothing to rest from.
      return {
        ...initialState(e.restMs ?? s.restMs),
        phase: "ready",
        startedAt: now,
        readyAt: now,
      };
    }

    case "CONFIRM_BITE": {
      if (s.phase !== "ready" && s.phase !== "resting") return s;

      const early = s.phase === "resting";
      const cuedAt = early ? (s.readyAt ?? now) : (s.readyAt ?? now);
      const prev = s.bites[s.bites.length - 1];

      // Rest actually served before this bite, excluding pauses.
      const restMs =
        prev && s.restStartedAt !== null
          ? Math.max(0, now - s.restStartedAt - s.restPausedMs)
          : null;

      const bite: BiteRecord = {
        seq: s.bites.length + 1,
        cuedAt,
        takenAt: now,
        // An early bite was never cued, so time-to-confirm is not meaningful.
        biteMs: early ? 0 : Math.max(0, now - (s.readyAt ?? now)),
        restMs,
        early,
      };

      return {
        ...s,
        phase: "resting",
        bites: [...s.bites, bite],
        restStartedAt: now,
        restPausedMs: 0,
        readyAt: null,
      };
    }

    case "TICK": {
      // The only implicit transition: rest completing promotes resting -> ready.
      if (s.phase !== "resting") return s;
      if (remainingRestMs(s, now) > 0) return s;
      return { ...s, phase: "ready", readyAt: now, restStartedAt: s.restStartedAt };
    }

    case "PAUSE": {
      if (s.phase !== "ready" && s.phase !== "resting") return s;
      return { ...s, phase: "paused", phaseBeforePause: s.phase, pausedAt: now };
    }

    case "RESUME": {
      if (s.phase !== "paused" || s.pausedAt === null) return s;
      const delta = Math.max(0, now - s.pausedAt);
      const back = s.phaseBeforePause ?? "ready";
      return {
        ...s,
        phase: back,
        pausedAt: null,
        phaseBeforePause: null,
        pausedTotalMs: s.pausedTotalMs + delta,
        restPausedMs: back === "resting" ? s.restPausedMs + delta : s.restPausedMs,
        // Resuming into READY restarts the time-to-confirm clock; the paused
        // stretch was not you deciding to take a bite.
        readyAt: back === "ready" ? now : s.readyAt,
      };
    }

    case "SET_REST": {
      if (e.restMs <= 0) return s;
      return { ...s, restMs: e.restMs };
    }

    case "END": {
      if (s.phase === "idle" || s.phase === "ended") return s;
      const pausedNow =
        s.phase === "paused" && s.pausedAt !== null ? now - s.pausedAt : 0;
      return {
        ...s,
        phase: "ended",
        endedAt: now,
        pausedAt: null,
        phaseBeforePause: null,
        pausedTotalMs: s.pausedTotalMs + pausedNow,
      };
    }
  }
}

export interface MealSummary {
  biteCount: number;
  durationMs: number;
  pausedMs: number;
  earlyBites: number;
  meanRestMs: number | null;
  meanBiteMs: number | null;
  /**
   * Change in mean time-to-confirm from the first third of the meal to the
   * last third, as a ratio. Below 1 means you sped up as the meal went on,
   * which is the failure mode the app exists to surface. Null when there are
   * too few bites to split meaningfully.
   */
  paceDrift: number | null;
}

export function summarize(s: MealState, now: number): MealSummary {
  const bites = s.bites;
  const rests = bites.map((b) => b.restMs).filter((r): r is number => r !== null);
  const cued = bites.filter((b) => !b.early);

  const mean = (xs: number[]) =>
    xs.length ? xs.reduce((a, b) => a + b, 0) / xs.length : null;

  let paceDrift: number | null = null;
  // Needs at least two bites per third for the comparison to mean anything.
  if (cued.length >= 6) {
    const third = Math.floor(cued.length / 3);
    const first = mean(cued.slice(0, third).map((b) => b.biteMs));
    const last = mean(cued.slice(-third).map((b) => b.biteMs));
    if (first && last && first > 0) paceDrift = last / first;
  }

  return {
    biteCount: bites.length,
    durationMs: activeDurationMs(s, now),
    pausedMs: s.pausedTotalMs,
    earlyBites: bites.filter((b) => b.early).length,
    meanRestMs: mean(rests),
    meanBiteMs: mean(cued.map((b) => b.biteMs)),
    paceDrift,
  };
}
