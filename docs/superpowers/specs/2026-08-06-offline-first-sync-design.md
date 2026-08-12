# Offline-First Sync and Auth Persistence — Design

**Date:** 2026-08-06
**Status:** Implemented (all three phases)
**Affects:** `splitcore_sdk` (0.1.0 → 0.2.0, breaking), `app/lib/`

## Problem

The SDK is online-only. Every read is a network fetch, every write is a
network round-trip, and nothing survives a process restart:

- `LocalStore` (`remote/local_store.dart`) is an in-memory `Map` of balance
  snapshots that dies with the process.
- The app compensates with its own read-only `offline_cache.dart` on
  SharedPreferences — last-known-good display data, no write support.
- Writes made without a connection simply fail.
- `AuthApi._refresh()` (`remote/auth_api.dart`) catches *every* exception and
  calls `authStore.clear()`. A network failure is indistinguishable from an
  expired token, so **launching the app offline signs the user out.** This is
  the auth-persistence bug, and it is fixed as part of this work.

There is no realtime channel: PocketBase's SSE subscribe is unused, so a
change made on another device is invisible until the user re-navigates.

## Goal

`splitcore_sdk` becomes local-first. The local SQLite database is the single
source of truth the UI reads from. Writes commit locally and are replayed to
the server by an event-driven sync engine. Nothing polls.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Package type | Stays pure Dart | Keeps `dart test` headless, keeps the package publishable and usable from the Linux/Windows desktop builds. Flutter-only dependencies are injected by the app, following the existing `TokenStore` pattern. |
| Local DB | `package:sqlite3` + hand-written SQL | Real transactions, which is the actual argument: an expense and its `split_entries` commit atomically *locally* even though PocketBase offers no client-side transaction. Indexed queries keep search and pagination fast as history grows. No codegen. |
| Offline write scope | Everything except auth | Groups, members, expenses, settlements and receipts all queue. |
| Receipts offline | Queue the **local file path**, not bytes | The outbox stays small rows instead of becoming a blob store. |
| Conflicts | Detect and park | Each op records the `updated` it was based on. A moved server record parks the op and surfaces both versions. Never silently overwrite a shared ledger. |
| Read API | `Stream`, breaking | Reads re-emit when sync writes. Stale screens become impossible. |
| Sync trigger | Events only | Connectivity transition, local outbox insert, PocketBase SSE, manual. The one timer is post-failure backoff. |

### Rejected

- **Drift.** Same engine, and its generated `watch()` streams would be most of
  the change bus for free — but `build_runner` codegen in a published package
  is a heavy, permanent cost for something ~80 lines of SQL covers.
- **Plain JSON files.** Zero dependencies, but whole-file rewrites and no
  index. Fine for hundreds of expenses, wrong for years of history, and it
  gives up the local atomicity that motivates SQLite here.
- **A `Database` interface with in-memory and SQLite implementations.**
  `sqlite3.openInMemory()` is pure Dart and runs headless, so tests use the
  real engine. One implementation, no abstraction. Only `ConnectivityMonitor`
  is an injected interface, because it genuinely has no pure-Dart
  implementation.
- **Last-write-wins.** Silently discards a co-member's edit. Unacceptable for
  money.

## Architecture

```
app  ──reads──▶  watch*() Streams
                      ▲
                      │ re-emit on table change
  ┌───────────────────┴────────────────────────────┐
  │  local/    SplitcoreDb (sqlite3) + DAOs        │
  │            ChangeBus: Stream<Set<String>>      │
  └───────▲──────────────────────┬─────────────────┘
     write│ (one txn:            │ outbox row inserted
          │  rows + outbox op)   ▼
  ┌───────┴──────────────────────────────────────────┐
  │  sync/     SyncEngine  ("dbListener")            │
  │    wakes on: outbox insert · connectivity→online │
  │              realtime event · manual sync()      │
  │    push: drain outbox FIFO ──▶ remote/*Api       │
  │    pull: staleness(version) ──▶ upsert local     │
  └──────────────────────────────────────────────────┘
          ▲                            ▲
   ConnectivityMonitor          PocketBase SSE
   (app-injected)               (subscribe, no polling)
```

