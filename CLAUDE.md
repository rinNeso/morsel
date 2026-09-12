# CLAUDE.md — Morsel

Context carried between two machines. Read this before changing anything.

## What this is

A personal, single-user iOS app for mindful eating. The bite timer is the product;
the meal journal, calorie log, and weight trends are instrumentation that tell the
owner whether the timer is working. Local-first, no backend, no account.

Design rationale lives in `docs/SPEC.md`, the data model in `docs/schema.sql`.
Read the spec before proposing product changes — most obvious ideas were already
considered and rejected there for stated reasons.

## Two machines — work out which one you are on first

Both machines now do day-to-day development. The MacBook Pro is additionally the
only one that can sign and install to the phone.

| | Linux desktop (`/home/nate/Projects/morsel`) | MacBook Pro |
|---|---|---|
| Role | day-to-day development | day-to-day development, plus signing and device installs |
| Can do | edit, typecheck, run tests, `expo export`, `expo start` | everything, plus Xcode |
| Cannot do | compile iOS, run a simulator, verify haptics | — |

GitHub (`rinNeso/morsel`, private) is the only sync path. **Always commit and push
before the session ends** — the other machine has no other way to see the work.
Equally, `git pull` before starting.

Xcode is only needed for the first dev client and whenever the **native module list
changes**. Pure TS/JS changes hot-reload onto the device from Linux over WiFi, so
do not send the owner to the Mac for something that does not need it.

All native modules the roadmap calls for are already installed and their config
plugins verified against the generated `Info.plist` — camera, SQLite, notifications,
haptics, keep-awake, HealthKit. This was deliberate: adding one later costs a trip
to the Mac. Think hard before adding another, and batch them if you must.

## Commands

```sh
npm run typecheck                                    # tsc --noEmit
node --experimental-strip-types src/lib/<x>.test.ts  # run a test suite
npx expo export --platform ios                       # full bundle check, works on Linux
npx expo start                                       # dev server; device connects over WiFi
npx expo prebuild --platform ios --clean             # regenerate ios/, also works on Linux
```

`ios/` and `android/` are gitignored on purpose — they are generated. Never commit
them; regenerate with `prebuild` instead.

## Decisions that must not be quietly reversed

Each of these looks wrong at a glance and is not. If you think one should change,
raise it rather than "fixing" it.

**Rest starts on bite confirmation, not on the cue.** The app is not a metronome.
A fixed cadence keeps cueing while the user is still chewing, so a slow chew eats
its own rest window — penalising the exact behaviour being trained. The configured
interval is a *minimum rest between bites*. Meal duration is an outcome, not an input.

**Confirming each bite is required, and the friction is intentional.** The tap marks
that the food went back down — utensil, sandwich, whatever it is — it is the
intervention, not data entry. Do not "improve" this by making it passive or
automatic.

**Early bites are recorded, not blocked.** Confirming during a rest window is allowed
and flagged `early`. Impatience is data, not an error state.

**All timing derives from wall-clock timestamps; nothing accumulates ticks.** iOS
suspends JS timers on background and lock, so a tick counter silently loses time and
makes meal records fiction. `setInterval` exists only to trigger re-renders. If you
find yourself adding `elapsed += delta`, stop.

**The reducer in `src/lib/mealTimer.ts` is pure and takes `now` as a parameter.**
No `Date.now()` inside. This is what makes it testable on Linux with no device and
no fake timers. Keep new logic in that shape: pure module in `src/lib/`, React
bindings in `src/hooks/`.

**Weight trend and weight rate use deliberately different methods.** The display
line is an EWMA (`ewmaTrend`); the rate of change is OLS on *raw* weights
(`rateOfChange`). Regressing the smoothed series looks cleaner and is wrong — EWMA
output is autocorrelated by construction, which collapses apparent residuals and
manufactures a standard error the data has not earned. There is a comment saying
this at the top of `src/lib/trend.ts`.

**Goal projection returns a cone, not a date.** A 14-day window on real bathroom-scale
noise reads roughly three times the true rate. Plateau detection falls out of the same
confidence interval straddling zero. Do not "simplify" this to a single date.

**No red in the UI, and no scolding copy.** Green means permission to eat, amber means
resting, grey means paused. The app reports; it does not judge. Same rule applies to
any nutrition features: no streak shaming, no "you exceeded your goal".

## Environment traps already hit

- **`create-expo-app` does not work here.** Arch ships npm 12, which changed the
  `npm pack --dry-run` JSON shape that create-expo-app parses. It fails with
  "Could not parse JSON" *and still exits 0*. The template was extracted manually
  from the tarball. Do not try to re-scaffold with it.
- **`allowImportingTsExtensions` is required** in `tsconfig.json`, and relative
  imports carry explicit `.ts`/`.tsx` extensions. This is what lets Node's
  `--experimental-strip-types` run the pure modules as tests with no build step.
  Do not strip the extensions.
- **HealthKit is `@kingstinct/react-native-healthkit`**, not `react-native-health` —
  the latter has been unmaintained since Oct 2024 and predates React 19. The plugin
  takes **raw `Info.plist` key names** as props (`NSHealthShareUsageDescription`),
  not Expo's usual `*Permission` convention. Getting this wrong fails silently: the
  build succeeds and the usage strings fall back to the plugin's generic defaults.
  After changing any plugin config, run `prebuild` and grep the generated
  `ios/Morsel/Info.plist` to confirm it actually applied.
- **`UIBackgroundModes: ["audio"]`** is declared in `app.json` but nothing plays audio
  yet. It is there to keep the timer alive with the screen locked. Harmless for
  sideloading; an App Store rejection risk if this is ever published. Flagged to the
  owner, undecided.
- Watch out for `grep`'s exit code masking a command's own when verifying tool output.

## State

Done: spec, schema, EWMA/OLS weight math (17 assertions), meal timer state machine
(43 assertions), timer UI, Expo SDK 57 scaffold. Everything typechecks and bundles.
First dev client built and installed on device from the MacBook — signing works
end to end, timer UI confirmed running on a real phone.

Never verified: haptics, keep-awake, and whether the 30s default feels right in a
real meal. Only the owner eating a meal can settle that.

Roadmap and open work are tracked as GitHub Issues (labels `v1-timer` through
`v4-correlation`), not here — check the issue tracker rather than this file for
what's next. This section stays for state that isn't a discrete ticket.

## Conventions

- TypeScript strict. Pure logic in `src/lib/` with a colocated `*.test.ts`; React in
  `src/hooks/` and `src/screens/`.
- Tests are plain assertions run by Node's type stripping — no Jest, no test runner
  to install. Keep it that way unless there is a real reason not to.
- Store weight in kg and durations in ms internally; convert only for display.
- Timestamps are ISO8601 UTC. Weigh-in dates are local `YYYY-MM-DD`, because "which
  day did I weigh in" is a calendar question, not an instant.
- Commit messages explain *why*, especially when the choice looks odd.
