// The local mirror of the server's collections, plus two tables the SDK
// owns outright (`outbox`, `sync_state`).
//
// Every mirrored table carries two columns the server does not have:
//   `updated` — the server's own `updated` timestamp, kept so a queued
//               write can detect that the record moved underneath it.
//   `pending` — 1 while an unsent outbox op targets this row, so the UI
//               can grey it. Always 0 until the outbox lands.
//
// Money is INTEGER minor units everywhere. SQLite's REAL type must never
// appear in this file.
const int schemaVersion = 2;

/// The migration ladder, indexed by the version each entry migrates *to*.
/// `migrations[1]` builds a v0 (empty) database into v1. Adding a column
/// later means appending `migrations[2]`, never editing this entry — a
/// shipped migration is immutable.
const Map<int, List<String>> migrations = {1: _v1, 2: _v2};

/// v2 — `members.removed_at`: the server's marker for a member the owner
/// removed but whose row had to be kept, because expenses and balances
/// reference it. Empty means an active member, so every row an older build
/// wrote reads as active.
const List<String> _v2 = ["ALTER TABLE members ADD COLUMN removed_at TEXT NOT NULL DEFAULT ''"];

const List<String> _v1 = [
  '''
  CREATE TABLE groups (
    id         TEXT PRIMARY KEY,
    name       TEXT NOT NULL,
    currency   TEXT NOT NULL,
    version    INTEGER NOT NULL DEFAULT 0,
    owner_id   TEXT NOT NULL,
    is_direct  INTEGER NOT NULL DEFAULT 0,
    updated    TEXT,
    pending    INTEGER NOT NULL DEFAULT 0
  )''',
  '''
  CREATE TABLE members (
    id         TEXT PRIMARY KEY,
    group_id   TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    user_id    TEXT NOT NULL,
    role       TEXT NOT NULL,
    name       TEXT NOT NULL DEFAULT '',
    avatar_url TEXT NOT NULL DEFAULT '',
    updated    TEXT,
    pending    INTEGER NOT NULL DEFAULT 0
  )''',
  'CREATE INDEX members_by_group ON members(group_id)',
  '''
  CREATE TABLE expenses (
    id              TEXT PRIMARY KEY,
    group_id        TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    payer_member_id TEXT NOT NULL,
    description     TEXT NOT NULL DEFAULT '',
    amount_cents    INTEGER NOT NULL,
    split_type      TEXT NOT NULL,
    date            TEXT NOT NULL,
    updated         TEXT,
    pending         INTEGER NOT NULL DEFAULT 0
  )''',
  // The group-detail list is "newest first, paged", which this serves.
  // Search filters by description within one group — a scan over that
  // group's rows, small enough not to want its own index.
  'CREATE INDEX expenses_by_group_date ON expenses(group_id, date DESC)',
  '''
  CREATE TABLE split_entries (
    id               TEXT PRIMARY KEY,
    expense_id       TEXT NOT NULL REFERENCES expenses(id) ON DELETE CASCADE,
    member_id        TEXT NOT NULL,
    amount_cents     INTEGER NOT NULL,
    receipt_filename TEXT
  )''',
  'CREATE INDEX split_entries_by_expense ON split_entries(expense_id)',
  '''
  CREATE TABLE settlements (
    id             TEXT PRIMARY KEY,
    group_id       TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    from_member_id TEXT NOT NULL,
    to_member_id   TEXT NOT NULL,
    amount_cents   INTEGER NOT NULL,
    date           TEXT NOT NULL,
    note           TEXT NOT NULL DEFAULT '',
    updated        TEXT,
    pending        INTEGER NOT NULL DEFAULT 0
  )''',
  'CREATE INDEX settlements_by_group_date ON settlements(group_id, date DESC)',
  // Balances are derived, never client-authored: the server rewrites them
  // on every mutation and a pull replaces this table's rows wholesale.
  '''
  CREATE TABLE balances (
    group_id  TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    member_id TEXT NOT NULL,
    net_cents INTEGER NOT NULL,
    PRIMARY KEY (group_id, member_id)
  )''',
  // Not written yet — the outbox arrives with local-first writes. Created
  // now so the schema version does not have to move when it does.
  '''
  CREATE TABLE outbox (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    op           TEXT NOT NULL,
    record_id    TEXT NOT NULL,
    payload      TEXT NOT NULL,
    base_updated TEXT,
    receipt_path TEXT,
    state        TEXT NOT NULL DEFAULT 'pending',
    attempts     INTEGER NOT NULL DEFAULT 0,
    last_error   TEXT,
    created_at   TEXT NOT NULL
  )''',
  'CREATE INDEX outbox_by_record ON outbox(record_id)',
  // One row per group: the version last pulled, which is the cursor the
  // /api/splitcore/staleness check compares against.
  '''
  CREATE TABLE sync_state (
    group_id  TEXT PRIMARY KEY REFERENCES groups(id) ON DELETE CASCADE,
    version   INTEGER NOT NULL DEFAULT 0,
    synced_at TEXT
  )''',
];
