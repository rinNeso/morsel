import Foundation
import Testing
@testable import MorselCore
@testable import MorselData

private let t0: Millis = 1_800_000_000_000

/// A store holding one finished meal with three bites, the middle one early.
private func populatedStore() async throws -> MealStore {
    let store = try MealStore(path: nil)
    let mealID = try await store.createMeal(startedAt: t0, restMs: 30_000)

    var state = MealState(restMs: 30_000).reduced(by: .start(), now: t0)
    state = state.reduced(by: .confirmBite, now: t0 + 5_000)
    try await store.insert(bite: state.bites[0], mealID: mealID)
    state = state.reduced(by: .confirmBite, now: t0 + 10_000) // early
    try await store.insert(bite: state.bites[1], mealID: mealID)
    state = state.reduced(by: .tick, now: t0 + 41_000)
    state = state.reduced(by: .confirmBite, now: t0 + 45_000)
    try await store.insert(bite: state.bites[2], mealID: mealID)

    try await store.endMeal(id: mealID, endedAt: t0 + 60_000, pausedMs: 3_000)
    try await store.setFullness(7, mealID: mealID)
    try await store.setSetting("accent_color", to: "#7C5CBF")
    return store
}

@Suite("Restoring an export")
struct Restoring {
    @Test("an export lands in an empty store intact")
    func restoreIntoEmpty() async throws {
        let source = try await populatedStore()
        let snapshot = try await source.exportSnapshot()

        let destination = try MealStore(path: nil)
        let result = try await destination.importSnapshot(snapshot)

        #expect(result.imported == 1)
        #expect(result.skipped == 0)
        #expect(result.settingsApplied == 1, "a fresh install gets its appearance back")

        let restored = try await destination.exportSnapshot()
        #expect(restored.meals == snapshot.meals, "every field and bite survives the round trip")
        #expect(try await destination.setting("accent_color") == "#7C5CBF")
    }

    @Test("history reads the restored meal the same way")
    func restoredMealReadsBack() async throws {
        let snapshot = try await populatedStore().exportSnapshot()
        let destination = try MealStore(path: nil)
        _ = try await destination.importSnapshot(snapshot)

        let meal = try #require(try await destination.listMeals().first)
        #expect(meal.biteCount == 3, "bite_count is derived from the bites actually imported")
        #expect(meal.earlyBites == 1)
        #expect(meal.fullness == 7)
        #expect(meal.durationMs == 60_000 - 3_000, "paused time still comes out of the duration")
    }

    @Test("importing the same file twice changes nothing the second time")
    func importIsIdempotent() async throws {
        let snapshot = try await populatedStore().exportSnapshot()
        let destination = try MealStore(path: nil)

        let first = try await destination.importSnapshot(snapshot)
        let second = try await destination.importSnapshot(snapshot)

        #expect(first.imported == 1 && first.skipped == 0)
        #expect(second.imported == 0 && second.skipped == 1, "matched on started_at, not re-added")
        #expect(try await destination.listMeals().count == 1, "history is not doubled")
    }

    @Test("merging leaves meals already on the device alone")
    func mergeKeepsLocalMeals() async throws {
        let snapshot = try await populatedStore().exportSnapshot()

        // A different meal, logged locally since the backup was taken.
        let destination = try MealStore(path: nil)
        let localID = try await destination.createMeal(startedAt: t0 + 900_000, restMs: 20_000)
        try await destination.endMeal(id: localID, endedAt: t0 + 960_000, pausedMs: 0)

        let result = try await destination.importSnapshot(snapshot)
        #expect(result.imported == 1)
        #expect(try await destination.listMeals().count == 2, "restoring is a merge, not a replace")
    }

    @Test("settings already set locally are not overwritten by an old backup")
    func localSettingsWin() async throws {
        let snapshot = try await populatedStore().exportSnapshot()
        let destination = try MealStore(path: nil)
        try await destination.setSetting("accent_color", to: "#2E9E96")

        let result = try await destination.importSnapshot(snapshot)
        #expect(result.settingsApplied == 0)
        #expect(try await destination.setting("accent_color") == "#2E9E96", "the live choice stands")
    }

    @Test("an in-progress meal restores as in-progress")
    func unfinishedMealSurvives() async throws {
        let source = try MealStore(path: nil)
        _ = try await source.createMeal(startedAt: t0, restMs: 30_000)

        let destination = try MealStore(path: nil)
        _ = try await destination.importSnapshot(try await source.exportSnapshot())

        let restored = try await destination.exportSnapshot()
        #expect(restored.meals.count == 1)
        #expect(restored.meals[0].endedAt == nil)
        #expect(try await destination.listMeals().isEmpty, "still hidden from history, as it should be")
    }
}

@Suite("Refusing bad input")
struct RefusingBadInput {
    @Test("a newer format version is refused rather than guessed at")
    func refusesNewerFormat() async throws {
        let future = MorselExport(
            formatVersion: MorselExport.currentFormatVersion + 1,
            exportedAt: iso(from: t0),
            meals: [],
            settings: [:]
        )
        let store = try MealStore(path: nil)
        await #expect(throws: ImportError.unsupportedFormat(
            found: MorselExport.currentFormatVersion + 1,
            supported: MorselExport.currentFormatVersion
        )) {
            try await store.importSnapshot(future)
        }
    }

    @Test("arbitrary JSON is rejected")
    func rejectsJunk() async throws {
        let store = try MealStore(path: nil)
        await #expect(throws: ImportError.malformed) {
            try await store.importJSON(Data(#"{"hello":"world"}"#.utf8))
        }
    }

    @Test("a refused import leaves the store untouched")
    func refusalIsAtomic() async throws {
        let store = try await populatedStore()
        _ = try? await store.importJSON(Data("not json at all".utf8))
        #expect(try await store.listMeals().count == 1, "nothing added, nothing lost")
    }
}
