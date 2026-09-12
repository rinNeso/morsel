import Foundation
import GRDB
import MorselCore

/// A complete, portable snapshot of everything the app knows.
///
/// This is the backup story for an app with no backend and no sync: if the
/// phone changes or the app is deleted, this file is the only thing standing
/// between the owner and starting over. So it is JSON rather than a copy of the
/// SQLite file — readable by anything, inspectable by a human, and still
/// meaningful if a future schema has moved on.
///
/// Row ids are deliberately omitted. They are local autoincrement values with
/// no meaning outside this install; an import should mint its own and match
/// meals to bites structurally, which is why bites are nested inside their meal
/// rather than listed flat with a foreign key.
public struct MorselExport: Codable, Sendable, Equatable {
    /// Bumped when the shape changes, so an importer can tell what it is
    /// holding rather than guessing.
    public let formatVersion: Int
    public let exportedAt: String
    public let meals: [ExportedMeal]
    public let weighIns: [ExportedWeighIn]
    public let settings: [String: String]

    /// Version 2 added weigh-ins. Version 1 files still restore — they simply
    /// carry no weight history — which is why the decoder defaults the field
    /// rather than requiring it.
    public static let currentFormatVersion = 2

    public init(
        formatVersion: Int,
        exportedAt: String,
        meals: [ExportedMeal],
        weighIns: [ExportedWeighIn] = [],
        settings: [String: String]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.meals = meals
        self.weighIns = weighIns
        self.settings = settings
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        exportedAt = try container.decode(String.self, forKey: .exportedAt)
        meals = try container.decode([ExportedMeal].self, forKey: .meals)
        weighIns = try container.decodeIfPresent([ExportedWeighIn].self, forKey: .weighIns) ?? []
        settings = try container.decode([String: String].self, forKey: .settings)
    }
}

public struct ExportedWeighIn: Codable, Sendable, Equatable {
    /// Local day, `YYYY-MM-DD`.
    public let measuredOn: String
    public let kg: Double
    public let source: String
}

public struct ExportedMeal: Codable, Sendable, Equatable {
    public let startedAt: String
    public let endedAt: String?
    public let label: String?
    public let targetIntervalS: Int
    public let targetDurationS: Int?
    public let pausedS: Int
    public let hungerBefore: Int?
    public let fullnessAfter: Int?
    public let kcal: Int?
    public let notes: String?
    public let bites: [ExportedBite]
}

public struct ExportedBite: Codable, Sendable, Equatable {
    public let seq: Int
    public let cuedAt: String
    public let takenAt: String?
    public let intervalS: Double?
    public let early: Bool
}

extension MealStore {
    public func exportSnapshot() async throws -> MorselExport {
        try await dbQueue.read { db in
            let mealRows = try Row.fetchAll(db, sql: """
                SELECT id, started_at, ended_at, label, target_interval_s, target_duration_s,
                       paused_s, hunger_before, fullness_after, kcal, notes
                FROM meal
                ORDER BY started_at ASC
                """)

            // One query for every bite rather than one per meal, grouped in
            // memory. Personal-scale data, but there is no reason to make it
            // quadratic.
            let biteRows = try Row.fetchAll(db, sql: """
                SELECT meal_id, seq, cued_at, taken_at, interval_s, early
                FROM bite
                ORDER BY meal_id ASC, seq ASC
                """)

            var bitesByMeal: [Int64: [ExportedBite]] = [:]
            for row in biteRows {
                let mealID: Int64 = row["meal_id"]
                bitesByMeal[mealID, default: []].append(
                    ExportedBite(
                        seq: row["seq"],
                        cuedAt: row["cued_at"],
                        takenAt: row["taken_at"],
                        intervalS: row["interval_s"],
                        early: row["early"] ?? false
                    )
                )
            }

            let meals = mealRows.map { row in
                ExportedMeal(
                    startedAt: row["started_at"],
                    endedAt: row["ended_at"],
                    label: row["label"],
                    targetIntervalS: row["target_interval_s"],
                    targetDurationS: row["target_duration_s"],
                    pausedS: row["paused_s"] ?? 0,
                    hungerBefore: row["hunger_before"],
                    fullnessAfter: row["fullness_after"],
                    kcal: row["kcal"],
                    notes: row["notes"],
                    bites: bitesByMeal[row["id"]] ?? []
                )
            }

            let weighIns = try Row
                .fetchAll(db, sql: "SELECT measured_on, kg, source FROM weight ORDER BY measured_on ASC")
                .map { row in
                    ExportedWeighIn(
                        measuredOn: row["measured_on"],
                        kg: row["kg"],
                        source: row["source"] ?? "manual"
                    )
                }

            var settings: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT key, value FROM setting") {
                settings[row["key"]] = row["value"]
            }

            return MorselExport(
                formatVersion: MorselExport.currentFormatVersion,
                exportedAt: iso(from: Millis(Date().timeIntervalSince1970 * 1000)),
                meals: meals,
                weighIns: weighIns,
                settings: settings
            )
        }
    }

    public func exportJSON() async throws -> Data {
        let encoder = JSONEncoder()
        // Readable and diffable: this file is meant to be opened and understood,
        // not just round-tripped.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(await exportSnapshot())
    }
}
