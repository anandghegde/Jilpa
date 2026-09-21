import GRDB

/// The activity store's tables. docs/ARCHITECTURE.md, Data, has the same SQL with the reasons.
enum Schema {
  static let version = 1

  /// Tables that exist for a later work package and have no write API yet, so the export does
  /// not cover them. A test fails when a table is neither exported nor named here.
  static let tablesWithoutWriter: Set<String> = ["consent", "save_outcome"]

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("v1") { db in try db.execute(sql: v1) }
    return migrator
  }

  static let v1 = """
    CREATE TABLE location (
      id INTEGER PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      volume_uuid TEXT, file_id INTEGER,
      persistent_ids INTEGER,
      bookmark BLOB,
      kind TEXT NOT NULL,
      git_root INTEGER NOT NULL DEFAULT 0,
      -- The user configured this folder. Retention and erase keep the row, and activity never
      -- overwrites the identity recorded for it.
      configured INTEGER NOT NULL DEFAULT 0,
      last_state TEXT
    );
    -- The key of the location and of every ancestor, so a folder exclusion added later can
    -- suppress rows that are already stored.
    CREATE TABLE location_ancestor (
      location_id INTEGER NOT NULL REFERENCES location(id) ON DELETE CASCADE,
      folder_key TEXT NOT NULL,
      PRIMARY KEY (location_id, folder_key)
    ) WITHOUT ROWID;
    CREATE TABLE dialog_session (
      id TEXT PRIMARY KEY,
      app TEXT NOT NULL, app_version TEXT, os_build TEXT,
      purpose TEXT NOT NULL, presentation TEXT, signature_id TEXT,
      opened_at REAL NOT NULL, closed_at REAL,
      original_location INTEGER REFERENCES location(id),
      outcome TEXT NOT NULL,
      outcome_evidence TEXT,
      confirmed_location INTEGER REFERENCES location(id),
      file_ext TEXT, context_id TEXT,
      auto_trigger TEXT,
      holdout INTEGER NOT NULL DEFAULT 0,
      -- Where the confirmed folder stood in the frozen shadow ranking: NULL is a dialog that
      -- does not count toward the hit rates, 0 is a miss, 1 to 5 is the rank.
      shadow_hit INTEGER,
      -- '' is no browser source, '?' is a browser source that could not be attributed,
      -- anything else is the host. source_evidence says where the host came from, or why not.
      source_domain TEXT NOT NULL DEFAULT '',
      source_evidence TEXT
    );
    CREATE INDEX dialog_session_opened ON dialog_session(opened_at);
    -- signals is the kinds of evidence, strongest first, joined by commas.
    CREATE TABLE shadow_rank (
      session_id TEXT REFERENCES dialog_session(id) ON DELETE CASCADE,
      rank INTEGER, location_id INTEGER REFERENCES location(id), score REAL, signals TEXT,
      PRIMARY KEY (session_id, rank)
    );
    CREATE TABLE nav_attempt (
      id INTEGER PRIMARY KEY, session_id TEXT NOT NULL, seq INTEGER NOT NULL,
      at REAL NOT NULL,
      -- An attempt is written while the dialog is open, so its session row does not exist yet
      -- and may never: it carries its own app, because a read with no app cannot be filtered.
      app TEXT NOT NULL,
      trigger TEXT NOT NULL, strategy TEXT, target_location INTEGER REFERENCES location(id),
      result TEXT NOT NULL, reason TEXT, latency_ms INTEGER,
      corrected INTEGER NOT NULL DEFAULT 0, safety_flags INTEGER NOT NULL DEFAULT 0
    );
    -- An attempt is named by its dialog and its number, so writing one again replaces it: that
    -- is how a correction found later is recorded.
    CREATE UNIQUE INDEX nav_attempt_of_session ON nav_attempt(session_id, seq);
    -- SQLite treats NULLs in a primary key as distinct, so the optional parts of the key are
    -- '' and never NULL.
    CREATE TABLE dest_stat (
      location_id INTEGER NOT NULL REFERENCES location(id),
      app TEXT NOT NULL, purpose TEXT NOT NULL,
      ext_class TEXT NOT NULL DEFAULT '', context_id TEXT NOT NULL DEFAULT '',
      source_domain TEXT NOT NULL DEFAULT '',
      score REAL NOT NULL, uses INTEGER NOT NULL, updated_at REAL NOT NULL,
      pinned INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (location_id, app, purpose, ext_class, context_id, source_domain)
    ) WITHOUT ROWID;
    CREATE TABLE consent (
      app TEXT, purpose TEXT, opted_in INTEGER NOT NULL,
      state TEXT NOT NULL, state_reason TEXT, changed_at REAL,
      PRIMARY KEY (app, purpose)
    );
    CREATE TABLE save_outcome (
      session_id TEXT PRIMARY KEY REFERENCES dialog_session(id) ON DELETE CASCADE,
      status TEXT NOT NULL, final_location INTEGER REFERENCES location(id), identity BLOB,
      file_name TEXT, evidence TEXT, settled_at REAL
    );
    """
}
