# CLAUDE.md — Morsel

Context carried between two machines. Read this before changing anything.

## What this is

A personal, single-user iOS app for mindful eating. The bite timer is the product;
the meal journal, calorie log, and weight trends are instrumentation that tell the
owner whether the timer is working. Local-first, no backend, no account.

Native SwiftUI, iOS 26+. It was React Native / Expo until 2026-09-12; see
"Why Swift" below before proposing a way back.

Design rationale lives in `docs/SPEC.md`, the data model in `docs/schema.sql`.
Read the spec before proposing product changes — most obvious ideas were already
considered and rejected there for stated reasons. `docs/SPEC.md` opens with the
design north star, which is the tiebreaker for anything visual.

## Layout

```
MorselCore/            SwiftPM package — the logic, testable anywhere
  Sources/MorselCore/  pure: reducer, trend math. NO dependencies, keep it that way
  Sources/MorselData/  GRDB store, schema, timestamps
App/                   SwiftUI app target
project.yml            XcodeGen spec; Morsel.xcodeproj is generated and gitignored
```

## Two machines — work out which one you are on first

| | Linux desktop (`/home/nate/Projects/morsel`) | MacBook Pro |
|---|---|---|
| Role | logic, tests, review | everything |
| Can do | `swift test` over `MorselCore/` | build, sign, install, run on device |
| Cannot do | build or run the app at all — Xcode is macOS-only | — |

This is the real cost of going native, and it was accepted deliberately. It is
softened by `MorselCore` being a plain SwiftPM package with no Apple-platform
dependencies: the reducer and the trend math run under `swift test` on Linux with
no Xcode, so the logic stays reviewable and testable from the desktop. Only the UI
layer is Mac-bound.

The owner also drives the Mac from Linux via Claude Code's Remote Control
(`/remote-control` on the Mac, open the URL on Linux). Commands still execute on
the Mac; it is remote hands, not a second working copy.

GitHub (`rinNeso/morsel`, private) is the only sync path. **Always commit and push
before the session ends.** Equally, `git pull` before starting.

## Commands

```sh
cd MorselCore && swift test                 # 26 assertions; works on Linux
xcodegen generate                           # regenerate Morsel.xcodeproj from project.yml
xcodebuild -project Morsel.xcodeproj -scheme Morsel -configuration Debug \
  -destination "id=<device-udid>" -allowProvisioningUpdates build
xcrun devicectl list devices                # find the phone, check it is reachable
xcrun devicectl device install app --device <udid> <path-to>/Morsel.app
xcrun devicectl device process launch --device <udid> com.rinneso.morsel
./Scripts/release.sh                        # archive, verify signing, upload to TestFlight
```

`Scripts/release.sh` is the only way a build should reach TestFlight. The build
number is `git rev-list --count HEAD` rather than a value in `project.yml`:
App Store Connect burns a version/build pair permanently on first upload, so a
hand-bumped number is the step that gets forgotten until the upload fails at the
very end. It refuses to run on a dirty tree, because a build number derived from
history cannot identify a build containing changes that are not in that history.
It also checks the export is distribution-signed *before* uploading — the first
manual attempt produced a development-signed archive that looked fine locally and
was only rejected once it reached Apple.

`Morsel.xcodeproj` is gitignored on purpose — it is generated. Never commit or
hand-edit it; change `project.yml` and regenerate.

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
and flagged `early`. Impatience is data, not an error state. It is a real column in
`bite`, not inferred from `cued_at == taken_at` — that inference happens to hold, but
only as a coincidence of how the reducer builds an uncued bite.

**All timing derives from wall-clock timestamps; nothing accumulates ticks.** iOS
suspends timers on background and lock, so a tick counter silently loses time and
makes meal records fiction. If you find yourself adding `elapsed += delta`, stop.
`MealTimerModel` schedules exactly one wake-up for the instant rest completes and
re-derives from the clock on foreground; it does not poll.

**The reducer in `MorselCore/Sources/MorselCore/MealTimer.swift` is pure and takes
`now` as a parameter.** No `Date()` inside. That is what keeps it testable with no
device and no fake clock, and what lets it run on Linux. Keep new logic in that
shape: pure code in `MorselCore`, side effects in `App/`.

**`MorselCore` has no dependencies and must keep none.** GRDB and anything else
belongs in `MorselData` or the app. The moment `MorselCore` gains a dependency, the
Linux testing story dies.

**Weight trend and weight rate use deliberately different methods.** The display
line is an EWMA (`ewmaTrend`); the rate of change is OLS on *raw* weights
(`rateOfChange`). Regressing the smoothed series looks cleaner and is wrong — EWMA
output is autocorrelated by construction, which collapses apparent residuals and
manufactures a standard error the data has not earned. There is a comment saying
this at the top of `Trend.swift`.

**Goal projection returns a cone, not a date.** A 14-day window on real bathroom-scale
noise reads roughly three times the true rate. Plateau detection falls out of the same
confidence interval straddling zero. Do not "simplify" this to a single date.

**No scolding copy, and the app never chooses red on its own.** Colour carries state:
the accent means permission to eat, the resting colour means waiting, grey means
paused. The app reports; it does not judge. The same rule governs any nutrition
feature: no streak shaming, no "you exceeded your goal".

