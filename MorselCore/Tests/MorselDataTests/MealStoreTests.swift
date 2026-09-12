import Foundation
import Testing
@testable import MorselCore
@testable import MorselData

private let t0: Millis = 1_800_000_000_000

private func makeStore() throws -> MealStore {
    try MealStore(path: nil) // in-memory
}

@Suite("Timestamps")
struct Timestamps {
    @Test("ISO round-trips at millisecond precision")
    func isoRoundTrip() throws {
        let s = iso(from: t0 + 862)
        #expect(s.hasSuffix("Z"), "stored as UTC")
        #expect(s.contains("."), "keeps fractional seconds")
        #expect(millis(fromISO: s) == t0 + 862, "round-trips without losing the milliseconds")
    }

    @Test("garbage parses to nil rather than a wrong date")
    func garbageIsNil() {
        #expect(millis(fromISO: "not a timestamp") == nil)
    }

    /// Regression guard. Formatting via `Date(timeIntervalSince1970:)` used to
    /// shave a millisecond off some values — …862 came back as …861 — because
    /// the sub-second part isn't exactly representable as a binary double and
    /// the format style truncates. One example value wouldn't have caught it;
    /// every possible sub-second offset does.
    @Test("every millisecond offset in a second round-trips exactly")
    func allSubSecondOffsetsRoundTrip() {
        for offset in 0..<1000 {
            let value = t0 + offset
            #expect(millis(fromISO: iso(from: value)) == value, "offset \(offset) drifted")
        }
    }

    @Test("timestamps before the epoch round-trip too")
    func negativeTimestamps() {
        for value in [Millis(-1), -999, -1_000, -1_500, -86_400_000] {
            #expect(millis(fromISO: iso(from: value)) == value, "\(value) drifted")
        }
    }
}

@Suite("Writing a meal as it happens")
struct WritingMeals {
    @Test("a meal and its bites survive being written incrementally")
    func incrementalWrites() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

        // Drive a real meal through the reducer and persist each bite as it lands.
        var state = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        for i in 1...3 {
            let at = t0 + i * 31_000
            state = state.reduced(by: .confirmBite, now: at)
            try await store.insert(bite: state.bites[i - 1], mealID: mealID)
            state = state.reduced(by: .tick, now: at + 30_000)
        }
        let endedAt = t0 + 4 * 31_000
        state = state.reduced(by: .end, now: endedAt)
        try await store.endMeal(id: mealID, endedAt: endedAt, pausedMs: state.pausedTotalMs)

        let meals = try await store.listMeals()
        #expect(meals.count == 1, "one completed meal")

        let meal = try #require(meals.first)
        #expect(meal.biteCount == 3, "bite_count kept in step as bites landed")
        #expect(meal.startedAt == t0, "start time round-trips")
        #expect(meal.durationMs == endedAt - t0, "duration spans the whole meal")
        #expect(meal.earlyBites == 0, "none of these were early")
        #expect(meal.fullness == nil, "no rating given yet")

