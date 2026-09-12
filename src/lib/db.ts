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

        CREATE TABLE IF NOT EXISTS setting (
          key   TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
      `);
      return db;
    });
  }
  return dbPromise;
}

function toIso(ms: number): string {
  return new Date(ms).toISOString();
}

function fromIso(iso: string): number {
  return new Date(iso).getTime();
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

export interface MealHistoryRow {
  id: number;
  startedAt: number;
  durationMs: number;
  pausedMs: number;
  biteCount: number;
  meanRestMs: number | null;
  /** Bites confirmed before the cue fired, per bite.early in mealTimer.ts. */
  earlyBites: number;
  fullness: number | null;
}

/** Completed meals, most recent first. */
export async function listMeals(limit = 100): Promise<MealHistoryRow[]> {
  const db = await getDb();
  const rows = await db.getAllAsync<{
    id: number;
    started_at: string;
    ended_at: string;
    bite_count: number;
    paused_s: number;
    fullness_after: number | null;
    mean_rest_s: number | null;
    early_bites: number;
  }>(
    `SELECT
       m.id, m.started_at, m.ended_at, m.bite_count, m.paused_s, m.fullness_after,
       AVG(b.interval_s) AS mean_rest_s,
       -- An early bite is confirmed the instant it's cued (before the rest
       -- window elapses) — see mealTimer.ts CONFIRM_BITE, where an early
       -- bite's cued_at and taken_at land on the same timestamp.
       SUM(CASE WHEN b.taken_at = b.cued_at THEN 1 ELSE 0 END) AS early_bites
     FROM meal m
     LEFT JOIN bite b ON b.meal_id = m.id
     WHERE m.ended_at IS NOT NULL
     GROUP BY m.id
     ORDER BY m.started_at DESC
     LIMIT ?`,
    limit,
  );

  return rows.map((r) => {
    const startedAt = fromIso(r.started_at);
    const endedAt = fromIso(r.ended_at);
    return {
      id: r.id,
      startedAt,
      durationMs: Math.max(0, endedAt - startedAt - r.paused_s * 1000),
      pausedMs: r.paused_s * 1000,
      biteCount: r.bite_count,
      meanRestMs: r.mean_rest_s !== null ? r.mean_rest_s * 1000 : null,
      earlyBites: r.early_bites,
      fullness: r.fullness_after,
    };
  });
}

export async function getSetting(key: string): Promise<string | null> {
  const db = await getDb();
  const row = await db.getFirstAsync<{ value: string }>(
    `SELECT value FROM setting WHERE key = ?`,
    key,
  );
  return row?.value ?? null;
}

export async function setSetting(key: string, value: string): Promise<void> {
  const db = await getDb();
  await db.runAsync(
    `INSERT INTO setting (key, value) VALUES (?, ?)
     ON CONFLICT(key) DO UPDATE SET value = excluded.value`,
    key,
    value,
  );
}
