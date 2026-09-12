# Morsel — mindful eating, nutrition, and weight trends

Working name; easy to change. Personal, single-user, local-first iOS app.

## Why this app exists

The premise is that eating fast defeats satiety signalling — fullness takes roughly
20 minutes to register, so a meal finished in 8 minutes is eaten blind. The timer is
the intervention. Everything else is instrumentation that tells you whether the
intervention is working.

That framing sets the priority order:

1. **Bite timer** — the actual behaviour change. Must be good, not just present.
2. **Fullness rating** — the feedback signal. One tap at end of meal.
3. **Weight trend** — the slow outcome measure. Happy Scale's job.
4. **Calorie/nutrition log** — the explanatory variable. Lowest priority, highest effort.

The interesting thing no existing app does: correlate **pace** against **fullness at a
given calorie load**. If a 700 kcal dinner eaten at 30s/bite lands at fullness 7, and the
same meal at 10s/bite lands at fullness 4, that is the whole thesis demonstrated on
personal data. Designing for that correlation from day one is why `fullness` and
`bite` timings are first-class columns rather than afterthoughts.

## Architecture

- **Expo (React Native) + TypeScript.** Dev loop runs entirely on Linux; the iPhone
  hot-reloads over WiFi. macOS only for signing.
- **Local-first SQLite** (`expo-sqlite`, Drizzle ORM for typed queries). No backend,
  no account, no network dependency for core function. Nutrition lookups are the only
  outbound calls, and they cache to the local `food` table.
- **No sync service.** Backup = export to JSON/CSV + optional HealthKit mirroring.

### Native modules required (these are what force a Mac rebuild)

| Module | Purpose | Needed for |
|---|---|---|
| `expo-haptics` | bite cue you can feel | v1 |
| `expo-notifications` | pre-scheduled chimes, survives backgrounding | v1 |
| `expo-keep-awake` | screen stays on during a meal | v1 |
| `expo-camera` | barcode scanning | v3 |
| `react-native-health` | HealthKit weight read/write | v2 |

Add all of them before cutting the first dev client, even if unused. Each one added
later costs a trip to the MacBook.

## The bite timer

Core loop: interval elapses -> haptic + optional chime -> countdown ring resets.

Design decisions worth stating:

- **Constant interval, not adaptive.** People naturally decelerate through a meal;
  the intervention is precisely to stop the fast opening. Research protocols use a
  fixed pace. Configurable, default 30s.
- **Two ways to set it.** Either a raw interval, or a target meal duration plus
  expected bite count, which derives the interval. The second frames it as
  "make this meal last 20 minutes," which is the actual goal.
- **Pause must be enormous.** Conversation, getting up, refilling a drink. A timer
  you can't pause instantly gets abandoned. Paused time is tracked separately so
  meal duration stats stay honest.
- **Passive by default.** It cues; it does not require you to confirm each bite.
  Tapping to confirm is optional and produces better `bite.taken_at` data, but
  demanding interaction 40 times per meal would make the app exhausting.
- **Backgrounding.** iOS will not run a JS timer reliably with the screen locked.
  Two-part answer: `expo-keep-awake` holds the screen on while a meal is active
  (phone sits on the table), and a batch of local notifications is pre-scheduled at
  the bite intervals as a fallback when the app does get backgrounded. iOS caps
  pending notifications at 64, so schedule a rolling window, not the whole meal.

### End of meal

Prompt for fullness 1-10. Optionally hunger 1-10 at the start. These two numbers are
the highest-value data in the app relative to the effort of collecting them.

## Weight trends (the Happy Scale part)

Happy Scale's value is that it hides daily noise, which is mostly water and gut
contents, and shows the underlying trend. The method is an exponentially weighted
moving average — the Hacker's Diet trend line.

```
trend_0 = weight_0
trend_i = trend_{i-1} + alpha_eff * (weight_i - trend_{i-1})
```

with `alpha = 0.1` (roughly a 10-day half-life), and gap correction so that a missed
week doesn't get treated as one day:

```
alpha_eff = 1 - (1 - alpha)^days_since_last
```

Derived from that:

- **Rate of change** — ordinary least squares on the trend series over a trailing
  window (14 / 30 / 90 day selector), reported as kg or lb per week.
- **Goal projection with a confidence cone.** Happy Scale gives a single date, which
  overstates precision. Use the residual spread of raw weights about the trend to get
  a standard error on the slope, and project a widening interval. An honest
  "somewhere between March 3 and April 18" beats a confident wrong date.
- **Plateau detection** — the slope's confidence interval straddling zero *is* the
  definition of a plateau. No heuristics needed.
- **Milestones** — lowest trend weight to date, total change since start, streaks.

Import path: Happy Scale exports CSV, and HealthKit holds the same data if a smart
scale writes to it. Support both; dedupe on date.

## Nutrition

Ranked by how much logging they actually save:

1. **Recents and favourites.** For one user, most logging is repeat foods. A good
   "you ate this 14 times" list beats any database.
2. **Saved meals.** Compose once, log as a unit.
3. **Barcode -> Open Food Facts.** Free, no API key, CC0 data, strong on packaged goods.
4. **Search -> USDA FoodData Central.** Free with a key, authoritative on whole foods.

Both APIs cache into the local `food` table on first use, so a food looked up once
works offline forever.

Deliberately excluded: MyFitnessPal-style social features, streak shaming, and any
"you have exceeded your goal" messaging. The app reports; it does not scold.

## Schema

See `docs/schema.sql`. Trend values are computed on read rather than stored — the
series is small enough that recomputation is free, and it avoids staleness bugs
when an old weight is edited or backfilled.

## Build workflow across two machines

- **Linux (daily):** edit code, `npx expo start`, iPhone hot-reloads over WiFi.
- **GitHub:** the sync point between machines.
- **MacBook (rare):** `npx expo prebuild && open ios/` -> Xcode -> sign and install.
  Only needed for the first dev client and whenever the native module list changes.

Free Apple ID signing gives 7-day certs. The $99/yr Developer Program gives TestFlight
and 90-day installs. Start free; upgrade if re-signing gets annoying.

## Roadmap

- **v1 — Timer.** Bite timer, meal records, fullness rating, meal history. Useful alone.
- **v2 — Weight.** Manual entry, EWMA trend chart, rate, projection, HealthKit, CSV import.
- **v3 — Nutrition.** Recents/favourites, saved meals, barcode scan, USDA search.
- **v4 — Correlation.** The pace-vs-fullness-vs-calories analysis the whole thing is for.

Each version stands on its own. v1 shipped and used beats v4 designed and unbuilt.