        let mean = try #require(meal.meanRestMs)
        // Bites 2 and 3 each served ~31s of rest; bite 1 had none to measure.
        #expect(abs(mean - 31_000) < 1, "mean rest reflects the intervals actually served")
    }

    @Test("an unfinished meal is listed, without a duration")
    func unfinishedMealListed() async throws {
        let store = try makeStore()
        _ = try await store.createMeal(startedAt: t0, restMs: 30_000)

        // Listed rather than hidden: an invisible row cannot be deleted, and it
        // still turns up in exports, so an import reports meals "already here"
        // that the owner has no way to see.
        let meal = try #require(try await store.listMeals().first)
        #expect(meal.durationMs == nil)
        #expect(!meal.isFinished)
    }

    @Test("early bites are stored explicitly, not inferred from timestamps")
    func earlyBitesStored() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

        var state = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        state = state.reduced(by: .confirmBite, now: t0)
        try await store.insert(bite: state.bites[0], mealID: mealID)
        // Impatient: 5s into a 30s rest.
        state = state.reduced(by: .confirmBite, now: t0 + 5_000)
        try await store.insert(bite: state.bites[1], mealID: mealID)
        try await store.endMeal(id: mealID, endedAt: t0 + 10_000, pausedMs: 0)

        let meal = try #require(try await store.listMeals().first)
        #expect(meal.earlyBites == 1, "the impatient bite is flagged")
    }

    @Test("fullness can be attached after the meal ends")
    func fullnessAttaches() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)
        try await store.endMeal(id: mealID, endedAt: t0 + 60_000, pausedMs: 0)
        try await store.setFullness(7, mealID: mealID)

        let meal = try #require(try await store.listMeals().first)
        #expect(meal.fullness == 7)
    }

    @Test("deleting a meal takes its bites with it")
    func cascadeDelete() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)
        var state = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        state = state.reduced(by: .confirmBite, now: t0)
        try await store.insert(bite: state.bites[0], mealID: mealID)

        // Foreign keys with ON DELETE CASCADE are only enforced when the
        // pragma is on, which is easy to lose silently — so assert it.
        #expect(try await store.biteCount(forMeal: mealID) == 1)
        try await store.deleteMeal(id: mealID)
        #expect(try await store.biteCount(forMeal: mealID) == 0, "orphaned bites are cleaned up")
    }
}

@Suite("Export")
struct Export {
    @Test("a snapshot carries every meal, its bites, and the settings")
    func snapshotIsComplete() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

        var state = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        state = state.reduced(by: .confirmBite, now: t0)
        try await store.insert(bite: state.bites[0], mealID: mealID)
        state = state.reduced(by: .confirmBite, now: t0 + 5_000) // early
        try await store.insert(bite: state.bites[1], mealID: mealID)
        try await store.endMeal(id: mealID, endedAt: t0 + 60_000, pausedMs: 0)
        try await store.setFullness(6, mealID: mealID)
        try await store.setSetting("accent_color", to: "#3B82C4")

        let snapshot = try await store.exportSnapshot()
        #expect(snapshot.formatVersion == MorselExport.currentFormatVersion)
        #expect(snapshot.settings["accent_color"] == "#3B82C4", "settings travel with the data")

        let meal = try #require(snapshot.meals.first)
        #expect(snapshot.meals.count == 1)
        #expect(meal.fullnessAfter == 6)
        #expect(meal.targetIntervalS == 30)
        #expect(meal.bites.count == 2, "bites are nested under their meal, not dropped")
        #expect(meal.bites[0].early == false)
        #expect(meal.bites[1].early == true, "the early flag survives the round trip")
        #expect(meal.bites.map(\.seq) == [1, 2], "bite order is preserved")
    }

    @Test("an in-progress meal is exported too — a backup that skips it loses it")
    func exportsUnfinishedMeals() async throws {
        let store = try makeStore()
        _ = try await store.createMeal(startedAt: t0, restMs: 30_000)

        let snapshot = try await store.exportSnapshot()
        #expect(snapshot.meals.count == 1, "history hides unfinished meals; the backup must not")
        #expect(snapshot.meals[0].endedAt == nil)
    }

    @Test("the JSON decodes back to an identical snapshot")
    func jsonRoundTrips() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 45_000)
        try await store.endMeal(id: mealID, endedAt: t0 + 60_000, pausedMs: 12_000)

        let original = try await store.exportSnapshot()
        let decoded = try JSONDecoder().decode(MorselExport.self, from: try await store.exportJSON())

        // Everything but `exportedAt`, which is stamped per export and so is
        // expected to differ between two separate calls.
        #expect(decoded.meals == original.meals, "what is written is what can be read back")
        #expect(decoded.settings == original.settings)
        #expect(decoded.formatVersion == original.formatVersion)
        #expect(millis(fromISO: decoded.exportedAt) != nil, "the stamp is a parseable timestamp")
    }

    @Test("an empty store still produces a valid snapshot")
    func emptyExport() async throws {
        let snapshot = try await makeStore().exportSnapshot()
        #expect(snapshot.meals.isEmpty)
        #expect(snapshot.settings.isEmpty)
        #expect(snapshot.formatVersion == MorselExport.currentFormatVersion)
    }
}

