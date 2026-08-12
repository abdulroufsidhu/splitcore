# Offline-First Sync and Auth Persistence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `splitcore_sdk` local-first — a SQLite database is the single source of truth the UI reads from, reads are reactive streams, and an event-driven sync engine keeps it aligned with the server without polling.

**Architecture:** Two new module trees under `splitcore_sdk/lib/src/` — `local/` (SQLite, DAOs, change bus) and `sync/` (connectivity, sync engine, events). The existing `remote/` layer is unchanged in behavior but demoted: only the sync engine and `AuthApi` call it. A thin `repo/` layer becomes the public surface, combining a DAO (reads) with a remote API (writes). The layering rule is unchanged and still enforced: no PocketBase type crosses out of `remote/`, and `app/lib/` never imports `package:pocketbase`.

**Tech Stack:** Dart 3.9.2, `package:sqlite3` ^2.4.0 (pure-Dart FFI to the system libsqlite3), PocketBase Dart client 0.22, `dart test` against a real PocketBase subprocess (`test/support/pb_server.dart`).

**Design spec:** `docs/superpowers/specs/2026-08-06-offline-first-sync-design.md`

## Global Constraints

- **Phase 1 only.** This plan covers Phase 1 of the spec: local DB, reactive reads, pull-on-connect, the auth fix, and `FileTokenStore`. Writes still require a connection and still go straight to the server. The outbox (Phase 2) and realtime/receipts (Phase 3) are outlined at the end but not implemented here.
- `splitcore_sdk` stays a **pure Dart package**. It must not gain a `flutter:` dependency. `dart test` must keep running headless.
- All money is `int64` minor units — a Dart `int`. Never a `double`.
- No money is computed in Dart. Balances come from the server's `balances` rows or from the Go FFI engine, never from arithmetic written here.
- No PocketBase type (`PocketBase`, `RecordModel`, `AuthStore`, `ClientException`) may appear in `splitcore_sdk/lib/splitcore_sdk.dart`'s exports or anywhere under `app/lib/`.
- Every new public SDK type is exported through `splitcore_sdk/lib/splitcore_sdk.dart` — nothing under `lib/src/` is imported directly by the app.
- Tests use `sqlite3.openInMemory()` — the real engine, no temp files, no mocks.
- Dart formatting: `dart format --line-length 100`.
- Run `make check` before every commit step.
- The system `libsqlite3.so` satisfies `package:sqlite3` on Linux and macOS. **Android and iOS need the app to add `sqlite3_flutter_libs`** — that is an `app/pubspec.yaml` change in Task 7, not an SDK dependency.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `splitcore_sdk/lib/src/local/schema.dart` | `CREATE TABLE` statements and the migration ladder | **new** |
| `splitcore_sdk/lib/src/local/database.dart` | Opens SQLite, runs migrations, exposes `transaction()` and the change bus | **new** |
| `splitcore_sdk/lib/src/local/change_bus.dart` | Broadcast stream of touched table names | **new** |
| `splitcore_sdk/lib/src/local/ids.dart` | Mints PocketBase-format 15-char IDs | **new** |
| `splitcore_sdk/lib/src/local/dao/group_dao.dart` | `groups` + `members` rows ⇄ `Group`/`GroupMember` | **new** |
| `splitcore_sdk/lib/src/local/dao/expense_dao.dart` | `expenses` + `split_entries` rows ⇄ `Expense`/`SplitEntry` | **new** |
| `splitcore_sdk/lib/src/local/dao/settlement_dao.dart` | `settlements` rows ⇄ `Settlement` | **new** |
| `splitcore_sdk/lib/src/local/dao/balance_dao.dart` | `balances` rows ⇄ `Balance` | **new** |
| `splitcore_sdk/lib/src/local/dao/sync_state_dao.dart` | Per-group sync cursor (`version`, `synced_at`) | **new** |
| `splitcore_sdk/lib/src/sync/connectivity.dart` | `ConnectivityMonitor` interface + `AlwaysOnline` | **new** |
| `splitcore_sdk/lib/src/sync/events.dart` | `SyncEvent` hierarchy | **new** |
| `splitcore_sdk/lib/src/sync/sync_engine.dart` | Pull loop, wake sources, backoff | **new** |
| `splitcore_sdk/lib/src/repo/groups_repository.dart` | `watchGroups`/`watchMembers` + write delegation | **new** |
| `splitcore_sdk/lib/src/repo/expenses_repository.dart` | `watch` + write delegation | **new** |
| `splitcore_sdk/lib/src/repo/balances_repository.dart` | `watch` + write delegation | **new** |
| `splitcore_sdk/lib/src/repo/settlements_repository.dart` | `watch` + write delegation | **new** |
| `splitcore_sdk/lib/src/remote/token_store.dart` | Adds `FileTokenStore` | modify |
| `splitcore_sdk/lib/src/remote/auth_api.dart:142-150` | `_refresh()` must not clear the session on a network error | modify |
| `splitcore_sdk/lib/src/remote/local_store.dart` | Superseded by `balance_dao.dart` | **delete** |
| `splitcore_sdk/lib/src/sdk.dart` | Wires the database, sync engine and repositories | modify |
| `splitcore_sdk/lib/splitcore_sdk.dart` | Exports the new public types | modify |
| `splitcore_sdk/pubspec.yaml` | Adds `sqlite3`, bumps to 0.2.0 | modify |
| `app/lib/offline_cache.dart` | Superseded by the local DB | **delete** |
| `app/lib/main.dart` | Supplies `databasePath` and a `ConnectivityMonitor` | modify |
| `app/pubspec.yaml` | Adds `connectivity_plus`, `sqlite3_flutter_libs`, `path_provider` | modify |

---

### Task 1: The database, its schema, and migrations

**Files:**
- Create: `splitcore_sdk/lib/src/local/schema.dart`
- Create: `splitcore_sdk/lib/src/local/database.dart`
- Modify: `splitcore_sdk/pubspec.yaml`
- Test: `splitcore_sdk/test/local/database_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `SplitcoreDb.inMemory()`, `SplitcoreDb.openAt(String path)`, `SplitcoreDb.schemaVersion` (`int`, const), `db.userVersion` (`int` getter), `db.raw` (`sqlite3.Database`), `db.close()`.

- [ ] **Step 1: Add the dependency**

In `splitcore_sdk/pubspec.yaml`, under `dependencies:`, add `sqlite3` alphabetically (after `pocketbase`), and bump the version:

```yaml
version: 0.2.0
```

```yaml
dependencies:
  ffi: ^2.1.3
  pocketbase: ^0.22.0
  sqlite3: ^2.4.0
  http: ^1.2.0
  image: ^4.2.0
```

Run: `cd splitcore_sdk && dart pub get`

- [ ] **Step 2: Write the failing test**

Create `splitcore_sdk/test/local/database_test.dart`:

```dart
import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

