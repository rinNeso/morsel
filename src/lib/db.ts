/**
 * SQLite persistence for meal records. Schema mirrors docs/schema.sql.
 *
 * This module only writes the meal/bite rows as the timer progresses — it does
 * not reconstruct an in-progress MealState on relaunch. If the app is force-quit
 * mid-meal, the bites taken so far and the meal's start time are safely on disk,
 * but resuming the *live* countdown where it left off is a separate feature
 * (tracked as a follow-up issue), not this one.
 */
import * as SQLite from "expo-sqlite";

import type { BiteRecord } from "./mealTimer.ts";

const DB_NAME = "morsel.db";

let dbPromise: Promise<SQLite.SQLiteDatabase> | null = null;

function getDb(): Promise<SQLite.SQLiteDatabase> {
  if (!dbPromise) {
    dbPromise = SQLite.openDatabaseAsync(DB_NAME).then(async (db) => {
      await db.execAsync(`
        PRAGMA journal_mode = WAL;
        PRAGMA foreign_keys = ON;

        CREATE TABLE IF NOT EXISTS meal (
          id                INTEGER PRIMARY KEY,
          started_at        TEXT    NOT NULL,
          ended_at          TEXT,
          label             TEXT,
          target_interval_s INTEGER NOT NULL,
          target_duration_s INTEGER,
          bite_count        INTEGER NOT NULL DEFAULT 0,
          paused_s          INTEGER NOT NULL DEFAULT 0,
          hunger_before     INTEGER,
          fullness_after    INTEGER,
          notes             TEXT,
          photo_uri         TEXT
        );
        CREATE INDEX IF NOT EXISTS meal_started_idx ON meal(started_at DESC);

        CREATE TABLE IF NOT EXISTS bite (
          id         INTEGER PRIMARY KEY,
          meal_id    INTEGER NOT NULL REFERENCES meal(id) ON DELETE CASCADE,
          seq        INTEGER NOT NULL,
          cued_at    TEXT    NOT NULL,
          taken_at   TEXT,
          interval_s REAL
        );
        CREATE INDEX IF NOT EXISTS bite_meal_idx ON bite(meal_id, seq);
      `);
      return db;
    });
  }
  return dbPromise;
}

function toIso(ms: number): string {
  return new Date(ms).toISOString();
}

/** Called on the idle -> ready transition that only START produces. */
export async function createMeal(startedAt: number, restMs: number): Promise<number> {
  const db = await getDb();
  const result = await db.runAsync(
    `INSERT INTO meal (started_at, target_interval_s) VALUES (?, ?)`,
    toIso(startedAt),
    Math.round(restMs / 1000),
  );
  return result.lastInsertRowId;
}

/** Called once per confirmed bite. Keeps meal.bite_count in sync as it goes. */
export async function insertBite(mealId: number, bite: BiteRecord): Promise<void> {
  const db = await getDb();
  await db.runAsync(
    `INSERT INTO bite (meal_id, seq, cued_at, taken_at, interval_s) VALUES (?, ?, ?, ?, ?)`,
    mealId,
    bite.seq,
    toIso(bite.cuedAt),
    toIso(bite.takenAt),
    bite.restMs !== null ? bite.restMs / 1000 : null,
  );
  await db.runAsync(`UPDATE meal SET bite_count = ? WHERE id = ?`, bite.seq, mealId);
}

/** Called once on END. */
export async function endMeal(mealId: number, endedAt: number, pausedMs: number): Promise<void> {
  const db = await getDb();
  await db.runAsync(
    `UPDATE meal SET ended_at = ?, paused_s = ? WHERE id = ?`,
    toIso(endedAt),
    Math.round(pausedMs / 1000),
    mealId,
  );
}
