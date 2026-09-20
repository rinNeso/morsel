import Foundation
import Testing
@testable import MorselCore
@testable import MorselData

/// 2026-09-17 12:00:00 UTC.
private let noonUTC: Millis = 1_789_646_400_000

@Suite("Meals logged without the timer")
struct ManualMeals {
    @Test("a manual meal is marked manual rather than looking like a timed meal with no bites")
    func markedExplicitly() async throws {
        let store = try MealStore(path: nil)
        try await store.recordManualMeal(startedAt: noonUTC, kcal: 640, notes: "Leftovers", fullness: 6)

        let meals = try await store.listMeals()
        #expect(meals.count == 1)
        #expect(meals[0].isManual, "the flag is stored, not inferred from a zero bite count")
        #expect(meals[0].biteCount == 0)
        #expect(meals[0].kcal == 640)
        #expect(meals[0].fullness == 6)
    }

    @Test("a timed meal is still not manual")
    func timedStaysTimed() async throws {
        let store = try MealStore(path: nil)
        let id = try await store.createMeal(startedAt: noonUTC, restMs: 30_000)
        try await store.endMeal(id: id, endedAt: noonUTC + 60_000, pausedMs: 0)

        let meals = try await store.listMeals()
        #expect(meals[0].isManual == false)
    }

    @Test("a manual meal counts toward the day's calories — a calorie is a calorie")
    func countsTowardIntake() async throws {
        let store = try MealStore(path: nil)
        let timed = try await store.createMeal(startedAt: noonUTC, restMs: 30_000)
        try await store.endMeal(id: timed, endedAt: noonUTC + 60_000, pausedMs: 0)
        try await store.setNutrition(kcal: 500, notes: nil, mealID: timed)
        try await store.recordManualMeal(startedAt: noonUTC + 3_600_000, kcal: 640, notes: nil, fullness: nil)

        let days = try await store.dailyIntake(timeZone: .gmt)
        #expect(days.count == 1)
        #expect(days[0].kcal == 1140, "both meals feed the daily total")
        #expect(days[0].meals == 2)
    }

    @Test("a manual meal has no duration, and none is invented for it")
    func noFabricatedDuration() async throws {
        let store = try MealStore(path: nil)
        try await store.recordManualMeal(startedAt: noonUTC, kcal: 300, notes: nil, fullness: nil)

        let meals = try await store.listMeals()
        #expect(meals[0].durationMs == nil, "nobody measured one")
        // But it is not an abandoned meal either — it is complete as recorded,
        // which is what stops it being offered for resumption.
        #expect(meals[0].isFinished, "complete despite having no duration")
    }

    @Test("manual survives a backup round trip")
    func survivesExport() async throws {
        let source = try MealStore(path: nil)
        try await source.recordManualMeal(startedAt: noonUTC, kcal: 640, notes: "Leftovers", fullness: 6)

        let destination = try MealStore(path: nil)
        _ = try await destination.importJSON(try await source.exportJSON())

        let restored = try await destination.listMeals()
        #expect(restored.count == 1)
        #expect(restored[0].isManual, "a manual meal that came back timed would corrupt the pace data")
        #expect(restored[0].kcal == 640)
    }

    @Test("an export written before manual meals existed restores as timed")
    func olderExportsDefaultToTimed() async throws {
        // Built by taking a real export and deleting the key, rather than by
        // hand-writing JSON that only resembles one — the point is that a file
        // from the previous format still restores.
        let source = try MealStore(path: nil)
        let id = try await source.createMeal(startedAt: noonUTC, restMs: 30_000)
        try await source.endMeal(id: id, endedAt: noonUTC + 1_200_000, pausedMs: 0)
        try await source.setNutrition(kcal: 500, notes: nil, mealID: id)

        var snapshot = try JSONSerialization.jsonObject(
            with: try await source.exportJSON()
        ) as! [String: Any]
        var meals = snapshot["meals"] as! [[String: Any]]
        #expect(meals[0]["source"] != nil, "the current format does carry it")
        meals[0].removeValue(forKey: "source")
        snapshot["meals"] = meals

        let destination = try MealStore(path: nil)
        _ = try await destination.importJSON(try JSONSerialization.data(withJSONObject: snapshot))

        let restored = try await destination.listMeals()
        #expect(restored.count == 1, "the older file still imports")
        #expect(restored[0].isManual == false, "absent source means timed")
        #expect(restored[0].kcal == 500)
    }
}
