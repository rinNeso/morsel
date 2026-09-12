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
    public let settings: [String: String]

    public static let currentFormatVersion = 1
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
                       paused_s, hunger_before, fullness_after, notes
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
                    notes: row["notes"],
                    bites: bitesByMeal[row["id"]] ?? []
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
