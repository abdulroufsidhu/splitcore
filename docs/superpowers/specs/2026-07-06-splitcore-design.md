# Splitcore — Expense-Splitting Backend + SDK Design

Date: 2026-07-06
Status: Approved

## Overview

Monorepo containing a pure Go calculation core (`splitcore`), a PocketBase server (`server`), and a Dart SDK (`splitcore_sdk`). The calculation core compiles both as a Go import (server) and a C shared library (Dart FFI), guaranteeing client and server math are identical by construction.

**Source of truth:** the record set (expenses, split_entries, settlements). Balances are always a derived cache, recomputable deterministically from records.

### In scope
Groups, members, expenses, split entries, settlements (reimbursements), receipts on split entries, cached balance table.

### Out of scope
Bank sync, IOU tracking, multi-currency conversion, recurring expenses, notifications. Currency is a group-level attribute; no conversion logic anywhere.

## Decisions (resolved with user)

| Question | Decision |
|---|---|
| Leftover cents | Largest-remainder distribution, ties broken by input order; callers pass stable member order |
| Debt simplification | Greedy max-debtor → max-creditor; ≤ n−1 transfers, deterministic, O(n log n) |
| Payer model | Single payer per expense; joint payments = two expenses |
| Percent splits | Basis points (int, 10000 = 100%); reject unless sum == 10000 |
| Log model | Mutable records + recompute (no append-only event table) |
| Settlement overpay | Allow any positive amount; overpayment flips balance direction |
| Staleness | Per-group monotonic `version` counter incremented by server hooks |
| Share splits | Positive integers only |
| FFI boundary | JSON strings in/out; small export surface + `SplitcoreFree` |
| Money representation | `int64` minor units (cents); no floats in any money path |

## 1. Repo layout

```
slice_pay/
├── go.work             # ties splitcore + server
├── splitcore/          # pure Go module, stdlib only
│   ├── money/          # Money type, split calculations
│   ├── settle/         # debt simplification
│   ├── balance/        # balance recompute from records
│   ├── ffi/            # cgo export shim (JSON in/out)
│   └── build/          # cross-compile scripts (android/ios/linux)
├── server/             # Go module, PocketBase framework
│   ├── main.go
│   ├── migrations/     # collection schema as code
│   └── hooks/          # validation, version counter, balance rewrite, staleness endpoint
└── splitcore_sdk/      # Dart package
    ├── lib/
    │   ├── splitcore_sdk.dart   # sole public export
    │   └── src/                 # internal: ffi bindings, pb client, isolate wrapper, sync
    └── test/
```

`splitcore` never imports PocketBase or any framework. `server` imports `splitcore` directly (Go-to-Go, no FFI).

## 2. splitcore API (pure Go)

All amounts `int64` minor units.

```go
// money
type Split struct { MemberID string; AmountCents int64 }
ComputeEqualSplit(totalCents int64, memberIDs []string) ([]Split, error)
ComputeExactSplit(totalCents int64, entries []ExactEntry) ([]Split, error)     // entries must sum to total
ComputePercentSplit(totalCents int64, entries []PercentEntry) ([]Split, error) // basis points, sum must == 10000
ComputeShareSplit(totalCents int64, entries []ShareEntry) ([]Split, error)     // shares are positive ints

// settle
type Balance struct { MemberID string; NetCents int64 }  // + = owed money, − = owes
type Transfer struct { FromMemberID, ToMemberID string; AmountCents int64 }
SimplifyDebts(balances []Balance) ([]Transfer, error)

// balance
ComputeBalances(expenses []Expense, settlements []Settlement) ([]Balance, error)
```

Invariants (enforced by tests):
- `sum(splits) == total` for every split function, always — no lost or duplicated cents.
- Same input order → same output (determinism). Callers sort members by ID before calling.
- Zero/negative totals rejected; empty member list rejected; percent sum ≠ 10000 rejected; non-positive shares rejected; exact entries not summing to total rejected.
- `sum(balances) == 0` for every `ComputeBalances` result.
- `SimplifyDebts` output: applying transfers to balances yields all-zero; at most n−1 transfers.

### FFI shim (`splitcore/ffi`)

```go
//export SplitcoreComputeSplits
func SplitcoreComputeSplits(req *C.char) *C.char   // {type, total_cents, entries[]} → {splits[]} | {error}
//export SplitcoreSimplifyDebts
func SplitcoreSimplifyDebts(req *C.char) *C.char
//export SplitcoreComputeBalances
func SplitcoreComputeBalances(req *C.char) *C.char
//export SplitcoreFree
func SplitcoreFree(p *C.char)
```