`remote/` keeps its current job — the PocketBase wire layer — but is demoted:
only `SyncEngine` and `AuthApi` call it. The public API no longer touches the
network directly. The layering rule is unchanged and still enforced: no
PocketBase type crosses out of `remote/`.

### Modules

| Module | Responsibility | Depends on |
|---|---|---|
| `local/database.dart` | Opens SQLite (path or in-memory), owns migrations via `PRAGMA user_version`, exposes `transaction()` | `package:sqlite3` |
| `local/schema.dart` | `CREATE TABLE` statements and per-version migration steps | — |
| `local/change_bus.dart` | Broadcast `Stream<Set<String>>` of touched table names; the basis of every `watch*` | — |
| `local/dao/*.dart` | Row ⇄ model mapping and queries, one file per entity | database, models |
| `local/ids.dart` | Mints PocketBase-format 15-char IDs | — |
| `sync/connectivity.dart` | `ConnectivityMonitor` interface + `AlwaysOnline` default | — |
| `sync/outbox.dart` | Outbox table access, op enqueue, state transitions | database |
| `sync/sync_engine.dart` | The dbListener: wake sources, push, pull, backoff | outbox, DAOs, remote/, connectivity |
| `sync/realtime.dart` | PocketBase SSE subscription → dirty groups | remote/ |
| `sync/events.dart` | `SyncEvent` hierarchy surfaced to the app | — |

## Data model

Local tables mirror the server collections: `groups`, `members`, `expenses`,
`split_entries`, `settlements`, `balances`, plus two of the SDK's own:
`outbox` and `sync_state`.

Every mirrored table carries:

- `updated TEXT` — the server's `updated` timestamp, the conflict base.
- `pending INTEGER NOT NULL DEFAULT 0` — 1 while an unsent outbox op targets
  this row, so the UI can grey it.

`sync_state` holds one row per group: the last-synced `version` (the cursor)
and the last successful sync time.

### Client-minted IDs

Records created offline get a client-generated ID in PocketBase's own format
(15 chars, `[a-z0-9]`), sent as `id` on create. This is what makes offline
work at all:

- `split_entries.expense` can reference an expense the server has never seen.
- A retried create that already landed fails with `validation_not_unique` on
  `id`, which the engine treats as success. Replay is idempotent for free.

### Balances are derived, not synced

Offline balances are recomputed locally through the existing FFI export
`SplitcoreComputeBalances` over local rows — the same Go code the server runs
in `server/hooks/recompute.go`, so the two agree by construction. Money math
stays in the Go engine; nothing here computes an amount in Dart. A successful
pull overwrites local balances with the server's rows.

## Sync engine

### Outbox

```sql
CREATE TABLE outbox (
  seq          INTEGER PRIMARY KEY AUTOINCREMENT,
  op           TEXT NOT NULL,      -- 'expense.create', 'settlement.delete', ...
  record_id    TEXT NOT NULL,
  payload      TEXT NOT NULL,      -- JSON
  base_updated TEXT,               -- server `updated` this op was based on; null for creates
  receipt_path TEXT,
  state        TEXT NOT NULL DEFAULT 'pending',  -- pending | conflict | failed
  attempts     INTEGER NOT NULL DEFAULT 0,
  last_error   TEXT,
  created_at   TEXT NOT NULL
);
```

**Ops are SDK-level, not row-level.** `expense.create` carries the expense
*and* its split entries as one payload, so replay calls
`ExpensesApi.createExpense` and inherits its existing compensating-delete
rollback. Without this, a partially-replayed expense whose splits do not sum
to its total is permanently skipped by the server's recompute — it shows in
the list, counts for nothing, and can only be removed by hand. There is no
second implementation of that atomicity dance.

### Push

Strict FIFO by `seq`. Ordering matters: an update to a record must not
overtake its create.

| Result | Action |
|---|---|
| 2xx | Delete the row, clear `pending` on the target |
| `validation_not_unique` on `id` | Already applied — same as 2xx |
| 404 on a delete | Already gone — same as 2xx |
| Server `updated` ≠ `base_updated` | `state=conflict`, emit `SyncConflict`; cascade-conflict every later op for the same `record_id` |
| Other 4xx (validation) | `state=failed`, emit `SyncFailed`, skip and continue |
| Network error | Stop draining, preserve order, arm backoff |

