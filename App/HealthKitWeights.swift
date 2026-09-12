import Foundation
import HealthKit
import MorselData

/// Reads body-mass samples out of Apple Health.
///
/// Read-only by design. Weigh-ins recorded by a scale, Happy Scale or the
/// Health app itself already live there, and Morsel's job is to chart the
/// trend — not to become a second competing source of truth for the same
/// numbers.
///
/// Lives in the app target rather than MorselData on purpose: HealthKit is
/// iOS-only, and pulling it into the package would end the package's ability to
/// run its tests on Linux.
@MainActor
final class HealthKitWeights {
    private let health = HKHealthStore()

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    struct SyncResult: Equatable {
        let added: Int
        let skipped: Int
    }

    func requestAccess() async throws {
        try await health.requestAuthorization(toShare: [], read: [HKQuantityType(.bodyMass)])
    }

    /// Import every body-mass sample as one weigh-in per local day.
    ///
    /// Days already recorded are left alone rather than overwritten — a manual
    /// entry is a deliberate act, and re-syncing should not quietly replace it.
    func sync(into store: MealStore) async throws -> SyncResult {
        try await requestAccess()

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: HKQuantityType(.bodyMass))],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let samples = try await descriptor.result(for: health)

        // Health can hold several readings for one day; the trend wants one.
        // The earliest is taken, which is the morning weigh-in the Hacker's
        // Diet method assumes — and consistency matters more than which rule,
        // since a series that mixes morning and evening readings is measuring
        // the day's food as much as the body.
        var byDay: [String: Double] = [:]
        for sample in samples {
            let day = Self.localDay(sample.startDate)
            guard byDay[day] == nil else { continue }
            byDay[day] = sample.quantity.doubleValue(for: .gramUnit(with: .kilo))
        }

        let existing = Set(try await store.weighIns().map(\.measuredOn))
        var added = 0
        var skipped = 0

        for (day, kg) in byDay.sorted(by: { $0.key < $1.key }) {
            guard !existing.contains(day) else {
                skipped += 1
                continue
            }
            try await store.recordWeight(WeighIn(measuredOn: day, kg: kg, source: "healthkit"))
            added += 1
        }

        return SyncResult(added: added, skipped: skipped)
    }

    /// `YYYY-MM-DD` in the local calendar: which day you weighed in is a
    /// calendar question, not an instant.
    private static func localDay(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
