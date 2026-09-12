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

    @Test("an unfinished meal is not listed as history")
    func unfinishedMealHidden() async throws {
        let store = try makeStore()
        _ = try await store.createMeal(startedAt: t0, restMs: 30_000)
        #expect(try await store.listMeals().isEmpty, "a meal with no ended_at is still in progress")
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