Every returned string must be released with `SplitcoreFree`. Errors returned as JSON `{"error": "..."}`, never panics across the boundary.

## 3. PocketBase collections

| Collection | Fields | Notes |
|---|---|---|
| `groups` | name, currency (ISO 4217 string), version (int), owner (user) | version hook-managed, not client-writable |
| `group_members` | group → groups, user → users, role (owner\|member) | unique (group, user) |
| `expenses` | group, payer (group_member), description, amount_cents (int), split_type (equal\|exact\|percent\|shares), date | |
| `split_entries` | expense, member (group_member), amount_cents (int), receipt (file, optional) | |
| `settlements` | group, from_member, to_member, amount_cents (int), date, note | |
| `balances` | group, member, net_cents (int) | cache only; hook-rewritten; client read-only |

API rules: every collection readable/writable only when `@request.auth` is a member of the record's group (via `group_members` lookup). `balances` has no client create/update/delete rule. `groups.version` excluded from client writes.

## 4. Server hooks + staleness endpoint

On create/update/delete of `expenses`, `split_entries`, `settlements` — in one transaction:
1. **Validate** via splitcore: split entries sum to expense amount; amounts positive; members belong to the group; from ≠ to on settlements.
2. **Increment** `groups.version`.
3. **Recompute** balances for the group via `splitcore.ComputeBalances` and rewrite `balances` rows.

Server-side recompute is internal integrity only — no client-facing calculation API.

**Staleness endpoint:** `GET /api/splitcore/staleness?group={id}&version={n}` → `{"current": bool, "serverVersion": int}`. Single indexed row read; requester must be a group member.

## 5. Dart SDK (`splitcore_sdk`)

Public surface, exported only via `lib/splitcore_sdk.dart`:

```dart
SplitcoreSdk.initialize(pocketbaseUrl: ...)
sdk.auth         // signIn / signUp / signOut / currentUser
sdk.groups       // CRUD + member management
sdk.expenses     // create with split spec, update, delete, receipt attach
sdk.settlements  // create — internally staleness-checks and resyncs first
sdk.balances     // local FFI compute from synced records
sdk.settleUp     // FFI SimplifyDebts → suggested transfers
```

Internals (`lib/src/`, not exported):
- **FFI bindings** to libsplitcore; JSON in/out matching the shim.
- **Isolate wrapper:** every FFI computation runs via `Isolate.run`; all public APIs are `Future`-based; callers never see isolates.
- **PocketBase client:** SDK owns all PB communication; frontend never talks to PB directly.
- **Local store:** in-memory per group, version-tagged, fetch-on-demand. No persistent cache in v1; interface allows adding one later.
- **Receipt pipeline:** downscale to max dimension + JPEG re-encode (pure-Dart `image` package) before upload; attach to split entry.
- **Pre-settlement flow:** staleness check → if stale, refetch group records and recompute → then create settlement. Silent when current.

## 6. Cross-compilation

- **Linux `.so`** (`build_linux.sh`): for local Dart FFI tests. Fully verifiable in this environment.
- **Android** (`build_android.sh`): NDK clang per ABI — arm64-v8a, armeabi-v7a, x86_64, x86 — `-buildmode=c-shared`, output in `jniLibs/` layout. Verifiable here only if NDK is installed locally.
- **iOS** (`build_ios.sh`): `-buildmode=c-archive` for ios-arm64 (c-shared unsupported on iOS); produces static `.a` + header. **Not verifiable here** — requires macOS/Xcode; user must verify.

Verification status flagged in build script docs.

## 7. Testing strategy

- **splitcore:** strict TDD, table-driven tests. Edge cases: 1-member group, zero-balance group, partial settlement, overpay flip, 100.00/3, 0.01/3, zero/negative amounts, basis-point sum ≠ 10000, share = 0, determinism under stable order, `sum(splits)==total` property across ranges.
- **server:** PocketBase test harness — invalid splits rejected, version increments per mutation, balances rewritten correctly, non-members denied on every collection, staleness endpoint auth + correctness.
- **SDK:** FFI round-trip tests against Linux `.so`; unit tests for isolate wrapper, staleness/resync flow (mocked PB), receipt compression bounds.

## Build order

1. Repo scaffolding (go.work, modules, Dart package skeleton)
2. `splitcore` — full TDD, all invariants green
3. FFI shim + Linux `.so` + round-trip test
4. PocketBase migrations + hooks + staleness endpoint + tests
5. Dart SDK (bindings → isolate wrapper → PB client → high-level API) + tests
6. Android/iOS build scripts + docs
