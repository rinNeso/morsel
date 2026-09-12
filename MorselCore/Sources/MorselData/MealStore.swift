import Foundation
import GRDB
import MorselCore

/// One meal, with its bite statistics folded in.
///
/// `durationMs` is nil for a meal that was never ended — the app killed
/// mid-meal, most likely. Those are listed rather than hidden: an invisible row
/// cannot be deleted, and it still turns up in exports, which makes an import
/// report meals "already here" that the owner cannot see.
public struct MealHistoryEntry: Sendable, Equatable, Identifiable, FetchableRecord, Decodable {
    public let id: Int64
    public let startedAt: Millis
    public let durationMs: Millis?
    public let pausedMs: Millis

    public let biteCount: Int
    public let meanRestMs: Double?
    public let earlyBites: Int
    public let fullness: Int?

    public var isFinished: Bool { durationMs != nil }
}

/// Local-first store. No backend, no account, no network — the whole point.
public final class MealStore: Sendable {
    /// Internal rather than private so Export.swift can read through it.
    let dbQueue: DatabaseQueue

    /// - Parameter path: on-disk location, or nil for an in-memory database
    ///   (used by tests).
    public init(path: String?) throws {
        if let path {
            dbQueue = try DatabaseQueue(path: path)
        } else {
            dbQueue = try DatabaseQueue()
        }
        try Schema.migrator.migrate(dbQueue)
    }

    /// Default on-disk location in Application Support.
    public static func defaultURL() throws -> URL {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return dir.appendingPathComponent("morsel.sqlite")
    }

    // MARK: Writes
    //
    // Written as the meal progresses rather than only at the end, so a crash or
    // force-quit mid-meal still leaves the bites taken so far on disk.

    /// Called when a meal starts. Returns the new meal's id.
    public func createMeal(startedAt: Millis, restMs: Millis) async throws -> Int64 {
        try await dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO meal (started_at, target_interval_s) VALUES (?, ?)",
                arguments: [iso(from: startedAt), Int(Double(restMs) / 1000)]
            )
            return db.lastInsertedRowID
        }
    }

    /// Called once per confirmed bite, keeping `meal.bite_count` in step.
    public func insert(bite: BiteRecord, mealID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO bite (meal_id, seq, cued_at, taken_at, interval_s, early)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    mealID,
                    bite.seq,
                    iso(from: bite.cuedAt),
                    iso(from: bite.takenAt),
                    bite.restMs.map { Double($0) / 1000 },
                    bite.early,
                ]
            )
            try db.execute(
                sql: "UPDATE meal SET bite_count = ? WHERE id = ?",
                arguments: [bite.seq, mealID]
            )
        }
    }

    /// Called once when the meal ends.
    public func endMeal(id: Int64, endedAt: Millis, pausedMs: Millis) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE meal SET ended_at = ?, paused_s = ? WHERE id = ?",
                arguments: [iso(from: endedAt), Int((Double(pausedMs) / 1000).rounded()), id]
            )
        }
    }

    public func setFullness(_ rating: Int, mealID: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE meal SET fullness_after = ? WHERE id = ?",
                arguments: [rating, mealID]
            )
        }
    }

    // MARK: Reads

    /// Every meal, most recent first, finished or not.
    public func listMeals(limit: Int = 100) async throws -> [MealHistoryEntry] {
        try await dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    m.id                AS id,
                    m.started_at        AS startedAt,
                    m.ended_at          AS endedAt,
                    m.bite_count        AS biteCount,
                    m.paused_s          AS pausedS,
                    m.fullness_after    AS fullness,
                    AVG(b.interval_s)   AS meanRestS,
                    SUM(b.early)        AS earlyBites
                FROM meal m
                LEFT JOIN bite b ON b.meal_id = m.id
                GROUP BY m.id
                ORDER BY m.started_at DESC
                LIMIT ?
                """, arguments: [limit])

            return rows.compactMap { row -> MealHistoryEntry? in
                guard let startedAt: String = row["startedAt"],
                      let started = millis(fromISO: startedAt)
                else { return nil }

                let pausedMs = (row["pausedS"] as Int? ?? 0) * 1000
                let meanRestS: Double? = row["meanRestS"]

                // Nil ended_at means the meal was never finished; it is listed
                // without a duration rather than hidden.
                let ended = (row["endedAt"] as String?).flatMap(millis(fromISO:))

                return MealHistoryEntry(
                    id: row["id"],
                    startedAt: started,
                    durationMs: ended.map { max(0, $0 - started - pausedMs) },
                    pausedMs: pausedMs,
                    biteCount: row["biteCount"] ?? 0,
                    meanRestMs: meanRestS.map { $0 * 1000 },
                    earlyBites: row["earlyBites"] as Int? ?? 0,
                    fullness: row["fullness"]
                )
            }
        }
    }

    public func biteCount(forMeal id: Int64) async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bite WHERE meal_id = ?", arguments: [id]) ?? 0
        }
    }

    /// Bites go with it, via ON DELETE CASCADE.
    public func deleteMeal(id: Int64) async throws {
        try await dbQueue.write { db in
            try db.execute(sql: "DELETE FROM meal WHERE id = ?", arguments: [id])
        }
    }

    // MARK: Settings

    public func setting(_ key: String) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key])
        }
    }

    public func setSetting(_ key: String, to value: String) async throws {
        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO setting (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                arguments: [key, value]
            )
        }
    }
}