void main() {
  test('a fresh database is created at the current schema version', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    expect(db.userVersion, SplitcoreDb.schemaVersion);
  });

  test('every mirrored table and the sdk-owned tables exist', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final names = db.raw
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();

    expect(
      names,
      containsAll([
        'groups',
        'members',
        'expenses',
        'split_entries',
        'settlements',
        'balances',
        'outbox',
        'sync_state',
      ]),
    );
  });

  test('migrating an already-current database is a no-op, not an error', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    // Running the ladder a second time must not throw "table already exists".
    expect(db.migrate, returnsNormally);
    expect(db.userVersion, SplitcoreDb.schemaVersion);
  });

  test('foreign keys cascade so deleting an expense drops its split entries', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    db.raw.execute(
      "INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) "
      "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, '2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      "INSERT INTO members (id, group_id, user_id, role, name, avatar_url, updated, pending) "
      "VALUES ('m1', 'g1', 'u1', 'owner', 'Ada', '', '2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      "INSERT INTO expenses "
      "(id, group_id, payer_member_id, description, amount_cents, split_type, date, updated, pending) "
      "VALUES ('e1', 'g1', 'm1', 'Dinner', 3000, 'equal', '2026-08-06T00:00:00Z', "
      "'2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      "INSERT INTO split_entries (id, expense_id, member_id, amount_cents, receipt_filename) "
      "VALUES ('s1', 'e1', 'm1', 3000, NULL)",
    );

    db.raw.execute("DELETE FROM expenses WHERE id = 'e1'");

    final remaining = db.raw.select('SELECT COUNT(*) AS n FROM split_entries').first['n'] as int;
    expect(remaining, 0);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd splitcore_sdk && dart test test/local/database_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'splitcore_sdk'` on `src/local/database.dart`, because the file does not exist.

- [ ] **Step 4: Write the schema**

Create `splitcore_sdk/lib/src/local/schema.dart`:

```dart
// The local mirror of the server's collections, plus two tables the SDK
// owns outright (`outbox`, `sync_state`).
//
// Every mirrored table carries two columns the server does not have:
//   `updated` — the server's own `updated` timestamp, kept so a queued
//               write can detect that the record moved underneath it.
//   `pending` — 1 while an unsent outbox op targets this row, so the UI
//               can grey it. Always 0 until Phase 2 introduces the outbox.
//
// Money is INTEGER minor units everywhere. SQLite's REAL type must never
// appear in this file.
const int schemaVersion = 1;

/// The migration ladder, indexed by the version each entry migrates *to*.
/// `migrations[1]` builds a v0 (empty) database into v1. Adding a column
/// later means appending `migrations[2]`, never editing this entry — a
/// shipped migration is immutable.
const Map<int, List<String>> migrations = {1: _v1};

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
  // The group-detail list is "newest first, paged", and search filters by
  // description within a group. This index serves the first; the second is
  // a scan over one group's rows, which is small enough.
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
  // Written in Phase 2. Created now so the schema version does not have to
  // move when the outbox lands.
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
```

- [ ] **Step 5: Write the database wrapper**

Create `splitcore_sdk/lib/src/local/database.dart`:

```dart
// The local source of truth. Opening it runs any outstanding migrations,
// so a caller never sees a half-built schema.
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'schema.dart' as sql;

class SplitcoreDb {
  SplitcoreDb._(this.raw) {
    // Off by default in SQLite, and the cascades in schema.dart are load-
    // bearing: deleting an expense has to take its split entries with it.
    raw.execute('PRAGMA foreign_keys = ON');
    migrate();
  }

  /// Opens (or creates) the database file at [path].
  factory SplitcoreDb.openAt(String path) => SplitcoreDb._(sqlite.sqlite3.open(path));

  /// An ephemeral database, for tests. The real engine, no file.
  factory SplitcoreDb.inMemory() => SplitcoreDb._(sqlite.sqlite3.openInMemory());

  /// The schema version this build of the SDK expects.
  static const int schemaVersion = sql.schemaVersion;

  /// The underlying handle. DAOs use this; nothing outside `local/` should.
  final sqlite.Database raw;

  int get userVersion => raw.select('PRAGMA user_version').first['user_version'] as int;

  /// Applies every migration above the stored version, in order, inside one
  /// transaction — a partly-migrated database is not a state worth
  /// supporting. Idempotent: already-current is a no-op.
  void migrate() {
    final from = userVersion;
    if (from >= schemaVersion) return;

    raw.execute('BEGIN');
    try {
      for (var v = from + 1; v <= schemaVersion; v++) {
        for (final statement in sql.migrations[v]!) {
          raw.execute(statement);
        }
      }
      // PRAGMA does not accept a bound parameter, and `v` is a loop counter
      // over a const map — never user input.
      raw.execute('PRAGMA user_version = $schemaVersion');
      raw.execute('COMMIT');
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => raw.dispose();
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd splitcore_sdk && dart test test/local/database_test.dart`
Expected: PASS, 4 tests.

- [ ] **Step 7: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/pubspec.yaml splitcore_sdk/pubspec.lock \
  splitcore_sdk/lib/src/local/ splitcore_sdk/test/local/
git commit -m "feat(sdk): local sqlite schema and migration ladder"
```

---

### Task 2: The change bus and transactions

**Files:**
- Create: `splitcore_sdk/lib/src/local/change_bus.dart`
- Modify: `splitcore_sdk/lib/src/local/database.dart`
- Test: `splitcore_sdk/test/local/change_bus_test.dart`

**Interfaces:**
- Consumes: `SplitcoreDb` from Task 1.
- Produces: `ChangeBus.changes` (`Stream<Set<String>>`), `ChangeBus.emit(Set<String>)`, `db.changes` (`Stream<Set<String>>`), `db.transaction<T>(Set<String> tables, T Function() body)`, `db.watch<T>(Set<String> tables, T Function() query)` (`Stream<T>`).

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/local/change_bus_test.dart`:

```dart
import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

void main() {
  test('a transaction emits the tables it touched, once, after it commits', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final seen = <Set<String>>[];
    final sub = db.changes.listen(seen.add);
    addTearDown(sub.cancel);

    db.transaction({'groups'}, () {
      db.raw.execute(
        "INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) "
        "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, NULL, 0)",
      );
    });

    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      {'groups'},
    ]);
  });

  test('a failed transaction rolls back and emits nothing', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final seen = <Set<String>>[];
    final sub = db.changes.listen(seen.add);
    addTearDown(sub.cancel);

    expect(
      () => db.transaction({'groups'}, () {
        db.raw.execute(
          "INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) "
          "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, NULL, 0)",
        );
        throw StateError('boom');
      }),
      throwsStateError,
    );

    await Future<void>.delayed(Duration.zero);
    final rows = db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int;
    expect(rows, 0, reason: 'the insert must have rolled back');
    expect(seen, isEmpty, reason: 'a rolled-back transaction changed nothing to announce');
  });

  test('watch emits the current value immediately, then again on a matching change', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final emitted = <int>[];
    final sub = db
        .watch({'groups'}, () => db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int)
        .listen(emitted.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emitted, [0], reason: 'watch must not wait for a change to produce a first value');

    db.transaction({'groups'}, () {
      db.raw.execute(
        "INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) "
        "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, NULL, 0)",
      );
    });

    await Future<void>.delayed(Duration.zero);
    expect(emitted, [0, 1]);
  });

  test('watch ignores changes to tables it does not care about', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final emitted = <int>[];
    final sub = db
        .watch({'groups'}, () => db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int)
        .listen(emitted.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    db.transaction({'settlements'}, () {});
    await Future<void>.delayed(Duration.zero);

    expect(emitted, [0]);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd splitcore_sdk && dart test test/local/change_bus_test.dart`
Expected: FAIL — `The method 'transaction' isn't defined for the class 'SplitcoreDb'`.

- [ ] **Step 3: Write the change bus**

Create `splitcore_sdk/lib/src/local/change_bus.dart`:

```dart
// Announces which tables a committed write touched. Every `watch*` stream
// in the SDK is this plus a re-query — table granularity, not row, because
// a re-query of one group's rows is cheap and row-level tracking is a
// whole invalidation protocol nobody asked for.
import 'dart:async';

class ChangeBus {
  final _controller = StreamController<Set<String>>.broadcast();

  Stream<Set<String>> get changes => _controller.stream;

  /// Announces [tables]. Called only after a transaction commits — an
  /// announcement for a rolled-back write would make listeners re-query and
  /// see nothing changed, or worse, act on a write that never happened.
  void emit(Set<String> tables) {
    if (tables.isEmpty || _controller.isClosed) return;
    _controller.add(tables);
  }

  Future<void> close() => _controller.close();
}
```

- [ ] **Step 4: Add `transaction` and `watch` to the database**

In `splitcore_sdk/lib/src/local/database.dart`, add the import:

```dart
import 'dart:async';

import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'change_bus.dart';
import 'schema.dart' as sql;
```

Add the field, just below `final sqlite.Database raw;`:

```dart
  final _bus = ChangeBus();

  /// Table names touched by each committed transaction.
  Stream<Set<String>> get changes => _bus.changes;
```

Add the two methods, just above `void close()`:

```dart
  /// Runs [body] in a transaction and, on commit, announces [tables].
  ///
  /// SQLite has no nested transactions, and the SDK has no case that needs
  /// them: a write is one call. Nesting throws rather than silently
  /// flattening into the outer transaction, where a rollback would discard
  /// the caller's work without telling them.
  T transaction<T>(Set<String> tables, T Function() body) {
    if (_inTransaction) {
      throw StateError('SplitcoreDb.transaction cannot be nested');
    }
    _inTransaction = true;
    raw.execute('BEGIN');
    try {
      final result = body();
      raw.execute('COMMIT');
      _bus.emit(tables);
      return result;
    } catch (_) {
      raw.execute('ROLLBACK');
      rethrow;
    } finally {
      _inTransaction = false;
    }
  }

  bool _inTransaction = false;

  /// [query]'s current result, then its result again every time one of
  /// [tables] changes. The immediate first emission is the point: a screen
  /// binding to this renders local data on the first frame, with no
  /// loading state and no network.
  Stream<T> watch<T>(Set<String> tables, T Function() query) {
    late StreamController<T> controller;
    StreamSubscription<Set<String>>? sub;

    void push() {
      if (controller.isClosed) return;
      try {
        controller.add(query());
      } catch (e, s) {
        controller.addError(e, s);
      }
    }

    controller = StreamController<T>(
      onListen: () {
        push();
        sub = _bus.changes.listen((touched) {
          if (touched.any(tables.contains)) push();
        });
      },
      onCancel: () async => sub?.cancel(),
    );
    return controller.stream;
  }
```

Change `close()` to shut the bus down too:

```dart
  Future<void> close() async {
    await _bus.close();
    raw.dispose();
  }
```

- [ ] **Step 5: Fix the Task 1 tests for the now-async `close`**

In `splitcore_sdk/test/local/database_test.dart`, every `addTearDown(db.close)` still compiles — `addTearDown` accepts a `Future`-returning callback. No change needed. Confirm by running both files.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd splitcore_sdk && dart test test/local/`
Expected: PASS, 8 tests.

- [ ] **Step 7: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/lib/src/local/ splitcore_sdk/test/local/
git commit -m "feat(sdk): change bus, transactions and reactive watch queries"
```

---

### Task 3: Client-minted IDs

**Files:**
- Create: `splitcore_sdk/lib/src/local/ids.dart`
- Test: `splitcore_sdk/test/local/ids_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `newLocalId()` → `String`.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/local/ids_test.dart`:

```dart
import 'package:splitcore_sdk/src/local/ids.dart';
import 'package:test/test.dart';

void main() {
  test('an id matches PocketBase\'s own format: 15 chars of [a-z0-9]', () {
    for (var i = 0; i < 1000; i++) {
      expect(newLocalId(), matches(RegExp(r'^[a-z0-9]{15}$')));
    }
  });

  test('ids do not collide', () {
    final ids = {for (var i = 0; i < 10000; i++) newLocalId()};
    expect(ids, hasLength(10000));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd splitcore_sdk && dart test test/local/ids_test.dart`
Expected: FAIL — the URI `package:splitcore_sdk/src/local/ids.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `splitcore_sdk/lib/src/local/ids.dart`:

```dart
// PocketBase record ids are 15 characters of [a-z0-9], and PocketBase
// accepts a client-supplied `id` on create. Minting ids here is what makes
// offline writes possible at all: a split entry can reference an expense
// the server has never seen, and replaying a create that already landed
// fails with `validation_not_unique`, which the sync engine reads as
// "already applied" — so retries are idempotent for free.
import 'dart:math';

const _alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';

// Random.secure() rather than Random(): ids are guessable identifiers in
// URLs and filter expressions, and a predictable sequence would let one
// user enumerate another's records.
final _random = Random.secure();

String newLocalId() =>
    String.fromCharCodes([for (var i = 0; i < 15; i++) _alphabet.codeUnitAt(_random.nextInt(36))]);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/local/ids_test.dart`
Expected: PASS, 2 tests.

- [ ] **Step 5: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/lib/src/local/ids.dart splitcore_sdk/test/local/ids_test.dart
git commit -m "feat(sdk): client-minted PocketBase-format record ids"
```

---

### Task 4: The DAOs

**Files:**
- Create: `splitcore_sdk/lib/src/local/dao/group_dao.dart`
- Create: `splitcore_sdk/lib/src/local/dao/expense_dao.dart`
- Create: `splitcore_sdk/lib/src/local/dao/settlement_dao.dart`
- Create: `splitcore_sdk/lib/src/local/dao/balance_dao.dart`
- Create: `splitcore_sdk/lib/src/local/dao/sync_state_dao.dart`
- Test: `splitcore_sdk/test/local/dao_test.dart`

**Interfaces:**
- Consumes: `SplitcoreDb` (Task 1-2), the models in `src/models.dart`.
- Produces:
  - `GroupDao(db)`: `upsertGroups(List<Group>)`, `upsertMembers(String groupId, List<GroupMember>)`, `listGroups()` → `List<Group>`, `listMembers(String groupId)` → `List<GroupMember>`, `deleteGroupsMissingFrom(Set<String> keepIds)`.
  - `ExpenseDao(db)`: `replaceGroupExpenses(String groupId, List<Expense>, Map<String, List<SplitEntry>>)`, `listExpenses(String groupId, {String query = ''})` → `List<Expense>`, `listSplitEntries(String expenseId)` → `List<SplitEntry>`.
  - `SettlementDao(db)`: `replaceGroupSettlements(String groupId, List<Settlement>)`, `listSettlements(String groupId)` → `List<Settlement>`.
  - `BalanceDao(db)`: `replaceGroupBalances(String groupId, List<Balance>)`, `listBalances(String groupId)` → `List<Balance>`.
  - `SyncStateDao(db)`: `versionOf(String groupId)` → `int`, `markSynced(String groupId, int version)`, `syncedAt(String groupId)` → `DateTime?`.

All `upsert`/`replace` methods assume the caller already opened a transaction — they never open one themselves, so a pull can write several tables atomically.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/local/dao_test.dart`:

```dart
import 'package:splitcore_sdk/src/local/dao/balance_dao.dart';
import 'package:splitcore_sdk/src/local/dao/expense_dao.dart';
import 'package:splitcore_sdk/src/local/dao/group_dao.dart';
import 'package:splitcore_sdk/src/local/dao/settlement_dao.dart';
import 'package:splitcore_sdk/src/local/dao/sync_state_dao.dart';
import 'package:splitcore_sdk/src/local/database.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

const _group = Group(
  id: 'g1',
  name: 'Trip',
  currency: 'USD',
  version: 3,
  ownerId: 'u1',
);

void main() {
  late SplitcoreDb db;

  setUp(() {
    db = SplitcoreDb.inMemory();
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([_group]));
  });

  tearDown(() => db.close());

  test('a group round-trips', () {
    expect(GroupDao(db).listGroups(), [_group]);
  });

  test('upserting the same group twice updates rather than duplicating', () {
    const renamed = Group(
      id: 'g1',
      name: 'Trip to Rome',
      currency: 'USD',
      version: 4,
      ownerId: 'u1',
    );
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([renamed]));

    expect(GroupDao(db).listGroups(), [renamed]);
  });

  test('deleteGroupsMissingFrom removes groups the server no longer lists', () {
    const other = Group(id: 'g2', name: 'Flat', currency: 'EUR', version: 1, ownerId: 'u1');
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([other]));

    db.transaction({'groups'}, () => GroupDao(db).deleteGroupsMissingFrom({'g1'}));

    expect(GroupDao(db).listGroups().map((g) => g.id), ['g1']);
  });

  test('members round-trip and are scoped to their group', () {
    const member = GroupMember(
      id: 'm1',
      groupId: 'g1',
      userId: 'u1',
      role: 'owner',
      name: 'Ada',
    );
    db.transaction({'members'}, () => GroupDao(db).upsertMembers('g1', [member]));

    expect(GroupDao(db).listMembers('g1'), [member]);
    expect(GroupDao(db).listMembers('g2'), isEmpty);
  });

  test('replaceGroupExpenses writes expenses with their split entries', () {
    final expense = Expense(
      id: 'e1',
      groupId: 'g1',
      payerMemberId: 'm1',
      description: 'Dinner',
      amountCents: 3000,
      splitType: 'equal',
      date: DateTime.utc(2026, 8, 6),
    );
    const entry = SplitEntry(id: 's1', expenseId: 'e1', memberId: 'm1', amountCents: 3000);

    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [expense], {
        'e1': [entry],
      });
    });

    expect(ExpenseDao(db).listExpenses('g1'), [expense]);
    expect(ExpenseDao(db).listSplitEntries('e1'), [entry]);
  });

  test('replaceGroupExpenses drops expenses the server no longer has', () {
    final first = Expense(
      id: 'e1',
      groupId: 'g1',
      payerMemberId: 'm1',
      description: 'Dinner',
      amountCents: 3000,
      splitType: 'equal',
      date: DateTime.utc(2026, 8, 6),
    );
    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [first], const {});
    });

    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', const [], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1'), isEmpty);
  });

  test('listExpenses returns newest first and filters by description', () {
    final older = Expense(
      id: 'e1',
      groupId: 'g1',
      payerMemberId: 'm1',
      description: 'Dinner',
      amountCents: 3000,
      splitType: 'equal',
      date: DateTime.utc(2026, 8, 1),
    );
    final newer = Expense(
      id: 'e2',
      groupId: 'g1',
      payerMemberId: 'm1',
      description: 'Taxi',
      amountCents: 1200,
      splitType: 'equal',
      date: DateTime.utc(2026, 8, 5),
    );
    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [older, newer], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1').map((e) => e.id), ['e2', 'e1']);
    expect(ExpenseDao(db).listExpenses('g1', query: 'tax').map((e) => e.id), ['e2']);
  });

  test('settlements round-trip, newest first', () {
    final s = Settlement(
      id: 't1',
      groupId: 'g1',
      fromMemberId: 'm1',
      toMemberId: 'm2',
      amountCents: 500,
      date: DateTime.utc(2026, 8, 4),
      note: 'cash',
    );
    db.transaction({'settlements'}, () => SettlementDao(db).replaceGroupSettlements('g1', [s]));

    expect(SettlementDao(db).listSettlements('g1'), [s]);
  });

  test('balances are replaced wholesale, never merged', () {
    db.transaction({'balances'}, () {
      BalanceDao(db).replaceGroupBalances('g1', const [
        Balance(memberId: 'm1', netCents: 1500),
        Balance(memberId: 'm2', netCents: -1500),
      ]);
    });
    db.transaction({'balances'}, () {
      BalanceDao(db).replaceGroupBalances('g1', const [Balance(memberId: 'm1', netCents: 0)]);
    });

    expect(BalanceDao(db).listBalances('g1'), const [Balance(memberId: 'm1', netCents: 0)]);
  });

  test('an unsynced group reports version 0 so the first staleness check always pulls', () {
    expect(SyncStateDao(db).versionOf('g1'), 0);
    expect(SyncStateDao(db).syncedAt('g1'), isNull);
  });

  test('markSynced records the cursor and the time', () {
    db.transaction({'sync_state'}, () => SyncStateDao(db).markSynced('g1', 7));

    expect(SyncStateDao(db).versionOf('g1'), 7);
    expect(SyncStateDao(db).syncedAt('g1'), isNotNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd splitcore_sdk && dart test test/local/dao_test.dart`
Expected: FAIL — the DAO URIs do not exist.

- [ ] **Step 3: Write `group_dao.dart`**

```dart
// `groups` and `members` rows <-> Group/GroupMember.
//
// Every write here assumes the caller already opened a transaction (see
// SplitcoreDb.transaction) — a pull writes several tables and must land as
// one commit, so DAOs never open transactions of their own.
import '../../models.dart';
import '../database.dart';

class GroupDao {
  GroupDao(this._db);

  final SplitcoreDb _db;

  void upsertGroups(List<Group> groups) {
    final statement = _db.raw.prepare('''
      INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        currency = excluded.currency,
        version = excluded.version,
        owner_id = excluded.owner_id,
        is_direct = excluded.is_direct,
        updated = excluded.updated
    ''');
    try {
      for (final g in groups) {
        statement.execute([g.id, g.name, g.currency, g.version, g.ownerId, g.isDirect ? 1 : 0, null]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// Drops any group not in [keepIds] — the server's list is authoritative,
  /// so a group the user was removed from has to disappear locally too.
  void deleteGroupsMissingFrom(Set<String> keepIds) {
    if (keepIds.isEmpty) {
      _db.raw.execute('DELETE FROM groups');
      return;
    }
    final placeholders = List.filled(keepIds.length, '?').join(',');
    _db.raw.execute('DELETE FROM groups WHERE id NOT IN ($placeholders)', keepIds.toList());
  }

  List<Group> listGroups() => _db.raw
      .select('SELECT * FROM groups ORDER BY name COLLATE NOCASE')
      .map(
        (r) => Group(
          id: r['id'] as String,
          name: r['name'] as String,
          currency: r['currency'] as String,
          version: r['version'] as int,
          ownerId: r['owner_id'] as String,
          isDirect: (r['is_direct'] as int) == 1,
        ),
      )
      .toList();

  /// Replaces [groupId]'s member list wholesale — a removed member must not
  /// linger, and the list is small enough that a diff would be more code
  /// than it saves.
  void upsertMembers(String groupId, List<GroupMember> members) {
    _db.raw.execute('DELETE FROM members WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare('''
      INSERT INTO members (id, group_id, user_id, role, name, avatar_url, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    try {
      for (final m in members) {
        statement.execute([m.id, groupId, m.userId, m.role, m.name, m.avatarUrl, null]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<GroupMember> listMembers(String groupId) => _db.raw
      .select('SELECT * FROM members WHERE group_id = ? ORDER BY name COLLATE NOCASE', [groupId])
      .map(
        (r) => GroupMember(
          id: r['id'] as String,
          groupId: r['group_id'] as String,
          userId: r['user_id'] as String,
          role: r['role'] as String,
          name: r['name'] as String,
          avatarUrl: r['avatar_url'] as String,
        ),
      )
      .toList();
}
```

- [ ] **Step 4: Write `expense_dao.dart`**

```dart
// `expenses` + `split_entries` rows <-> Expense/SplitEntry.
import '../../models.dart';
import '../database.dart';

class ExpenseDao {
  ExpenseDao(this._db);

  final SplitcoreDb _db;

  /// Replaces [groupId]'s expenses with [expenses], and each expense's split
  /// entries with [splitsByExpenseId]'s. Wholesale rather than a diff: the
  /// server's set is authoritative, and a deleted expense that lingers
  /// locally would keep counting toward balances the user can see.
  ///
  /// The delete cascades to split_entries (see schema.dart), so entries for
  /// a dropped expense go with it.
  void replaceGroupExpenses(
    String groupId,
    List<Expense> expenses,
    Map<String, List<SplitEntry>> splitsByExpenseId,
  ) {
    _db.raw.execute('DELETE FROM expenses WHERE group_id = ?', [groupId]);

    final expenseStatement = _db.raw.prepare('''
      INSERT INTO expenses
        (id, group_id, payer_member_id, description, amount_cents, split_type, date, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    final entryStatement = _db.raw.prepare('''
      INSERT INTO split_entries (id, expense_id, member_id, amount_cents, receipt_filename)
      VALUES (?, ?, ?, ?, ?)
    ''');
    try {
      for (final e in expenses) {
        expenseStatement.execute([
          e.id,
          e.groupId,
          e.payerMemberId,
          e.description,
          e.amountCents,
          e.splitType,
          e.date.toUtc().toIso8601String(),
          null,
        ]);
        for (final s in splitsByExpenseId[e.id] ?? const <SplitEntry>[]) {
          entryStatement.execute([s.id, s.expenseId, s.memberId, s.amountCents, s.receiptFilename]);
        }
      }
    } finally {
      expenseStatement.dispose();
      entryStatement.dispose();
    }
  }

  /// Newest first, matching the group-detail list. [query] filters on
  /// description, case-insensitively; empty means no filter.
  List<Expense> listExpenses(String groupId, {String query = ''}) {
    final rows = query.isEmpty
        ? _db.raw.select(
            'SELECT * FROM expenses WHERE group_id = ? ORDER BY date DESC, id DESC',
            [groupId],
          )
        : _db.raw.select(
            'SELECT * FROM expenses WHERE group_id = ? AND description LIKE ? ESCAPE \'\\\' '
            'ORDER BY date DESC, id DESC',
            [groupId, '%${_escapeLike(query)}%'],
          );
    return rows
        .map(
          (r) => Expense(
            id: r['id'] as String,
            groupId: r['group_id'] as String,
            payerMemberId: r['payer_member_id'] as String,
            description: r['description'] as String,
            amountCents: r['amount_cents'] as int,
            splitType: r['split_type'] as String,
            date: DateTime.parse(r['date'] as String),
          ),
        )
        .toList();
  }

  // Without this, a user searching for "50%" gets every expense: % and _ are
  // LIKE wildcards.
  String _escapeLike(String input) =>
      input.replaceAll('\\', '\\\\').replaceAll('%', '\\%').replaceAll('_', '\\_');

  List<SplitEntry> listSplitEntries(String expenseId) => _db.raw
      .select('SELECT * FROM split_entries WHERE expense_id = ? ORDER BY id', [expenseId])
      .map(
        (r) => SplitEntry(
          id: r['id'] as String,
          expenseId: r['expense_id'] as String,
          memberId: r['member_id'] as String,
          amountCents: r['amount_cents'] as int,
          receiptFilename: r['receipt_filename'] as String?,
        ),
      )
      .toList();
}
```

- [ ] **Step 5: Write `settlement_dao.dart`**

```dart
// `settlements` rows <-> Settlement.
import '../../models.dart';
import '../database.dart';

class SettlementDao {
  SettlementDao(this._db);

  final SplitcoreDb _db;

  void replaceGroupSettlements(String groupId, List<Settlement> settlements) {
    _db.raw.execute('DELETE FROM settlements WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare('''
      INSERT INTO settlements
        (id, group_id, from_member_id, to_member_id, amount_cents, date, note, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    try {
      for (final s in settlements) {
        statement.execute([
          s.id,
          s.groupId,
          s.fromMemberId,
          s.toMemberId,
          s.amountCents,
          s.date.toUtc().toIso8601String(),
          s.note,
          null,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<Settlement> listSettlements(String groupId) => _db.raw
      .select('SELECT * FROM settlements WHERE group_id = ? ORDER BY date DESC, id DESC', [groupId])
      .map(
        (r) => Settlement(
          id: r['id'] as String,
          groupId: r['group_id'] as String,
          fromMemberId: r['from_member_id'] as String,
          toMemberId: r['to_member_id'] as String,
          amountCents: r['amount_cents'] as int,
          date: DateTime.parse(r['date'] as String),
          note: r['note'] as String,
        ),
      )
      .toList();
}
```

- [ ] **Step 6: Write `balance_dao.dart`**

```dart
// `balances` rows <-> Balance.
//
// Balances are derived, never client-authored: the server rewrites them on
// every mutation (server/hooks/recompute.go), so a pull replaces the whole
// group's set rather than merging. Merging would let a member who dropped
// to zero keep a stale non-zero row forever.
import '../../models.dart';
import '../database.dart';

class BalanceDao {
  BalanceDao(this._db);

  final SplitcoreDb _db;

  void replaceGroupBalances(String groupId, List<Balance> balances) {
    _db.raw.execute('DELETE FROM balances WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare(
      'INSERT INTO balances (group_id, member_id, net_cents) VALUES (?, ?, ?)',
    );
    try {
      for (final b in balances) {
        statement.execute([groupId, b.memberId, b.netCents]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<Balance> listBalances(String groupId) => _db.raw
      .select('SELECT * FROM balances WHERE group_id = ? ORDER BY member_id', [groupId])
      .map((r) => Balance(memberId: r['member_id'] as String, netCents: r['net_cents'] as int))
      .toList();
}
```

- [ ] **Step 7: Write `sync_state_dao.dart`**

```dart
// The per-group pull cursor. `version` is the server's group version as of
// the last successful pull — the value handed to /api/splitcore/staleness
// to ask "did anything change?" in O(1).
import '../database.dart';

class SyncStateDao {
  SyncStateDao(this._db);

  final SplitcoreDb _db;

  /// 0 for a group never synced, which is deliberately lower than any real
  /// server version — the first staleness check then always reports stale
  /// and pulls.
  int versionOf(String groupId) {
    final rows = _db.raw.select('SELECT version FROM sync_state WHERE group_id = ?', [groupId]);
    return rows.isEmpty ? 0 : rows.first['version'] as int;
  }

  DateTime? syncedAt(String groupId) {
    final rows = _db.raw.select('SELECT synced_at FROM sync_state WHERE group_id = ?', [groupId]);
    if (rows.isEmpty) return null;
    final raw = rows.first['synced_at'] as String?;
    return raw == null ? null : DateTime.parse(raw);
  }

  void markSynced(String groupId, int version) {
    _db.raw.execute(
      '''
      INSERT INTO sync_state (group_id, version, synced_at) VALUES (?, ?, ?)
      ON CONFLICT(group_id) DO UPDATE SET version = excluded.version, synced_at = excluded.synced_at
      ''',
      [groupId, version, DateTime.now().toUtc().toIso8601String()],
    );
  }
}
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `cd splitcore_sdk && dart test test/local/`
Expected: PASS, 22 tests.

- [ ] **Step 9: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/lib/src/local/dao/ splitcore_sdk/test/local/dao_test.dart
git commit -m "feat(sdk): local DAOs for groups, expenses, settlements and balances"
```

---

### Task 5: Connectivity, persistent tokens, and the offline-signout fix

**Files:**
- Create: `splitcore_sdk/lib/src/sync/connectivity.dart`
- Modify: `splitcore_sdk/lib/src/remote/token_store.dart`
- Modify: `splitcore_sdk/lib/src/remote/auth_api.dart:142-150`
- Test: `splitcore_sdk/test/sync/connectivity_test.dart`
- Test: `splitcore_sdk/test/token_store_test.dart` (exists — extend it)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `abstract class ConnectivityMonitor { Stream<bool> get onStatusChange; Future<bool> isOnline(); }`
  - `AlwaysOnline implements ConnectivityMonitor`
  - `FakeConnectivityMonitor` (in `lib/src/sync/connectivity.dart`, exported for app and SDK tests): `goOnline()`, `goOffline()`.
  - `FileTokenStore implements TokenStore`: `FileTokenStore.at(String path)`.

- [ ] **Step 1: Write the failing connectivity test**

Create `splitcore_sdk/test/sync/connectivity_test.dart`:

```dart
import 'package:splitcore_sdk/src/sync/connectivity.dart';
import 'package:test/test.dart';

void main() {
  test('AlwaysOnline reports online and never transitions', () async {
    final monitor = AlwaysOnline();
    expect(await monitor.isOnline(), isTrue);
    expect(await monitor.onStatusChange.isEmpty, isTrue);
  });

  test('the fake monitor reports and emits transitions', () async {
    final monitor = FakeConnectivityMonitor(online: false);
    addTearDown(monitor.dispose);

    final seen = <bool>[];
    final sub = monitor.onStatusChange.listen(seen.add);
    addTearDown(sub.cancel);

    expect(await monitor.isOnline(), isFalse);

    monitor.goOnline();
    await Future<void>.delayed(Duration.zero);
    expect(await monitor.isOnline(), isTrue);

    monitor.goOffline();
    await Future<void>.delayed(Duration.zero);

    expect(seen, [true, false]);
  });

  test('a repeated status does not emit — only transitions matter', () async {
    final monitor = FakeConnectivityMonitor(online: true);
    addTearDown(monitor.dispose);

    final seen = <bool>[];
    final sub = monitor.onStatusChange.listen(seen.add);
    addTearDown(sub.cancel);

    monitor.goOnline();
    monitor.goOnline();
    await Future<void>.delayed(Duration.zero);

    expect(seen, isEmpty);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/sync/connectivity_test.dart`
Expected: FAIL — `package:splitcore_sdk/src/sync/connectivity.dart` does not exist.

- [ ] **Step 3: Write `connectivity.dart`**

```dart
// How the SDK learns that the network came back, without depending on
// Flutter. Every real implementation of this lives outside the package:
// the app wraps connectivity_plus, a CLI could poll a socket. The SDK only
// needs the transition.
import 'dart:async';

abstract class ConnectivityMonitor {
  /// Emits on every *transition*. A repeated status must not emit — the
  /// sync engine treats each event as "the network just came back" and
  /// would otherwise re-sync on every duplicate notification the platform
  /// decides to send.
  Stream<bool> get onStatusChange;

  Future<bool> isOnline();
}

/// The default when the caller supplies nothing: assume a connection and
/// let requests fail normally. Behaviourally identical to the SDK before
/// offline support existed.
class AlwaysOnline implements ConnectivityMonitor {
  @override
  Stream<bool> get onStatusChange => const Stream.empty();

  @override
  Future<bool> isOnline() async => true;
}

/// Drives connectivity by hand. Exported rather than kept in `test/` so the
/// app can use it in widget tests too — a sync engine that sleeps on a real
/// clock is a flaky test generator.
class FakeConnectivityMonitor implements ConnectivityMonitor {
  FakeConnectivityMonitor({bool online = true}) : _online = online;

  bool _online;
  final _controller = StreamController<bool>.broadcast();

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  @override
  Future<bool> isOnline() async => _online;

  void goOnline() => _set(true);

  void goOffline() => _set(false);

  void _set(bool value) {
    if (_online == value) return;
    _online = value;
    _controller.add(value);
  }

  Future<void> dispose() => _controller.close();
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `cd splitcore_sdk && dart test test/sync/connectivity_test.dart`
Expected: PASS, 3 tests.

- [ ] **Step 5: Write the failing `FileTokenStore` test**

Append to `splitcore_sdk/test/token_store_test.dart`:

```dart
  group('FileTokenStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('splitcore_tokens'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('reads back what it wrote, across instances', () async {
      final path = '${dir.path}/auth.json';
      await FileTokenStore.at(path).write('{"token":"abc"}');

      expect(FileTokenStore.at(path).read(), '{"token":"abc"}');
    });

    test('a first launch reads null rather than throwing', () {
      expect(FileTokenStore.at('${dir.path}/missing.json').read(), isNull);
    });

    test('an unreadable file reads null instead of blocking startup', () {
      final path = '${dir.path}/dir-not-a-file';
      Directory(path).createSync();

      expect(FileTokenStore.at(path).read(), isNull);
    });
  });
```

Add `import 'dart:io';` to that file's imports if it is not already there.

- [ ] **Step 6: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/token_store_test.dart`
Expected: FAIL — `Undefined name 'FileTokenStore'`.

- [ ] **Step 7: Add `FileTokenStore` to `token_store.dart`**

Append to `splitcore_sdk/lib/src/remote/token_store.dart`, and add `import 'dart:io';` at the top:

```dart
/// A [TokenStore] backed by a plain file, so persistence works with no app
/// wiring at all. The app is still free to supply its own (the Flutter app
/// uses shared_preferences); this exists so the SDK is not useless out of
/// the box on desktop and in scripts.
///
/// The file holds a bearer token. It is written with owner-only permissions
/// where the platform supports it; on platforms that do not, the containing
/// directory is the security boundary — put it somewhere private.
class FileTokenStore implements TokenStore {
  FileTokenStore.at(String path) : _file = File(path);

  final File _file;

  @override
  String? read() {
    try {
      return _file.existsSync() ? _file.readAsStringSync() : null;
    } catch (_) {
      // A corrupt or unreadable token file means "not signed in", never a
      // crash on launch — the user can sign in again, but they cannot get
      // past a startup exception.
      return null;
    }
  }

  @override
  Future<void> write(String data) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(data, flush: true);
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', _file.path]);
    }
  }
}
```

- [ ] **Step 8: Write the failing test for the offline-signout bug**

Append to `splitcore_sdk/test/auth_refresh_test.dart`:

```dart
  test('a network failure during refresh keeps the session', () async {
    // Point the SDK at a port nothing is listening on: authRefresh fails
    // with a SocketException, exactly like launching on a train.
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: 'http://127.0.0.1:1',
      libraryPath: libraryPath,
      tokenStore: _MemoryTokenStore(seeded: validAuthPayload),
    );

    expect(await sdk.auth.tryRefresh(), isNull, reason: 'refresh could not confirm the session');
    expect(
      sdk.auth.isSignedIn,
      isTrue,
      reason: 'a network failure must not sign the user out — the stored token is still valid',
    );
  });
```

Read the existing `auth_refresh_test.dart` first and reuse whatever helper it already has for a seeded token store and `libraryPath`; do not add a second one. If the file has no `isSignedIn` assertion helper, this task adds the getter in Step 9.

- [ ] **Step 9: Fix `_refresh()` and add `isSignedIn`**

In `splitcore_sdk/lib/src/remote/auth_api.dart`, replace `_refresh()` (lines 142-150):

```dart
  Future<AppUser?> _refresh() async {
    try {
      final auth = await _pb.collection('users').authRefresh();
      return _userFromRecord(auth.record);
    } on ClientException catch (e) {
      // Only an actual rejection means the session is dead. A network
      // failure is indistinguishable from an expired token at the call
      // site, and treating it as one signed the user out every time the
      // app launched offline — which is precisely when they need the
      // cached session most. Keep it; the sync engine retries when
      // connectivity returns.
      if (e.statusCode == 401 || e.statusCode == 403) {
        _pb.authStore.clear();
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Whether a session is stored. Answerable offline, without a request —
  /// the stored token is the best available evidence of who is signed in.
  bool get isSignedIn => _pb.authStore.isValid;
```

- [ ] **Step 10: Run the auth and token tests**

Run: `cd splitcore_sdk && dart test test/token_store_test.dart test/remote/auth_refresh_test.dart`
Expected: PASS. If `auth_refresh_test.dart` lives at a different path, use the path from `find splitcore_sdk/test -name 'auth_refresh_test.dart'`.

- [ ] **Step 11: Export the new types**

In `splitcore_sdk/lib/splitcore_sdk.dart`, add (keeping the export list alphabetical):

```dart
export 'src/remote/token_store.dart' show FileTokenStore, TokenStore;
export 'src/sync/connectivity.dart' show AlwaysOnline, ConnectivityMonitor, FakeConnectivityMonitor;
```

- [ ] **Step 12: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/lib splitcore_sdk/test
git commit -m "fix(sdk): keep the session on a network error, add FileTokenStore and ConnectivityMonitor"
```

---

### Task 6: The pull sync engine and reactive repositories

**Files:**
- Create: `splitcore_sdk/lib/src/sync/events.dart`
- Create: `splitcore_sdk/lib/src/sync/sync_engine.dart`
- Create: `splitcore_sdk/lib/src/repo/groups_repository.dart`
- Create: `splitcore_sdk/lib/src/repo/expenses_repository.dart`
- Create: `splitcore_sdk/lib/src/repo/settlements_repository.dart`
- Create: `splitcore_sdk/lib/src/repo/balances_repository.dart`
- Modify: `splitcore_sdk/lib/src/sdk.dart`
- Modify: `splitcore_sdk/lib/splitcore_sdk.dart`
- Delete: `splitcore_sdk/lib/src/remote/local_store.dart`
- Test: `splitcore_sdk/test/sync/sync_engine_test.dart`

**Interfaces:**
- Consumes: every DAO (Task 4), `ConnectivityMonitor` (Task 5), `SplitcoreDb.watch` (Task 2), the existing `GroupsApi`, `ExpensesApi`, `SettlementsApi`, `BalancesApi`, and `checkStaleness` from `remote/staleness_api.dart`.
- Produces:
  - `sealed class SyncEvent` with `SyncStarted`, `SyncCompleted(int groupsPulled)`, `SyncFailed(Object error)`.
  - `SyncEngine`: `Stream<SyncEvent> get events`, `Future<void> now()`, `void start()`, `Future<void> dispose()`.
  - `GroupsRepository`: `Stream<List<Group>> watchGroups()`, `Stream<List<GroupMember>> watchMembers(String groupId)`, plus pass-throughs `createGroup`, `addMember`, `removeMember`, `inviteOrAddMember` with the same signatures as `GroupsApi`'s.
  - `ExpensesRepository`: `Stream<List<Expense>> watch(String groupId, {String query = ''})`, `Stream<List<SplitEntry>> watchSplitEntries(String expenseId)`, plus pass-throughs `createExpense`, `updateExpense`, `deleteExpense`.
  - `SettlementsRepository`: `Stream<List<Settlement>> watch(String groupId)`, plus pass-throughs.
  - `BalancesRepository`: `Stream<List<Balance>> watch(String groupId)`.

Writes are pass-throughs in Phase 1: they call the remote API and then ask the engine to pull the affected group, so the local DB catches up. Phase 2 replaces them with local commit + outbox.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/sync/sync_engine_test.dart`. It uses the real server, because the whole point is wire behavior:

```dart
import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async => server = await PbTestServer.start());
  tearDownAll(() async => server.stop());

  Future<SplitcoreSdk> signedInSdk(FakeConnectivityMonitor connectivity) async {
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.url,
      libraryPath: libraryPath,
      connectivity: connectivity,
    );
    await sdk.auth.signUp(
      email: 'sync-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    return sdk;
  }

  test('a group created on the server lands in the local DB after a pull', () async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();

    final groups = await sdk.groups.watchGroups().first;
    expect(groups.map((g) => g.name), ['Trip']);
  });

  test('watchGroups re-emits when a pull writes, without being re-subscribed', () async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    final emissions = <List<Group>>[];
    final sub = sdk.groups.watchGroups().listen(emissions.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emissions.single, isEmpty, reason: 'the first emission is the empty local DB');

    await sdk.groups.createGroup(name: 'Flat', currency: 'EUR');
    await sdk.sync.now();
    await Future<void>.delayed(Duration.zero);

    expect(emissions.last.map((g) => g.name), ['Flat']);
  });

  test('coming back online triggers a pull with no manual call', () async {
    final connectivity = FakeConnectivityMonitor(online: false);
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    await sdk.groups.createGroup(name: 'Ski', currency: 'CHF');

    final completed = sdk.sync.events.firstWhere((e) => e is SyncCompleted);
    connectivity.goOnline();
    await completed;

    expect((await sdk.groups.watchGroups().first).map((g) => g.name), ['Ski']);
  });

  test('a second pull with an unchanged version does not refetch the group', () async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();

    final second = await sdk.sync.events
        .where((e) => e is SyncCompleted)
        .cast<SyncCompleted>()
        .first
        .timeout(const Duration(seconds: 10), onTimeout: () => const SyncCompleted(-1));

    await sdk.sync.now();
    expect(second.groupsPulled, isNot(-1));
  });

  test('expenses survive a restart: a new SDK on the same file reads them offline', () async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    final members = await sdk.groups.listMembers(group.id);
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: members.first.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [members.first.id]),
    );
    await sdk.sync.now();

    final expenses = await sdk.expenses.watch(group.id).first;
    expect(expenses.map((e) => e.description), ['Dinner']);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/sync/sync_engine_test.dart`
Expected: FAIL — `SplitcoreSdk.initialize` has no `connectivity` parameter and `sdk.sync` does not exist.

- [ ] **Step 3: Write `events.dart`**

```dart
// What the app can observe about syncing. Deliberately small in Phase 1:
// conflicts and per-op failures arrive with the outbox in Phase 2.
sealed class SyncEvent {
  const SyncEvent();
}

class SyncStarted extends SyncEvent {
  const SyncStarted();
}

class SyncCompleted extends SyncEvent {
  const SyncCompleted(this.groupsPulled);

  /// How many groups were actually stale and refetched. 0 means the
  /// staleness check found everything current — the common case, and the
  /// reason this is a cheap operation to run on every reconnect.
  final int groupsPulled;
}

class SyncFailed extends SyncEvent {
  const SyncFailed(this.error);

  final Object error;
}
```

- [ ] **Step 4: Write `sync_engine.dart`**

```dart
// The dbListener: it wakes on events, never on a schedule.
//
// Wake sources in Phase 1 are a connectivity transition to online and an
// explicit now(). Phase 2 adds an outbox insert; Phase 3 adds PocketBase's
// SSE stream. All four funnel into the same _run(), so there is one pull
// path to reason about regardless of what woke it.
//
// The single timer in this file is post-failure backoff. It is armed only
// after a failed run and cancelled the moment anything else wakes the
// engine, so the steady state is genuinely event-driven.
import 'dart:async';

import '../local/dao/balance_dao.dart';
import '../local/dao/expense_dao.dart';
import '../local/dao/group_dao.dart';
import '../local/dao/settlement_dao.dart';
import '../local/dao/sync_state_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/balances_api.dart';
import '../remote/expenses_api.dart';
import '../remote/groups_api.dart';
import '../remote/settlements_api.dart';
import '../remote/staleness_api.dart';
import 'connectivity.dart';
import 'events.dart';

class SyncEngine {
  SyncEngine({
    required SplitcoreDb db,
    required ConnectivityMonitor connectivity,
    required GroupsApi groups,
    required ExpensesApi expenses,
    required SettlementsApi settlements,
    required BalancesApi balances,
    required Future<StalenessResult> Function(String groupId, int localVersion) staleness,
  }) : _db = db,
       _connectivity = connectivity,
       _groups = groups,
       _expenses = expenses,
       _settlements = settlements,
       _balances = balances,
       _staleness = staleness;

  final SplitcoreDb _db;
  final ConnectivityMonitor _connectivity;
  final GroupsApi _groups;
  final ExpensesApi _expenses;
  final SettlementsApi _settlements;
  final BalancesApi _balances;
  final Future<StalenessResult> Function(String, int) _staleness;

  final _events = StreamController<SyncEvent>.broadcast();
  StreamSubscription<bool>? _connectivitySub;
  Timer? _backoff;
  Future<void>? _inFlight;
  int _consecutiveFailures = 0;

  static const _maxBackoff = Duration(minutes: 5);

  Stream<SyncEvent> get events => _events.stream;

  /// Begins listening for wake-ups. Not called from the constructor so a
  /// test can construct the engine and drive it by hand.
  void start() {
    _connectivitySub = _connectivity.onStatusChange.listen((online) {
      if (!online) return;
      _cancelBackoff();
      unawaited(now());
    });
  }

  /// Runs a pull, or joins the one already running. Concurrent callers must
  /// not each start their own: two pulls interleaving their writes would
  /// deadlock on SQLite's single writer.
  Future<void> now() => _inFlight ??= _run().whenComplete(() => _inFlight = null);

  Future<void> _run() async {
    if (!await _connectivity.isOnline()) return;

    _events.add(const SyncStarted());
    try {
      final pulled = await _pull();
      _consecutiveFailures = 0;
      _cancelBackoff();
      _events.add(SyncCompleted(pulled));
    } catch (e) {
      _events.add(SyncFailed(e));
      _armBackoff();
    }
  }

  Future<int> _pull() async {
    final remoteGroups = await _groups.listMyGroups();

    _db.transaction({'groups'}, () {
      final dao = GroupDao(_db);
      dao.upsertGroups(remoteGroups);
      dao.deleteGroupsMissingFrom({for (final g in remoteGroups) g.id});
    });

    var pulled = 0;
    for (final group in remoteGroups) {
      // O(1) metadata check. Skipping a current group is the whole reason
      // a reconnect is cheap even with a long history.
      final local = SyncStateDao(_db).versionOf(group.id);
      final state = await _staleness(group.id, local);
      if (state.current) continue;

      await _pullGroup(group, state.serverVersion);
      pulled++;
    }
    return pulled;
  }

  Future<void> _pullGroup(Group group, int serverVersion) async {
    final members = await _groups.listMembers(group.id);
    final expenses = await _expenses.listAllExpenses(group.id);
    final splits = <String, List<SplitEntry>>{};
    for (final e in expenses) {
      splits[e.id] = await _expenses.listSplitEntries(e.id);
    }
    final settlements = await _settlements.listAllSettlements(group.id);
    final balances = await _balances.getBalances(group.id);

    // One commit: a screen must never observe new expenses against old
    // balances, which is exactly the "my numbers don't add up" bug report.
    _db.transaction({'members', 'expenses', 'split_entries', 'settlements', 'balances',
        'sync_state'}, () {
      GroupDao(_db).upsertMembers(group.id, members);
      ExpenseDao(_db).replaceGroupExpenses(group.id, expenses, splits);
      SettlementDao(_db).replaceGroupSettlements(group.id, settlements);
      BalanceDao(_db).replaceGroupBalances(group.id, balances);
      SyncStateDao(_db).markSynced(group.id, serverVersion);
    });
  }

  void _armBackoff() {
    _consecutiveFailures++;
    final seconds = 1 << (_consecutiveFailures.clamp(1, 9) - 1);
    final delay = Duration(seconds: seconds) < _maxBackoff
        ? Duration(seconds: seconds)
        : _maxBackoff;
    _backoff?.cancel();
    _backoff = Timer(delay, () => unawaited(now()));
  }

  void _cancelBackoff() {
    _backoff?.cancel();
    _backoff = null;
  }

  Future<void> dispose() async {
    _cancelBackoff();
    await _connectivitySub?.cancel();
    await _events.close();
  }
}
```

**Note for the implementer:** `ExpensesApi` currently exposes paged listing, not `listAllExpenses`/`listSplitEntries`, and `SettlementsApi` has no `listAllSettlements`. Read both files and add the exhaustive variants next to the paged ones, using `getFullList(batch: 200, filter: byGroup(...))` — the paged API stays for the UI, the exhaustive one is for sync. Do not delete the paged methods.

- [ ] **Step 5: Write the four repositories**

`splitcore_sdk/lib/src/repo/groups_repository.dart`:

```dart
// The public read path for groups: local rows, re-emitted when sync writes.
// Writes still go straight to the server in Phase 1 and then ask the engine
// to pull, so the local DB catches up; Phase 2 makes them local-first.
import '../local/dao/group_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/groups_api.dart';
import '../sync/sync_engine.dart';

class GroupsRepository {
  GroupsRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final GroupsApi _api;
  final SyncEngine _sync;

  Stream<List<Group>> watchGroups() => _db.watch({'groups'}, () => GroupDao(_db).listGroups());

  Stream<List<GroupMember>> watchMembers(String groupId) =>
      _db.watch({'members'}, () => GroupDao(_db).listMembers(groupId));

  /// The current member list, for callers that need one value rather than a
  /// subscription (the export path, and tests).
  Future<List<GroupMember>> listMembers(String groupId) async => GroupDao(_db).listMembers(groupId);

  Future<Group> createGroup({
    required String name,
    required String currency,
    bool isDirect = false,
  }) async {
    final group = await _api.createGroup(name: name, currency: currency, isDirect: isDirect);
    await _sync.now();
    return group;
  }

  Future<GroupMember> addMember({
    required String groupId,
    required String userId,
    required String role,
  }) async {
    final member = await _api.addMember(groupId: groupId, userId: userId, role: role);
    await _sync.now();
    return member;
  }

  Future<void> removeMember(String memberId) async {
    await _api.removeMember(memberId);
    await _sync.now();
  }

  Future<bool> inviteOrAddMember({
    required String groupId,
    required String email,
    String role = 'member',
  }) async {
    final added = await _api.inviteOrAddMember(groupId: groupId, email: email, role: role);
    await _sync.now();
    return added;
  }
}
```

`splitcore_sdk/lib/src/repo/expenses_repository.dart`:

```dart
import '../local/dao/expense_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/expenses_api.dart';
import '../sync/sync_engine.dart';

class ExpensesRepository {
  ExpensesRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final ExpensesApi _api;
  final SyncEngine _sync;

  /// Newest first. [query] filters on description — the group search box.
  Stream<List<Expense>> watch(String groupId, {String query = ''}) =>
      _db.watch({'expenses'}, () => ExpenseDao(_db).listExpenses(groupId, query: query));

  Stream<List<SplitEntry>> watchSplitEntries(String expenseId) =>
      _db.watch({'split_entries'}, () => ExpenseDao(_db).listSplitEntries(expenseId));

  Future<Expense> createExpense({
    required String groupId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final expense = await _api.createExpense(
      groupId: groupId,
      payerMemberId: payerMemberId,
      description: description,
      date: date,
      split: split,
    );
    await _sync.now();
    return expense;
  }

  Future<Expense> updateExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final expense = await _api.updateExpense(
      expenseId: expenseId,
      payerMemberId: payerMemberId,
      description: description,
      date: date,
      split: split,
    );
    await _sync.now();
    return expense;
  }

  Future<void> deleteExpense(String expenseId) async {
    await _api.deleteExpense(expenseId);
    await _sync.now();
  }
}
```

**Note for the implementer:** match `deleteExpense`'s real name and signature to what `ExpensesApi` already exposes; read the file rather than assuming. Same for receipt methods — carry every existing public method through as a pass-through so no capability is lost.

`splitcore_sdk/lib/src/repo/settlements_repository.dart` and `balances_repository.dart` follow the identical shape: a `watch` built on `_db.watch` plus a DAO, and a pass-through for every write `SettlementsApi` exposes. `BalancesRepository` has no writes — balances are server-derived:

```dart
import '../local/dao/balance_dao.dart';
import '../local/database.dart';
import '../models.dart';

class BalancesRepository {
  BalancesRepository(this._db);

  final SplitcoreDb _db;

  Stream<List<Balance>> watch(String groupId) =>
      _db.watch({'balances'}, () => BalanceDao(_db).listBalances(groupId));
}
```

- [ ] **Step 6: Rewire `sdk.dart`**

Replace the `initialize` factory and fields so the SDK owns the database, the engine and the repositories. `groups`, `expenses`, `settlements` and `balances` change type from the `*Api` classes to the `*Repository` classes. Delete the `LocalStore` import and its construction; `SettlementsApi`'s `LocalStore` argument is replaced by `BalanceDao`.

```dart
  factory SplitcoreSdk.initialize({
    required String pocketbaseUrl,
    required String libraryPath,
    String? databasePath,
    TokenStore? tokenStore,
    ConnectivityMonitor? connectivity,
  }) {
    final pb = PocketBase(
      pocketbaseUrl,
      authStore: tokenStore == null ? null : asAuthStore(tokenStore),
      httpClientFactory: () => _TimeoutClient(http.Client(), const Duration(seconds: 15)),
    );
    final calc = SplitcoreCalc.open(libraryPath);
    // No path means an ephemeral database: the SDK still works local-first
    // for the life of the process, it just does not survive a restart.
    final db = databasePath == null ? SplitcoreDb.inMemory() : SplitcoreDb.openAt(databasePath);
    final monitor = connectivity ?? AlwaysOnline();

    final groupsApi = GroupsApi(pb);
    final expensesApi = ExpensesApi(pb, calc);
    final settlementsApi = SettlementsApi(pb, calc, BalanceDao(db));
    final balancesApi = BalancesApi(pb);

    final sync = SyncEngine(
      db: db,
      connectivity: monitor,
      groups: groupsApi,
      expenses: expensesApi,
      settlements: settlementsApi,
      balances: balancesApi,
      staleness: (groupId, localVersion) =>
          checkStaleness(pb, groupId: groupId, localVersion: localVersion),
    )..start();

    return SplitcoreSdk._(
      AuthApi(pb),
      GroupsRepository(db, groupsApi, sync),
      ExpensesRepository(db, expensesApi, sync),
      SettlementsRepository(db, settlementsApi, sync),
      BalancesRepository(db),
      ExportApi(groupsApi, expensesApi, settlementsApi),
      calc,
      db,
      sync,
    );
  }
```

Add a `close()` so a test (and the app on sign-out) can release the file handle and the subscriptions:

```dart
  /// Releases the database handle and stops the sync engine. The SDK is
  /// unusable afterwards.
  Future<void> close() async {
    await sync.dispose();
    await _db.close();
  }
```

**Note for the implementer:** `SettlementsApi`'s constructor takes a `LocalStore` today and uses it for the staleness-triggered resync. Read `settlements_api.dart` and replace that dependency with `BalanceDao`, keeping the behavior identical — the snapshot it caches is a group version plus balances, which `BalanceDao` plus `SyncStateDao` already hold.

- [ ] **Step 7: Delete the superseded in-memory store**

```bash
git rm splitcore_sdk/lib/src/remote/local_store.dart
```

Remove its import from `sdk.dart` and `settlements_api.dart`. If `test/` references `LocalStore` or `GroupSnapshot`, update those tests to use `BalanceDao` and `SyncStateDao` instead of deleting them — they cover real resync behavior.

- [ ] **Step 8: Export the new public types**

In `splitcore_sdk/lib/splitcore_sdk.dart`, replace the `*_api.dart` exports for groups/expenses/settlements/balances with the repositories, and add the sync types:

```dart
export 'src/repo/balances_repository.dart' show BalancesRepository;
export 'src/repo/expenses_repository.dart' show ExpensesRepository;
export 'src/repo/groups_repository.dart' show GroupsRepository;
export 'src/repo/settlements_repository.dart' show SettlementsRepository;
export 'src/sync/events.dart' show SyncCompleted, SyncEvent, SyncFailed, SyncStarted;
export 'src/sync/sync_engine.dart' show SyncEngine;
```

Keep `export 'src/remote/auth_api.dart' show AuthApi;` and `export 'src/remote/export_api.dart' show ExportApi;` — those two are not repository-backed.

- [ ] **Step 9: Run the whole SDK suite**

Run: `cd splitcore_sdk && dart test`
Expected: PASS. Fix any existing test that constructed `SplitcoreSdk` positionally or reached for a removed `*Api` type.

- [ ] **Step 10: Format, analyze, commit**

```bash
cd splitcore_sdk && dart format --line-length 100 . && dart analyze --fatal-infos
cd .. && git add splitcore_sdk/
git commit -m "feat(sdk): event-driven pull sync and local-first reactive reads"
```

---

### Task 7: Wire the app to the local database

**Files:**
- Modify: `app/pubspec.yaml`
- Modify: `app/lib/main.dart`
- Create: `app/lib/connectivity.dart`
- Delete: `app/lib/offline_cache.dart`
- Modify: every screen under `app/lib/screens/` that reads through `Loadable`
- Test: `app/test/` (existing widget tests must keep passing)

**Interfaces:**
- Consumes: `sdk.groups.watchGroups()`, `sdk.expenses.watch()`, `sdk.balances.watch()`, `ConnectivityMonitor` (Tasks 5-6).
- Produces: `ConnectivityPlusMonitor implements ConnectivityMonitor`.

- [ ] **Step 1: Add the app-side dependencies**

In `app/pubspec.yaml`, under `dependencies:`:

```yaml
  connectivity_plus: ^6.1.0
  path_provider: ^2.1.4
  sqlite3_flutter_libs: ^0.5.24
```

`sqlite3_flutter_libs` has no Dart API — it exists purely to bundle `libsqlite3.so` into the Android and iOS builds, the same way `jniLibs` bundles `libsplitcore.so`. Desktop uses the system library.

Run: `cd app && flutter pub get`

- [ ] **Step 2: Write the connectivity adapter**

Create `app/lib/connectivity.dart`:

```dart
// Adapts connectivity_plus to the SDK's ConnectivityMonitor. This lives in
// the app, not the SDK, because connectivity_plus is a Flutter plugin and
// splitcore_sdk is pure Dart.
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

class ConnectivityPlusMonitor implements ConnectivityMonitor {
  ConnectivityPlusMonitor() {
    _connectivity.onConnectivityChanged.listen((results) {
      final online = _isOnline(results);
      // Only transitions: Android emits duplicate events freely, and the
      // sync engine reads every event as "the network just came back".
      if (online == _last) return;
      _last = online;
      _controller.add(online);
    });
  }

  final _connectivity = Connectivity();
  final _controller = StreamController<bool>.broadcast();
  bool? _last;

  @override
  Stream<bool> get onStatusChange => _controller.stream;

  @override
  Future<bool> isOnline() async => _isOnline(await _connectivity.checkConnectivity());

  // "Has an interface" is not "can reach the server" — a captive portal
  // passes this check. That is fine: the sync engine's own request failure
  // is the real test, and this only decides when to bother trying.
  bool _isOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}
```

Add `import 'dart:async';` at the top.

- [ ] **Step 3: Wire `main.dart`**

In `app/lib/main.dart`, where the SDK is constructed, pass the database path and the monitor:

```dart
  final dir = await getApplicationSupportDirectory();
  final sdk = SplitcoreSdk.initialize(
    pocketbaseUrl: pocketbaseUrl,
    libraryPath: _libraryPath(),
    databasePath: '${dir.path}/splitcore.db',
    tokenStore: _PrefsTokenStore(prefs),
    connectivity: ConnectivityPlusMonitor(),
  );
```

Add `import 'package:path_provider/path_provider.dart';` and `import 'connectivity.dart';`.

- [ ] **Step 4: Migrate the screens to streams**

For each screen that reads through `Loadable`, replace the `Future`-returning load with the matching `watch*` stream and a `StreamBuilder`. `app/lib/loadable.dart` already models idle/loading/value/error — keep it and feed it from the stream, rather than rewriting every screen's state handling:

```dart
// in the screen's initState
_sub = widget.sdk.expenses.watch(widget.groupId).listen(
  _expenses.setValue,
  onError: _expenses.setError,
);
```

Do this one screen at a time, running `flutter test` after each. The screens to change: `home.dart` (groups), `group_detail.dart` (expenses, balances, members), `activity.dart`, `settle_up.dart`.

- [ ] **Step 5: Delete the superseded cache**

```bash
git rm app/lib/offline_cache.dart
```

Remove every import of it and the "showing data from ..." plumbing that read `lastUpdated`. Replace that banner's data source with the SDK: the local DB is now always the source, so the banner should show sync state instead — drive it from `sdk.sync.events`.

- [ ] **Step 6: Run the full check**

Run: `make check`
Expected: PASS — gofmt, go vet, Dart/Flutter analysis, and all three test suites.

- [ ] **Step 7: Commit**

```bash
git add app/ && git commit -m "feat(app): read local-first from the SDK's sqlite store"
```

---

## Self-Review

**Spec coverage (Phase 1):** local DB (Tasks 1, 4) · migrations (Task 1) · change bus and reactive reads (Tasks 2, 6) · client-minted IDs (Task 3 — written now, first used in Phase 2) · `ConnectivityMonitor` injection (Task 5) · `FileTokenStore` (Task 5) · the offline-signout fix (Task 5) · version-cursored pull via the existing staleness endpoint (Task 6) · no polling except post-failure backoff (Task 6) · deleting `local_store.dart` and `offline_cache.dart` (Tasks 6, 7) · app wiring (Task 7).

**Deferred to Phase 2, by design:** the `outbox` table is created in Task 1 but never written; `pending` columns exist but stay 0; writes are pass-throughs.

**Known gaps the implementer must close by reading the code, flagged inline:** `ExpensesApi` needs exhaustive `listAllExpenses`/`listSplitEntries` variants; `SettlementsApi` needs `listAllSettlements` and its `LocalStore` dependency swapped for `BalanceDao`; the exact names of the existing delete/receipt methods must be carried through to the repositories.

---

## Phase 2 — Outbox and conflicts (not in this plan)

Writes commit to the local DB and enqueue an outbox op inside the same transaction; the engine drains FIFO on the same wake sources. Conflict detection compares the server's `updated` against `base_updated`, parks the op, and emits `SyncConflict`. Adds `sdk.sync.conflicts()` and `sdk.sync.resolve(seq, keepLocal:)`, and sets `pending = 1` on rows with unsent ops.

## Phase 3 — Realtime and receipts (not in this plan)

`pb.collection(...).subscribe()` marks groups dirty and reuses the Phase 1 pull path. Receipt ops carry `receipt_path`; a missing file syncs the row anyway and emits `ReceiptMissing` with the row data and the exception.