@Suite("Settings")
struct Settings {
    @Test("settings round-trip and overwrite in place")
    func settingsRoundTrip() async throws {
        let store = try makeStore()
        #expect(try await store.setting("accent_color") == nil, "absent key reads as nil")

        try await store.setSetting("accent_color", to: "#4C9A5E")
        #expect(try await store.setting("accent_color") == "#4C9A5E")

        try await store.setSetting("accent_color", to: "#3B82C4")
        #expect(try await store.setting("accent_color") == "#3B82C4", "upsert replaces rather than duplicating")
    }
}

@Suite("Resuming an interrupted meal")
struct Resuming {
    @Test("a meal with bites comes back mid-rest, timed from the last bite")
    func resumesMidRest() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

        var live = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        live = live.reduced(by: .confirmBite, now: t0 + 5_000)
        try await store.insert(bite: live.bites[0], mealID: mealID)
        live = live.reduced(by: .tick, now: t0 + 36_000)
        live = live.reduced(by: .confirmBite, now: t0 + 40_000)
        try await store.insert(bite: live.bites[1], mealID: mealID)

        // The app dies here.
        let resumed = try #require(try await store.resumableMeal())
        #expect(resumed.id == mealID)
        #expect(resumed.state.bites.count == 2, "both bites come back")
        #expect(resumed.state.phase == .resting)
        #expect(resumed.state.startedAt == t0)

        // Rest runs from the last confirmation, not from when the app restarted.
        #expect(resumed.state.remainingRest(now: t0 + 50_000) == 20_000)

        // And a tick after the window has passed promotes it, from the clock alone.
        let ready = resumed.state.reduced(by: .tick, now: t0 + 90_000)
        #expect(ready.phase == .ready, "an hour later it is your turn, not still resting")
    }

    @Test("bite details survive the rebuild")
    func biteDetailsSurvive() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

        var live = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
        live = live.reduced(by: .confirmBite, now: t0 + 8_000)
        try await store.insert(bite: live.bites[0], mealID: mealID)
        live = live.reduced(by: .confirmBite, now: t0 + 12_000) // early
        try await store.insert(bite: live.bites[1], mealID: mealID)

        let resumed = try #require(try await store.resumableMeal())
        #expect(resumed.state.bites[0].biteMs == 8_000, "time-to-confirm is recovered from the timestamps")
        #expect(resumed.state.bites[0].early == false)
        #expect(resumed.state.bites[1].early == true, "impatience is not lost to a restart")
        #expect(resumed.state.bites[1].restMs == 4_000, "rest actually served is recovered")
    }

    @Test("a meal started but never confirmed comes back ready")
    func resumesBeforeFirstBite() async throws {
        let store = try makeStore()
        _ = try await store.createMeal(startedAt: t0, restMs: 45_000)

        let resumed = try #require(try await store.resumableMeal())
        #expect(resumed.state.phase == .ready, "nothing to rest from yet")
        #expect(resumed.state.restMs == 45_000, "the configured interval is recovered")
        #expect(resumed.state.bites.isEmpty)
    }

    @Test("nothing to resume once the meal is ended")
    func finishedMealsAreNotResumed() async throws {
        let store = try makeStore()
        let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)
        try await store.endMeal(id: mealID, endedAt: t0 + 60_000, pausedMs: 0)

        #expect(try await store.resumableMeal() == nil)
    }

    @Test("an empty store has nothing to resume")
    func emptyStoreResumesNothing() async throws {
        #expect(try await makeStore().resumableMeal() == nil)
    }
}