The colour half of this is now the owner's to set, by their explicit decision. The
accent is user-chosen and red is allowed — picking it is *their* call, not the app
defaulting to it or an assistant quietly restoring it. The resting colour is also
user-chosen and follows the accent unless set separately, so amber is a starting
point rather than a rule. Paused stays fixed grey: "nothing is happening" is not a
matter of taste.

**Weight figures may use red for a gain.** A second explicit owner override
(2026-09-13), extending the first: the weight trend tiles colour losses green and
gains red, as Happy Scale does. The argument that carried it is that a
*trend-derived* gain is a real signal rather than scale noise, so the colour is
reporting something true. Do not strip this out on the strength of the rule above.

**A calorie day may use red for going over goal.** A third explicit owner override
(2026-09-19), extending the second to the intake screen: days at or under the daily
goal read green, days over read red, on the same argument. It is narrower than it
looks — the colour only appears once the owner has set a goal, and there is no
default goal, so the app never invents a target and then colours you against it.

The copy stays factual either way: "58 over goal" states the gap and stops. No
"over budget", no streaks, no praise for a green day.

What must not be quietly reversed is the *reporting, not judging* posture, and the
fact that these are settings rather than hardcoded opinions. No streak shaming, no
"you exceeded your goal", nothing that editorialises beyond stating the number.

**Apple's Human Interface Guidelines are the default authority for anything visual.**
If a request contradicts current HIG, say so and link the specific guidance so the
owner can decide, rather than silently following either one. Check the live HIG
rather than trusting recall — it moves (iOS 26's Liquid Glass materially changed
tab bar guidance).

## Why Swift

The RN build reimplemented Apple's interactions by hand and always approximately:
~80 lines of SVG wedges for a colour wheel because react-native-svg has no conic
gradient, ~150 lines of Animated plumbing for minimize-on-scroll, BlurView faking
`.glassEffect()`. Natively those are `ColorPicker`, `.tabBarMinimizeBehavior()`, and
the system tab bar. The owner's verdict on the RN tab bar was "we have apple tab bar
at home", and the design north star is to be indistinguishable from Apple's own work.

The forcing function was iPhone Duo (#15): its adaptive-layout APIs ship as
SwiftUI/UIKit in Xcode 27.1, day one, with no third-party wrapper to wait for.

## Environment traps already hit

- **Pin `DEVELOPMENT_TEAM` in `project.yml`.** It is committed deliberately. The RN
  build lost an hour to `expo prebuild --clean` silently wiping the signing team out
  of the generated project, producing "Signing for Morsel requires a development
  team" with no hint why. Recovering it meant digging the team ID out of a cached
  `.mobileprovision`.
- **A free Apple ID cannot sign an app requesting the push entitlement.** Personal
  teams reject `aps-environment` outright. Local notifications never needed it.
- **A locked phone refuses `devicectl ... process launch`** with
  `BSErrorCodeDescription = Locked`; install works fine, launch does not. Over WiFi
  the debug tunnel also drops when the phone sleeps, surfacing as "device
  disconnected immediately after connecting". Auto-Lock → Never while developing.
- **Swift 6 strict concurrency is load-bearing here, not ceremony.** It rejected a
  global `ISO8601DateFormatter` as non-Sendable; replacing it surfaced a real bug
  underneath — formatting through `Date(timeIntervalSince1970: ms / 1000)` silently
  shaved a millisecond off some timestamps, because the sub-second part is not
  exactly representable in binary and the style truncates rather than rounds.
  Milliseconds are split off with integer arithmetic now. Do not "simplify" that back.
- **XcodeGen needs each SwiftPM product named explicitly.** A bare `package:` entry
  links only the product sharing the package's name, so `MorselData` went missing
  until it was listed on its own.
- **Run `xcodegen generate` after adding a source file.** XcodeGen enumerates `App/`
  when it generates, so a new file is simply not in the target until it is rerun. The
  failure looks like a type having "no member" somewhere else entirely, with no error
  in the new file at all, because that file is not being compiled.
- Watch out for `grep`'s exit code masking a command's own when verifying tool output.

## State

Working on device: the timer end to end, SQLite persistence, meal history, accent
colour and Light/Dark/System. That is parity with what React Native ever shipped.

Never verified: whether the 30s default feels right across real meals. Only the
owner eating can settle that.

Roadmap and open work are tracked as GitHub Issues on the "Morsel Roadmap" project
board (labels `v1-timer` through `v5-watch`), not here — check the tracker rather
than this file for what is next. Anything the owner suggests that gets built should
get a ticket, even small polish. This section is for state that is not a discrete
ticket.

## Conventions

- Pure logic in `MorselCore` with tests beside it; side effects in `App/`.
- Tests are swift-testing (`@Test`, `#expect`). `MorselCore` tests must keep running
  on Linux — no XCTest, no UIKit, no simulator dependency.
- Store weight in kg and durations in milliseconds internally; convert only for
  display or persistence.
- Timestamps are ISO8601 UTC. Weigh-in dates are local `YYYY-MM-DD`, because "which
  day did I weigh in" is a calendar question, not an instant.
- Commit messages explain *why*, especially when the choice looks odd.