### Receipts

An op carries `receipt_path`. At sync time the engine reads the file. If it is
gone, **the row still syncs** and a `ReceiptMissing(record, path, error)` event
carries the row data plus the exception, so the user's expense is not held
hostage to a photo that the OS cleaned up.

### Pull

Per group, `GET /api/splitcore/staleness?group=&version=` — the existing
endpoint — compares the local cursor to the server's `version`. Only groups
that moved are re-fetched. O(1) metadata check per group, never a blind full
download. The group list itself is small and fetched whole.

### Realtime

While online, `pb.collection(...).subscribe()` marks the affected group dirty
and runs the same pull path. One code path, whether the wake came from SSE, a
reconnect, or a manual `sync()`.

### No polling

The only timer in the system is exponential backoff **after a failure**
(capped at 5 minutes), cancelled the moment connectivity or a realtime event
fires. Steady state is entirely event-driven.

## Public API (0.2.0, breaking)

```dart
sdk.expenses.watch(groupId)   // Stream<List<Expense>>, local-first
sdk.groups.watch()
sdk.balances.watch(groupId)

sdk.sync.events               // Stream<SyncEvent>
sdk.sync.conflicts()          // Future<List<Conflict>>
sdk.sync.resolve(seq, keepLocal: bool)
sdk.sync.now()                // manual, for pull-to-refresh
```

Writes keep their signatures but return once the **local** commit lands, not
the server round-trip. `remote/local_store.dart` and `app/lib/offline_cache.dart`
are both deleted — they are strictly subsumed.

Wiring, following the existing `TokenStore` precedent:

```dart
SplitcoreSdk.initialize(
  pocketbaseUrl: ...,
  libraryPath: ...,
  databasePath: '${dir.path}/splitcore.db',
  connectivity: ConnectivityPlusMonitor(),   // app-side, wraps connectivity_plus
  tokenStore: PrefsTokenStore(prefs),
);
```

## Auth persistence

1. **Fix `_refresh()`**: clear the auth store only on 401/403. On a network
   error, keep the session — the stored token is still the best evidence of who
   is signed in, and the sync engine will refresh when connectivity returns.
2. **Ship `FileTokenStore`** in the SDK, so persistence works with no app
   wiring at all. The app's SharedPreferences implementation keeps working
   unchanged.
3. Signed-in state is answerable offline, from the store, without a request.

## Error handling

- Local write failures (disk full, corrupt DB) throw from the write call —
  the caller has not been told the write succeeded.
- Network failures never surface to write callers. The write already
  committed locally; the failure surfaces on `sdk.sync.events`.
- A corrupt or unreadable database is dropped and recreated. Anything not yet
  synced is lost, so this is a last resort and emits a `SyncEvent` — but a
  crash loop is worse.
- Conflicts and permanent validation failures are never dropped silently.
  Both park in the outbox until the app resolves them.

## Testing

- `sqlite3.openInMemory()` for DAO and migration tests — the real engine, no
  temp files.
- `FakeConnectivityMonitor` with a controllable stream makes the engine
  deterministic: no sleeping, no wall-clock waits.
- The existing `test/support/pb_server.dart` spawns a real PocketBase, so
  conflict detection, replay idempotency, and the missing-receipt path are
  tested end to end against real wire behavior, not mocks.

## Phasing

Each phase is shippable on its own.

All three phases are built. Implementation notes and the defects each phase
uncovered are in the plans under `docs/superpowers/plans/`.

1. **Local DB + reactive reads + pull.** Schema, DAOs, change bus,
   `ConnectivityMonitor`, `watch*`, pull-on-connect, the auth fix, and
   `FileTokenStore`. The app reads local-first and survives a restart offline.
   Writes still require a connection.
2. **Outbox + push + conflicts.** Writes commit locally and replay. Conflict
   detection, the conflict/failed states, and the resolution API.
3. **Realtime + receipts.** SSE subscriptions, and receipt paths in the
   outbox with the missing-file event.
