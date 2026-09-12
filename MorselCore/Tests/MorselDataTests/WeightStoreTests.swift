import Foundation
import Testing
@testable import MorselCore
@testable import MorselData

@Suite("Recording weigh-ins")
struct RecordingWeighIns {
    @Test("weigh-ins come back oldest first, which is what the trend maths wants")
    func ordering() async throws {
        let store = try MealStore(path: nil)
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-03", kg: 89.4))
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-01", kg: 90.0))
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-02", kg: 89.7))

        #expect(try await store.weighIns().map(\.measuredOn) == ["2026-03-01", "2026-03-02", "2026-03-03"])
    }

    @Test("a second reading on the same day replaces the first")
    func oneReadingPerDay() async throws {
        let store = try MealStore(path: nil)
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-01", kg: 90.0))
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-01", kg: 89.6))

        let all = try await store.weighIns()
        #expect(all.count == 1, "the day is the key — two readings are not two observations")
        #expect(all[0].kg == 89.6, "the later reading wins")
    }

    @Test("a weigh-in can be removed")
    func deletion() async throws {
        let store = try MealStore(path: nil)
        try await store.recordWeight(WeighIn(measuredOn: "2026-03-01", kg: 90.0))
        try await store.deleteWeight(measuredOn: "2026-03-01")
        #expect(try await store.weighIns().isEmpty)
    }

    @Test("the stored series feeds the trend maths directly")
    func feedsTrend() async throws {
        let store = try MealStore(path: nil)
        // Two weeks losing a steady 0.5 kg/week.
        for day in 0..<14 {
            let date = dayString(dayNumber("2026-03-01")! + day)
            try await store.recordWeight(WeighIn(measuredOn: date, kg: 90.0 - (0.5 / 7) * Double(day)))
        }

        let points = try await store.weightPoints()
        #expect(points.count == 14)

        let rate = try #require(rateOfChange(points, windowDays: 14))
        #expect(abs(rate.kgPerWeek - -0.5) < 1e-9, "a clean series recovers the exact rate")

        let trend = ewmaTrend(points)
        #expect(trend.count == 14)
        #expect(trend.last!.trend > trend.last!.kg, "the trend lags a fall, which is the point of it")
    }

    @Test("an empty series produces no trend and no rate rather than a wrong one")
    func emptySeries() async throws {
        let store = try MealStore(path: nil)
        let points = try await store.weightPoints()
        #expect(points.isEmpty)
        #expect(ewmaTrend(points).isEmpty)
        #expect(rateOfChange(points) == nil)
    }
}
