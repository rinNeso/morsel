import Foundation
import GRDB

/// Schema for Morsel's local store, mirroring `docs/schema.sql`.
///
/// Timestamps are ISO8601 UTC strings; weigh-in dates (v2) will be local-day
/// `YYYY-MM-DD`, because "which day did I weigh in" is a calendar question,
/// not an instant. SQLite has no native date type, so both are text.
enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-meals") { db in
            try db.create(table: "meal") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("started_at", .text).notNull()
                t.column("ended_at", .text)
                t.column("label", .text) // breakfast | lunch | dinner | snack | free text
                t.column("target_interval_s", .integer).notNull()
                t.column("target_duration_s", .integer) // optional "make it last 20 min" goal
                t.column("bite_count", .integer).notNull().defaults(to: 0)
                t.column("paused_s", .integer).notNull().defaults(to: 0)
                t.column("hunger_before", .integer) // 1-10, optional
                t.column("fullness_after", .integer) // 1-10, the key feedback signal
                t.column("notes", .text)
                t.column("photo_uri", .text)
            }
            try db.create(index: "meal_started_idx", on: "meal", columns: ["started_at"])

            // One row per bite. Enables real pace analytics rather than just a
            // count: did the gaps actually hold, or did the pace collapse in
            // the last third?
            try db.create(table: "bite") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("meal_id", .integer)
                    .notNull()
                    .references("meal", onDelete: .cascade)
                t.column("seq", .integer).notNull()
                t.column("cued_at", .text).notNull()
                t.column("taken_at", .text)
                t.column("interval_s", .double) // actual elapsed since previous bite, pauses excluded
                // Stored explicitly rather than derived. The React Native build
                // inferred "early" from cued_at == taken_at, which happened to
                // hold because the reducer collapses both onto `now` for an
                // uncued bite — but that's a coincidence of the implementation,
                // not a contract the data should depend on.
                t.column("early", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "bite_meal_idx", on: "bite", columns: ["meal_id", "seq"])

            try db.create(table: "setting") { t in
                t.primaryKey("key", .text)
                t.column("value", .text).notNull()
            }
        }

        // A flat total on the meal, rather than the meal_item/food modelling in
        // docs/schema.sql that v3 will bring. That breakdown is for logging
        // convenience; the *total* is what the v4 correlation needs — fullness
        // at a given calorie load — so this is the minimum that makes the
        // analysis possible, and v3 can sum its items into the same column.
        migrator.registerMigration("v2-meal-calories") { db in
            try db.alter(table: "meal") { t in
                t.add(column: "kcal", .integer)
            }
        }

        migrator.registerMigration("v3-weight") { db in
            // Stored in kg; display units are a presentation setting.
            //
            // One weigh-in per local day, enforced. The EWMA trend assumes a
            // daily series, and several readings on the same morning are the
            // water-weight noise the trend exists to discard — so a second
            // reading replaces the first rather than adding a point.
            try db.create(table: "weight") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("measured_on", .text).notNull().unique() // local YYYY-MM-DD
                t.column("kg", .double).notNull()
                t.column("source", .text).notNull().defaults(to: "manual") // manual | healthkit | import
                t.column("hk_uuid", .text) // HealthKit sample id, for dedupe on re-sync
                t.column("noted_at", .text).notNull()
            }
            try db.create(index: "weight_date_idx", on: "weight", columns: ["measured_on"])
        }

        migrator.registerMigration("v4-followup-fullness") { db in
            try db.alter(table: "meal") { t in
                t.add(column: "fullness_later", .integer) // 1-10, the check-in
                // When the answer actually arrived. A reply three hours late is
                // a different measurement from one at forty-five minutes, and
                // recording it as though it were on time would quietly corrupt
                // the one thing this check-in exists to measure.
                t.add(column: "fullness_later_at", .text)
            }
        }

        return migrator
    }
}
