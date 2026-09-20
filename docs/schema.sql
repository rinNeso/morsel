-- Morsel schema. SQLite via expo-sqlite.
-- Timestamps are ISO8601 UTC strings; dates are local-day 'YYYY-MM-DD'.
-- SQLite has no native date type, and storing the local day for weights matters:
-- "which day did I weigh in" is a local-calendar question, not a UTC instant.

PRAGMA foreign_keys = ON;

CREATE TABLE meal (
  id                INTEGER PRIMARY KEY,
  started_at        TEXT    NOT NULL,
  ended_at          TEXT,
  label             TEXT,              -- breakfast | lunch | dinner | snack | free text
  target_interval_s INTEGER NOT NULL,  -- configured seconds between bite cues
  target_duration_s INTEGER,           -- optional "make it last 20 min" goal
  bite_count        INTEGER NOT NULL DEFAULT 0,
  paused_s          INTEGER NOT NULL DEFAULT 0,
  hunger_before     INTEGER,           -- 1-10, optional
  fullness_after    INTEGER,           -- 1-10, the key feedback signal
  notes             TEXT,
  -- Flat total, added ahead of the meal_item/food modelling below. The v4
  -- correlation needs the total, not the breakdown; v3 sums its items here.
  kcal              INTEGER,
  photo_uri         TEXT,
  -- timed | manual. Recorded rather than inferred from bite_count = 0: a
  -- manual meal has no measured pace, and the v4 correlation would otherwise
  -- average it into every pace figure as a timed meal that logged nothing.
  source            TEXT    NOT NULL DEFAULT 'timed'
);
CREATE INDEX meal_started_idx ON meal(started_at DESC);

-- One row per cue. Enables real pace analytics rather than just a bite count:
-- did the gaps actually hold, or did the pace collapse in the last third?
CREATE TABLE bite (
  id         INTEGER PRIMARY KEY,
  meal_id    INTEGER NOT NULL REFERENCES meal(id) ON DELETE CASCADE,
  seq        INTEGER NOT NULL,
  cued_at    TEXT    NOT NULL,
  taken_at   TEXT,               -- null when the user didn't confirm; cue still logged
  interval_s REAL,               -- actual elapsed since previous cue, excluding pauses
  -- Stored rather than derived. It is tempting to infer "early" from
  -- cued_at == taken_at, which does hold today because the reducer collapses
  -- both onto `now` for a bite taken before its cue — but that is a
  -- coincidence of the implementation, not something the data should depend on.
  early      INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX bite_meal_idx ON bite(meal_id, seq);

-- Foods cached from Open Food Facts / USDA, plus user-created entries.
-- Nutrients normalised per 100g so portion math is one multiply.
CREATE TABLE food (
  id           INTEGER PRIMARY KEY,
  source       TEXT    NOT NULL,   -- off | usda | custom
  source_id    TEXT,               -- barcode (off) or fdcId (usda)
  name         TEXT    NOT NULL,
  brand        TEXT,
  serving_desc TEXT,               -- human label, e.g. "1 cup (240 g)"
  serving_g    REAL,               -- grams in that default serving
  kcal_100g    REAL    NOT NULL,
  protein_100g REAL,
  carb_100g    REAL,
  fat_100g     REAL,
  fiber_100g   REAL,
  sugar_100g   REAL,
  sodium_mg100g REAL,
  favorite     INTEGER NOT NULL DEFAULT 0,
  use_count    INTEGER NOT NULL DEFAULT 0,
  last_used_at TEXT,
  UNIQUE(source, source_id)
);
-- Drives the recents/favourites list that does most of the logging work.
CREATE INDEX food_recent_idx ON food(favorite DESC, use_count DESC, last_used_at DESC);

CREATE TABLE meal_item (
  id      INTEGER PRIMARY KEY,
  meal_id INTEGER NOT NULL REFERENCES meal(id) ON DELETE CASCADE,
  food_id INTEGER NOT NULL REFERENCES food(id),
  qty_g   REAL    NOT NULL
);
CREATE INDEX meal_item_meal_idx ON meal_item(meal_id);

-- A saved combo logged as a unit ("my usual breakfast").
CREATE TABLE recipe (
  id   INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE
);
CREATE TABLE recipe_item (
  id        INTEGER PRIMARY KEY,
  recipe_id INTEGER NOT NULL REFERENCES recipe(id) ON DELETE CASCADE,
  food_id   INTEGER NOT NULL REFERENCES food(id),
  qty_g     REAL    NOT NULL
);

-- Stored in kg internally; display units are a presentation setting.
-- One weigh-in per local day: the EWMA trend assumes a daily series, and multiple
-- same-day readings are noise the trend is specifically designed to discard.
CREATE TABLE weight (
  id          INTEGER PRIMARY KEY,
  measured_on TEXT    NOT NULL UNIQUE,   -- local 'YYYY-MM-DD'
  kg          REAL    NOT NULL,
  source      TEXT    NOT NULL DEFAULT 'manual',  -- manual | healthkit | import
  hk_uuid     TEXT,                      -- HealthKit sample id, for dedupe on re-sync
  noted_at    TEXT    NOT NULL
);
CREATE INDEX weight_date_idx ON weight(measured_on);

CREATE TABLE setting (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
