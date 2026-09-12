import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { AppState } from "react-native";
import * as Haptics from "expo-haptics";
import { activateKeepAwakeAsync, deactivateKeepAwake } from "expo-keep-awake";

import {
  initialState, reduce, remainingRestMs, restProgress, activeDurationMs, summarize,
  DEFAULT_REST_MS,
} from "../lib/mealTimer.ts";
import type { Event, MealState, Phase } from "../lib/mealTimer.ts";

const KEEP_AWAKE_TAG = "morsel-meal";
/** UI refresh rate. Smooth enough for the ring; nowhere near the timing source. */
export const TICK_MS = 100;

function isActive(phase: Phase): boolean {
  return phase === "ready" || phase === "resting" || phase === "paused";
}

export function useMealTimer(restMs: number = DEFAULT_REST_MS) {
  const [state, rawDispatch] = useReducer(
    (s: MealState, e: Event) => reduce(s, e, Date.now()),
    restMs,
    initialState,
  );

  // Drives re-render only. All real timing comes from Date.now() inside the
  // reducer and selectors, so a dropped or delayed tick cannot corrupt a meal.
  const [, forceRender] = useState(0);
  const dispatch = useCallback((e: Event) => rawDispatch(e), []);

  useEffect(() => {
    if (!isActive(state.phase)) return;
    const id = setInterval(() => {
      rawDispatch({ type: "TICK" });
      forceRender((n) => n + 1);
    }, TICK_MS);
    return () => clearInterval(id);
  }, [state.phase]);

  // Returning from background may have skipped thousands of ticks. One TICK
  // recomputes everything from the wall clock.
  useEffect(() => {
    const sub = AppState.addEventListener("change", (next) => {
      if (next === "active") rawDispatch({ type: "TICK" });
    });
    return () => sub.remove();
  }, []);

  // Hold the screen on for the whole meal — the phone sits on the table, and a
  // timer that sleeps mid-meal is worse than no timer.
  useEffect(() => {
    if (isActive(state.phase)) {
      activateKeepAwakeAsync(KEEP_AWAKE_TAG).catch(() => {});
      return () => {
        deactivateKeepAwake(KEEP_AWAKE_TAG).catch(() => {});
      };
    }
  }, [state.phase]);

  // Fire the cue exactly once per resting -> ready transition.
  const prevPhase = useRef<Phase>(state.phase);
  useEffect(() => {
    if (prevPhase.current === "resting" && state.phase === "ready") {
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success).catch(() => {});
    }
    prevPhase.current = state.phase;
  }, [state.phase]);

  const now = Date.now();
  return {
    state,
    dispatch,
    phase: state.phase,
    remainingMs: remainingRestMs(state, now),
    progress: restProgress(state, now),
    elapsedMs: activeDurationMs(state, now),
    biteCount: state.bites.length,
    summary: summarize(state, now),
    confirmBite: useCallback(() => {
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium).catch(() => {});
      dispatch({ type: "CONFIRM_BITE" });
    }, [dispatch]),
  };
}
