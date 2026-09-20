import Foundation
import GRDB
import MorselCore

public struct ImportResult: Sendable, Equatable {
    /// Meals written.
    public let imported: Int
    /// Meals already present, matched on `started_at`.
    public let skipped: Int
    /// Settings taken from the file because nothing local held that key.
    public let settingsApplied: Int
    /// Weigh-ins written.
    public let weighInsImported: Int
    /// Days already recorded here, left as they were.
    public let weighInsSkipped: Int

    public init(
        imported: Int,
        skipped: Int,
        settingsApplied: Int,
        weighInsImported: Int = 0,
        weighInsSkipped: Int = 0
    ) {
        self.imported = imported
        self.skipped = skipped
        self.settingsApplied = settingsApplied
        self.weighInsImported = weighInsImported
        self.weighInsSkipped = weighInsSkipped
    }
}

public enum ImportError: Error, LocalizedError, Equatable {
    case unsupportedFormat(found: Int, supported: Int)
    case malformed

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(found, supported):
            "This file is in format version \(found); this version of Morsel understands \(supported). "
                + "Update the app and try again."
        case .malformed:
            "This file isn't a Morsel export, or it's damaged."
        }
    }
}

extension MealStore {
    /// Merge rather than replace: restoring on a new phone should not destroy
    /// anything already logged there.
    ///
    /// Meals are matched on `started_at`, which is a sound natural key — two
    /// meals cannot begin at the same instant. That makes importing the same
    /// file twice a no-op rather than a way to double your history.
    ///
    /// Settings are applied only where nothing local already holds the key. The
    /// restore case (fresh install, empty settings) gets its appearance back;
    /// an established install does not silently have its colours rewritten by a
    /// year-old file.
    public func importSnapshot(_ snapshot: MorselExport) async throws -> ImportResult {
        guard snapshot.formatVersion <= MorselExport.currentFormatVersion else {
            throw ImportError.unsupportedFormat(
                found: snapshot.formatVersion,
                supported: MorselExport.currentFormatVersion
            )
        }

        return try await dbQueue.write { db in
            let existing = Set(try String.fetchAll(db, sql: "SELECT started_at FROM meal"))
            var imported = 0
            var skipped = 0

            for meal in snapshot.meals {
                guard !existing.contains(meal.startedAt) else {
                    skipped += 1
                    continue
                }

                try db.execute(
                    sql: """
                        INSERT INTO meal (
                            started_at, ended_at, label, target_interval_s, target_duration_s,
                            bite_count, paused_s, hunger_before, fullness_after, kcal, notes,
                            source
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        meal.startedAt, meal.endedAt, meal.label,
                        meal.targetIntervalS, meal.targetDurationS,
                        // Derived from the bites actually present rather than
                        // carried in the file, so a count can never disagree
                        // with the rows it is counting.
                        meal.bites.count,
                        meal.pausedS, meal.hungerBefore, meal.fullnessAfter, meal.kcal, meal.notes,
                        // An export predating manual meals carries no source;
                        // everything in one was timed.
                        meal.source ?? "timed",
                    ]
                )
                let mealID = db.lastInsertedRowID

                for bite in meal.bites {
                    try db.execute(
                        sql: """
                            INSERT INTO bite (meal_id, seq, cued_at, taken_at, interval_s, early)
                            VALUES (?, ?, ?, ?, ?, ?)
                            """,
                        arguments: [mealID, bite.seq, bite.cuedAt, bite.takenAt, bite.intervalS, bite.early]
                    )
                }
                imported += 1
            }

            // Same merge rule as meals, keyed on the day: a day already weighed
            // in is not overwritten by a backup.
            let existingDays = Set(try String.fetchAll(db, sql: "SELECT measured_on FROM weight"))
            var weighInsImported = 0
            var weighInsSkipped = 0
            let notedAt = iso(from: Millis(Date().timeIntervalSince1970 * 1000))

            for weighIn in snapshot.weighIns {
                guard !existingDays.contains(weighIn.measuredOn) else {
                    weighInsSkipped += 1
                    continue
                }
                try db.execute(
                    sql: "INSERT INTO weight (measured_on, kg, source, noted_at) VALUES (?, ?, ?, ?)",
                    arguments: [weighIn.measuredOn, weighIn.kg, weighIn.source, notedAt]
                )
                weighInsImported += 1
            }

            var settingsApplied = 0
            for (key, value) in snapshot.settings {
                let present = try Bool.fetchOne(
                    db, sql: "SELECT EXISTS(SELECT 1 FROM setting WHERE key = ?)", arguments: [key]
                ) ?? false
                guard !present else { continue }
                try db.execute(
                    sql: "INSERT INTO setting (key, value) VALUES (?, ?)",
                    arguments: [key, value]
                )
                settingsApplied += 1
            }

            return ImportResult(
                imported: imported,
                skipped: skipped,
                settingsApplied: settingsApplied,
                weighInsImported: weighInsImported,
                weighInsSkipped: weighInsSkipped
            )
        }
    }

    public func importJSON(_ data: Data) async throws -> ImportResult {
        guard let snapshot = try? JSONDecoder().decode(MorselExport.self, from: data) else {
            throw ImportError.malformed
        }
        return try await importSnapshot(snapshot)
    }
}
