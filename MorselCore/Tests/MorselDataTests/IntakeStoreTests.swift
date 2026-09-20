import Foundation
import Testing
@testable import MorselCore
@testable import MorselData

/// 2026-09-17 12:00:00 UTC.
private let noonUTC: Millis = 1_789_646_400_000

private func meal(_ store: MealStore, at offsetMs: Millis, kcal: Int?) async throws {
    let id = try await store.createMeal(startedAt: noonUTC + offsetMs, restMs: 30_000)
    try await store.endMeal(id: id, endedAt: noonUTC + offsetMs + 60_000, pausedMs: 0)
    if let kcal {
        try await store.setNutrition(kcal: kcal, notes: nil, mealID: id)
    }
}

@Suite("Daily intake totals")
struct DailyIntake {
    @Test("meals on the same day sum into one entry")
    func sumsWithinADay() async throws {
        let store = try MealStore(path: nil)
        try await meal(store, at: 0, kcal: 600)
        try await meal(store, at: 3_600_000 * 4, kcal: 900)

        let days = try await store.dailyIntake(timeZone: .gmt)
        #expect(days.count == 1)
        #expect(days[0].kcal == 1500)
        #expect(days[0].meals == 2, "meal count travels with the total")
    }

    @Test("a meal with no calorie figure is skipped, not counted as zero")
    func uncostedMealsAreSkipped() async throws {
        let store = try MealStore(path: nil)
        try await meal(store, at: 0, kcal: 700)
        try await meal(store, at: 3_600_000, kcal: nil)

        let days = try await store.dailyIntake(timeZone: .gmt)
        #expect(days[0].kcal == 700)
        #expect(days[0].meals == 1, "the uncosted meal does not dilute the day")
    }

    @Test("a day whose only meal was uncosted does not appear at all")
    func uncostedDayIsAbsent() async throws {
        let store = try MealStore(path: nil)
        try await meal(store, at: 0, kcal: nil)
        #expect(try await store.dailyIntake(timeZone: .gmt).isEmpty, "absent, rather than a day of zero")
    }

    @Test("days are grouped by local time, so a late dinner stays on its own day")
    func groupsByLocalDay() async throws {
        let store = try MealStore(path: nil)
        // 23:40 in New York is already 03:40 the next morning in UTC. The meal
        // belongs to the evening you ate it.
        let newYork = TimeZone(identifier: "America/New_York")!
        try await meal(store, at: 3_600_000 * 15 + 2_400_000, kcal: 800)

        let local = try await store.dailyIntake(timeZone: newYork)
        #expect(local.map(\.date) == ["2026-09-17"], "stays on the 17th where the eater was")

        let utc = try await store.dailyIntake(timeZone: .gmt)
        #expect(utc.map(\.date) == ["2026-09-18"], "and would have slid to the 18th under UTC")
    }

    @Test("results come back oldest first, which is what the rolling mean expects")
    func oldestFirst() async throws {
        let store = try MealStore(path: nil)
        try await meal(store, at: 86_400_000 * 2, kcal: 300)
        try await meal(store, at: 0, kcal: 100)
        try await meal(store, at: 86_400_000, kcal: 200)

        let days = try await store.dailyIntake(timeZone: .gmt)
        #expect(days.map(\.kcal) == [100, 200, 300])
    }

    @Test("an empty store charts nothing")
    func emptyStore() async throws {
        let store = try MealStore(path: nil)
        #expect(try await store.dailyIntake(timeZone: .gmt).isEmpty)
    }
}
