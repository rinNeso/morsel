import Foundation
import GRDB
import MorselCore

public struct WeighIn: Sendable, Equatable, Identifiable {
    public var id: String { measuredOn }
    /// Local day, `YYYY-MM-DD`.
    public let measuredOn: String
    public let kg: Double
    public let source: String

    public init(measuredOn: String, kg: Double, source: String = "manual") {
        self.measuredOn = measuredOn
        self.kg = kg
        self.source = source
    }
}

extension MealStore {
    /// Record a weigh-in. A second reading for the same local day replaces the
    /// first rather than adding a point — the EWMA trend assumes a daily
    /// series, and two readings one morning apart are the water-weight noise
    /// the trend exists to smooth away, not two observations.
    public func recordWeight(_ weighIn: WeighIn, notedAt: Millis = Millis(Date().timeIntervalSince1970 * 1000)) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO weight (measured_on, kg, source, noted_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(measured_on) DO UPDATE SET
                        kg = excluded.kg,
                        source = excluded.source,
                        noted_at = excluded.noted_at
                    """,
                arguments: [weighIn.measuredOn, weighIn.kg, weighIn.source, iso(from: notedAt)]
            )
        }
    }

    /// Oldest first, which is the order the trend maths expects.
    public func weighIns() async throws -> [WeighIn] {
        try await dbQueue.read { db in
            try Row
                .fetchAll(db, sql: "SELECT measured_on, kg, source FROM weight ORDER BY measured_on ASC")
                .map { row in
                    WeighIn(measuredOn: row["measured_on"], kg: row["kg"], source: row["source"] ?? "manual")
                }
        }
    }

    public func deleteWeight(measuredOn: String) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM weight WHERE measured_on = ?", arguments: [measuredOn])
        }
    }

    /// Convenience for the chart and readouts: the raw series as the trend
    /// maths in MorselCore wants it.
    public func weightPoints() async throws -> [WeightPoint] {
        try await weighIns().map { WeightPoint(date: $0.measuredOn, kg: $0.kg) }
    }
}
