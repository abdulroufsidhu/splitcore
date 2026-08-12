# Offline-First Sync — Phase 2: Outbox, Local-First Writes, Conflicts

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Writes commit to the local database and are replayed to the server by the sync engine, so the app is fully usable with no connection.

**Architecture:** A write opens one transaction that inserts the domain rows *and* an outbox op, then returns. The engine drains the outbox FIFO on the same wake sources Phase 1 established, before pulling. Conflicts park rather than overwrite.

**Tech Stack:** Unchanged from Phase 1 — Dart 3.9.2, `package:sqlite3`, PocketBase Dart client 0.22.

**Design spec:** `docs/superpowers/specs/2026-08-06-offline-first-sync-design.md`
**Phase 1 plan:** `docs/superpowers/plans/2026-08-06-offline-first-sync.md`

## Global Constraints

Everything from the Phase 1 plan still holds. Additionally:

- **Conflict detection applies to updates only.** Creates carry a client-minted id, so a replayed create that already landed fails `validation_not_unique` and counts as applied. A delete of an already-deleted record 404s and counts as applied. Neither can conflict. In this app the only update ops are `expense.update` and `receipt.attach`, so `Expense` is the only model that needs the server's `updated` timestamp.
- **Split math stays in the Go engine.** A local write computes its splits through `SplitcoreCalc.computeSplits`, and local balances through `computeBalances` — the same code the server runs. Nothing here adds a number in Dart.
- Balances written by a local write are provisional; the next pull replaces them with the server's.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `splitcore_sdk/lib/src/models.dart` | `Expense.updated` — the conflict base | modify |
| `splitcore_sdk/lib/src/local/dao/expense_dao.dart` | Persist `updated`, single-row upsert/delete, `pending` | modify |
| `splitcore_sdk/lib/src/local/dao/outbox_dao.dart` | Enqueue, drain order, state transitions | **new** |
| `splitcore_sdk/lib/src/sync/outbox_op.dart` | Op names + payload encode/decode | **new** |
| `splitcore_sdk/lib/src/sync/sync_engine.dart` | Push before pull, conflict detection, resolution | modify |
| `splitcore_sdk/lib/src/sync/events.dart` | `SyncConflict`, `SyncOpFailed` | modify |
| `splitcore_sdk/lib/src/repo/*_repository.dart` | Writes commit locally and enqueue | modify |
| `app/lib/screens/group_detail.dart` | Greys rows with an unsent op | modify |

---

### Task 1: Outbox storage and the conflict base

**Files:**
- Modify: `splitcore_sdk/lib/src/models.dart`
- Modify: `splitcore_sdk/lib/src/local/dao/expense_dao.dart`
- Create: `splitcore_sdk/lib/src/sync/outbox_op.dart`
- Create: `splitcore_sdk/lib/src/local/dao/outbox_dao.dart`
- Test: `splitcore_sdk/test/local/outbox_dao_test.dart`

**Interfaces:**
- Produces: `Expense.updated` (`DateTime?`); `OutboxOp` (`seq`, `op`, `recordId`, `payload`, `baseUpdated`, `receiptPath`, `state`, `attempts`, `lastError`); `OutboxDao.enqueue(...)  -> int`, `.pending() -> List<OutboxOp>`, `.conflicts() -> List<OutboxOp>`, `.markConflict(seq, error)`, `.markFailed(seq, error)`, `.delete(seq)`, `.deleteFor(recordId)`, `.pendingRecordIds() -> Set<String>`.

Steps: write the failing DAO test first (FIFO order, cascade-conflict of later ops for the same record, `pending` flag round-trip), then the implementation, then commit.

---

### Task 2: Local-first writes

**Files:**
- Modify: every `splitcore_sdk/lib/src/repo/*_repository.dart`
- Modify: `splitcore_sdk/lib/src/sdk.dart` (repositories now need `SplitcoreCalc`)
- Test: `splitcore_sdk/test/sync/local_write_test.dart`

A write:

1. Computes splits via the FFI engine (throws before touching the database if the spec is invalid).
2. Opens one transaction: upsert the domain rows with `pending = 1`, insert the outbox op, recompute the group's balances locally via `computeBalances`.
3. Returns. No network.

The test that matters: create an expense with the monitor offline, and assert it is visible through `watch()`, flagged pending, and that local balances moved — with the server never contacted.

---

### Task 3: Push, conflicts and resolution

**Files:**
- Modify: `splitcore_sdk/lib/src/sync/sync_engine.dart`
- Modify: `splitcore_sdk/lib/src/sync/events.dart`
- Test: `splitcore_sdk/test/sync/outbox_push_test.dart`

`_run()` becomes push-then-pull. Drain is strict FIFO; the outcome table is in the spec. On conflict, the op and every later op for the same `recordId` move to `conflict` and a `SyncConflict` is emitted.

`sync.conflicts()` lists them; `sync.resolve(seq, keepLocal:)` either re-bases the op on the server's current `updated` and re-queues it, or drops it and pulls the server's version back over the local row.

The tests that matter: offline create then reconnect lands on the server; a replayed op that already landed is not duplicated; an update whose server record moved parks instead of overwriting.

---

### Task 4: Surface pending and conflicts in the app

Rows with an unsent op render greyed. The existing sync banner gains a conflict state. Small, and last, so the SDK is proven before the UI leans on it.
