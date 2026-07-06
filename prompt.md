Start completely fresh — do not look for, reference, or resume any existing 
"splitcore" project or package. This is a brand new project from an empty directory.

Build the backend and SDK for an expense-splitting app (Splitwise-style). Follow 
strict clean architecture and TDD throughout. Here is the full spec:

## Scope
In scope: groups, members, expenses, split entries, settlements (as reimbursements), 
receipts attached to split entries, cached balance table derived from an event log.

Explicitly OUT of scope: bank sync, IOU tracking, multi-currency conversion, 
recurring expenses, notifications. Currency is a group-level attribute — no 
conversion logic anywhere. If multi-currency is needed later, that's a "create 
another group" problem, not a data-model problem.

## Architecture

**Source of truth model:** The event log (expenses, split entries, settlements) 
is the single source of truth. Balances are always a derived/cached view, 
recomputable from the log. Never treat the cached balance table as authoritative.

**Three layers, one shared core:**

1. `splitcore` — a pure Go package with zero framework dependencies. Contains:
   - Money/split calculation logic (exact splits, percentage splits, share-based 
     splits, with correct rounding — no lost or duplicated cents)
   - Settlement/debt-simplification algorithm (minimize number of transactions 
     needed to settle a group's balances)
   - Balance-from-event-log recomputation (deterministic: same log always 
     produces same balances)
   - Written with TDD — write the test first for every function, especially 
     rounding edge cases and settlement edge cases (partial settlements, 
     uneven splits, single-member groups, zero-balance groups)
   - This package must be compilable as a C-shared library (for FFI) AND 
     importable directly by the Go server. One implementation, two consumers.

2. `server` — a Go application using PocketBase as the backend framework.
   - PocketBase collections: groups (with currency field), group_members, 
     expenses, split_entries (with receipt file field), settlements
   - Permission rules: only group members can read/write their group's data
   - PocketBase hooks import `splitcore` directly (not via FFI, it's Go-to-Go) 
     for any server-side validation or recomputation
   - Expose one lightweight endpoint for the "staleness check": given a group 
     ID and the client's last-synced event timestamp/count, return whether the 
     client's view is current. This should be a cheap metadata check, not a 
     full recompute.
   - No endpoint should require the server to do split/settlement math for the 
     client under normal operation — the client does that via the SDK. The 
     server computing the same math (via direct Go import of splitcore) is 
     only for internal validation/hooks, not a client-facing calculation API.

3. `splitcore_sdk` — a Dart package, meant to be published/used as a local 
   package by both a future Flutter frontend and any other Dart consumer.
   - Wraps `splitcore` via `dart:ffi`, calling the same compiled logic the 
     server uses — this guarantees client and server math can never drift, 
     by construction, not by testing two implementations against each other.
   - All FFI calls that do non-trivial computation run inside a Dart Isolate, 
     so the UI thread never blocks. Provide a clean async API — callers should 
     not need to know isolates are involved.
   - Takes a PocketBase URL as a configuration/initialization parameter (e.g. 
     `SplitcoreSdk.initialize(pocketbaseUrl: ...)`), and owns all PocketBase 
     communication itself — the frontend never talks to PocketBase directly, 
     only through this SDK.
   - Responsibilities: auth against PocketBase, CRUD for groups/expenses/splits/
     settlements, receipt upload (compress/prepare before upload) and 
     attachment to split entries, local sync of the event log, calling FFI for 
     all split/settlement/balance calculations, and the pre-settlement 
     staleness check (silently proceed if the client is current; force a 
     resync if not, before allowing a settlement to be created).
   - Structure this as installable Dart package with clear public API surface 
     (what's exported vs internal), not a dumping ground of scripts.

## Cross-compilation
Set up build scripts/tooling for compiling `splitcore` as a shared library for:
- Android (all standard ABIs)
- iOS (arm64)
Get this working and documented even if I have to do final verification on 
real devices/simulators myself — flag clearly which parts you were able to 
verify in this environment vs which need my testing.

## Process
1. Set up the repo structure (monorepo: `/splitcore`, `/server`, `/splitcore_sdk`)
2. Build `splitcore` first, fully TDD, before touching PocketBase or Dart
3. Then PocketBase schema + hooks
4. Then the FFI bridge and Dart SDK
5. At each stage, run the actual tests and show me they pass — don't just 
   write code and assume it works

Ask me clarifying questions before starting if anything above is ambiguous — 
don't guess on money-math semantics.
