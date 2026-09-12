import {
  initialState, reduce, remainingRestMs, restProgress,
  activeDurationMs, summarize, DEFAULT_REST_MS,
} from "./mealTimer.ts";
import type { MealState, Event } from "./mealTimer.ts";

let pass = 0, fail = 0;
function check(name: string, cond: boolean, detail = "") {
  if (cond) { pass++; console.log(`  PASS  ${name} ${detail}`); }
  else { fail++; console.log(`  FAIL  ${name} ${detail}`); }
}
const T0 = 1_800_000_000_000;
/** Drive the machine through [event, timeOffsetMs] pairs. */
function run(s: MealState, steps: [Event, number][]): MealState {
  return steps.reduce((acc, [e, t]) => reduce(acc, e, T0 + t), s);
}

console.log("\n1. Rest begins on confirmation, not on the cue");
{
  let s = run(initialState(30_000), [[{ type: "START" }, 0]]);
  check("starts READY — first bite needs no rest", s.phase === "ready");
  // Chew for 12s before putting the utensil down.
  s = run(s, [[{ type: "CONFIRM_BITE" }, 12_000]]);
  check("confirming moves to RESTING", s.phase === "resting");
  check("full rest remains at moment of confirm", remainingRestMs(s, T0 + 12_000) === 30_000);
  // The 12s chew must NOT have counted against the rest window.
  check("slow chew did not consume rest", remainingRestMs(s, T0 + 30_000) === 12_000,
    `(${remainingRestMs(s, T0 + 30_000)}ms left)`);
  check("time-to-confirm recorded", s.bites[0].biteMs === 12_000);
  s = run(s, [[{ type: "TICK" }, 41_999]]);
  check("still RESTING 1ms early", s.phase === "resting");
  s = run(s, [[{ type: "TICK" }, 42_000]]);
  check("READY exactly when rest elapses", s.phase === "ready");
}

console.log("\n2. Backgrounding: no ticks for 5 minutes");
{
  let s = run(initialState(30_000), [
    [{ type: "START" }, 0],
    [{ type: "CONFIRM_BITE" }, 1_000],
  ]);
  // Screen locks; JS timers stop. Next tick arrives 5 minutes later.
  s = run(s, [[{ type: "TICK" }, 301_000]]);
  check("recovers to READY from wall clock alone", s.phase === "ready");
  check("no time lost from the meal", activeDurationMs(s, T0 + 301_000) === 301_000);
}

console.log("\n3. Pause genuinely suspends the countdown");
{
  let s = run(initialState(30_000), [
    [{ type: "START" }, 0],
    [{ type: "CONFIRM_BITE" }, 0],
    [{ type: "PAUSE" }, 10_000],
  ]);
  check("20s left when paused", remainingRestMs(s, T0 + 10_000) === 20_000);
  check("paused countdown does not drain", remainingRestMs(s, T0 + 70_000) === 20_000,
    "(60s of conversation)");
  s = run(s, [[{ type: "RESUME" }, 70_000]]);
  check("resumes with 20s still owed", remainingRestMs(s, T0 + 70_000) === 20_000);
  s = run(s, [[{ type: "TICK" }, 89_999]]);
  check("not ready 1ms early post-pause", s.phase === "resting");
  s = run(s, [[{ type: "TICK" }, 90_000]]);
  check("ready after full rest served", s.phase === "ready");
  check("paused time tracked separately", s.pausedTotalMs === 60_000);
  check("paused time excluded from duration", activeDurationMs(s, T0 + 90_000) === 30_000);
}

console.log("\n4. Early bites are recorded, not silently dropped");
{
  let s = run(initialState(30_000), [
    [{ type: "START" }, 0],
    [{ type: "CONFIRM_BITE" }, 0],
    [{ type: "CONFIRM_BITE" }, 5_000],   // impatient: 5s into a 30s rest
  ]);
  check("early bite captured", s.bites.length === 2 && s.bites[1].early);
  check("actual rest served recorded", s.bites[1].restMs === 5_000);
  check("rest window restarts from the early bite", remainingRestMs(s, T0 + 5_000) === 30_000);
  check("first bite not flagged early", !s.bites[0].early);
}

console.log("\n5. Ring progress");
{
  let s = run(initialState(30_000), [[{ type: "START" }, 0], [{ type: "CONFIRM_BITE" }, 0]]);
  check("0% at start of rest", restProgress(s, T0) === 0);
  check("50% halfway", restProgress(s, T0 + 15_000) === 0.5);
  check("100% at completion", restProgress(s, T0 + 30_000) === 1);
  check("clamped past completion", restProgress(s, T0 + 99_000) === 1);
  const ready = run(s, [[{ type: "TICK" }, 30_000]]);
  check("full ring while READY", restProgress(ready, T0 + 30_000) === 1);
}

console.log("\n6. Pace drift detection (the failure mode we care about)");
{
  // Nine bites: chews slow at first (8s), collapsing to 2s by the end.
  const chews = [8000, 8000, 8000, 5000, 5000, 5000, 2000, 2000, 2000];
  let s = run(initialState(1_000), [[{ type: "START" }, 0]]);
  let t = 0;
  for (const chew of chews) {
    t += chew;
    s = reduce(s, { type: "CONFIRM_BITE" }, T0 + t);
    t += 1_000;
    s = reduce(s, { type: "TICK" }, T0 + t);
  }
  s = reduce(s, { type: "END" }, T0 + t);
  const sum = summarize(s, T0 + t);
  check("all bites counted", sum.biteCount === 9);
  check("no early bites", sum.earlyBites === 0);
  check("drift < 1 flags speeding up", sum.paceDrift !== null && sum.paceDrift < 1,
    `(drift=${sum.paceDrift?.toFixed(2)})`);
  check("drift is the 2s/8s ratio", Math.abs((sum.paceDrift ?? 0) - 0.25) < 1e-9);
}

console.log("\n7. Guards and degenerate transitions");
{
  const idle = initialState();
  check("default rest is 30s", idle.restMs === DEFAULT_REST_MS);
  check("CONFIRM before START ignored", reduce(idle, { type: "CONFIRM_BITE" }, T0).phase === "idle");
  check("RESUME while unpaused ignored", reduce(idle, { type: "RESUME" }, T0).phase === "idle");
  check("END while idle ignored", reduce(idle, { type: "END" }, T0).phase === "idle");
  const started = reduce(idle, { type: "START" }, T0);
  check("double START ignored", reduce(started, { type: "START" }, T0 + 5).startedAt === T0);
  check("SET_REST rejects zero", reduce(started, { type: "SET_REST", restMs: 0 }, T0).restMs === DEFAULT_REST_MS);
  check("SET_REST accepts positive", reduce(started, { type: "SET_REST", restMs: 45_000 }, T0).restMs === 45_000);
  const ended = reduce(started, { type: "END" }, T0 + 1000);
  check("ENDed meal is frozen", reduce(ended, { type: "CONFIRM_BITE" }, T0 + 2000).bites.length === 0);
  check("ended duration stops accruing", activeDurationMs(ended, T0 + 999_000) === 1000);
  check("empty meal summarises safely", summarize(ended, T0 + 1000).meanRestMs === null);
}

console.log(`\n=== ${pass} passed, ${fail} failed ===`);
process.exit(fail === 0 ? 0 : 1);
