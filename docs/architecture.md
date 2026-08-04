# Architecture

## The shape

```
┌─────────────────────────────────────────────────────────────┐
│  app/  — Flutter UI                                          │
│  screens, widgets, theme. Holds no domain logic, no HTTP.    │
└───────────────────────────┬─────────────────────────────────┘
                            │ SplitcoreSdk (the only API it sees)
┌───────────────────────────▼─────────────────────────────────┐
│  splitcore_sdk/  — Dart package                              │
│  ┌───────────────────────┐   ┌────────────────────────────┐ │
│  │ compute layer         │   │ remote layer               │ │
│  │ bindings → isolate →  │   │ auth, groups, expenses,    │ │
│  │ SplitcoreCalc         │   │ settlements, balances,     │ │
│  └──────────┬────────────┘   │ receipts, staleness, store │ │
│             │ dart:ffi       └──────────────┬─────────────┘ │
└─────────────┼───────────────────────────────┼───────────────┘
              │                               │ HTTPS (PocketBase REST)
┌─────────────▼──────────────┐   ┌────────────▼────────────────┐
│ libsplitcore.so / .a       │   │  server/  — Go + PocketBase  │
│ (cgo shim, JSON in/out)    │   │  migrations, access rules,   │
└─────────────┬──────────────┘   │  hooks, 3 custom routes      │
              │                  └────────────┬────────────────┘
┌─────────────▼───────────────────────────────▼───────────────┐
│  splitcore/  — pure Go: money, settle, balance               │
│  stdlib only. Imported by the server, compiled for the SDK.  │
└─────────────────────────────────────────────────────────────┘
```

The bottom box is reached two different ways. The server does a normal Go
import. The Dart SDK loads the same package compiled as a C shared library.
That is the whole point of the design: **one implementation, two consumers.**

## Layer 1 — `splitcore` (pure Go)

Three packages, stdlib only, no framework import anywhere:

- **`money`** — `ComputeEqualSplit`, `ComputeExactSplit`, `ComputePercentSplit`,
  `ComputeShareSplit`. All four route through one private `splitByWeights`
  using largest-remainder rounding, so leftover cents are distributed by a
  single rule everywhere. Invariant: `sum(splits) == total`, always.
- **`settle`** — `SimplifyDebts`: greedy max-debtor → max-creditor, ties broken
  by member id ascending. At most n−1 transfers, fully deterministic.
- **`balance`** — `ComputeBalances(expenses, settlements)`: net position per
  member, derived from the record set. Output sorted by member id. Invariant:
  `sum(balances) == 0`.

Every money path is `int64` minor units. Every addition goes through a checked
`addChecked` that returns an overflow error rather than wrapping — a wrapped
int64 in the settle loop would have meant an infinite loop, which is exactly
what a late review caught and fixed before merge.

### The FFI shim (`splitcore/ffi`)

Four C exports, all with the same contract — take a JSON string, return a
malloc'd JSON string the caller must release:

```
SplitcoreComputeSplits(req) → {"splits":[...]} | {"error":"..."}
SplitcoreSimplifyDebts(req) → {"transfers":[...]} | {"error":"..."}
SplitcoreComputeBalances(req) → {"balances":[...]} | {"error":"..."}
SplitcoreFree(ptr)
```

Every export goes through one `safeCall` wrapper that turns a NULL pointer or
any Go panic into a JSON error string. A panic unwinding across the cgo
boundary is undefined behaviour in the host process, so nothing is allowed to
cross it but a string.

JSON was chosen over a struct-based ABI on purpose: the export surface stays at
four symbols, and adding a field never breaks the binary interface. The payloads
are tens of members at most, so serialization cost is irrelevant.

## Layer 2 — `server` (Go + PocketBase)

PocketBase supplies auth, REST, file storage, admin UI, and SQLite. This project
supplies schema, rules, and domain behaviour on top of it.

Three responsibilities:

1. **Access control** — collection rules, expressed as PocketBase filter
   expressions in the migrations. The pattern throughout is "the requester must
   have a `group_members` row for this record's group." No exceptions, no
   endpoint that bypasses it.
2. **Domain validation via hooks** — payer must belong to the group, settlement
   `from` ≠ `to`, amounts positive, no re-parenting a record into another group.
3. **Version bump + balance recompute** — on any create/update/delete of
   `expenses`, `split_entries`, or `settlements`, in one transaction: bump
   `groups.version`, then rewrite that group's `balances` rows from scratch via
   `splitcore/balance`.

The server never computes math *for* a client. It imports `splitcore` only for
its own integrity. There is no calculation endpoint.

### Custom routes

Only three, all under `/api/splitcore/`:

- `GET /staleness` — O(1) "is my cached version current?"
- `POST /invite` — add someone to a group by email
- `GET /members` — resolve member names/avatars

The last one exists because PocketBase's default `users` rules are self-only:
a member cannot read another member's name. Rather than loosening that rule
globally, one app-privileged route crosses the boundary after confirming shared
group membership. See [api-reference.md](api-reference.md).

## Layer 3 — `splitcore_sdk` (Dart)

Two independent internal layers behind one facade.

**Compute layer:** `bindings.dart` (dlopen + 4 symbol lookups) →
`native_calc.dart` (encode → call → *always* free in a `finally` → decode) →
`isolate_calc.dart` (`Isolate.run`) → `calc_api.dart` (`SplitcoreCalc`).

Native library handles cannot cross isolate boundaries, so each call re-opens
the library inside the spawned isolate. Callers never see an isolate; every
public method returns a `Future`.

**Remote layer:** one file per concern — `auth_api`, `groups_api`,
`expenses_api`, `receipts`, `settlements_api`, `staleness_api`, `balances_api`,
`local_store`. There is deliberately no shared "PB client wrapper": each class
just takes a `PocketBase` instance, because there was no shared behaviour worth
abstracting. Network I/O is already async, so nothing here touches isolates.

**Facade:** `SplitcoreSdk.initialize(pocketbaseUrl:, libraryPath:, authStore:)`
wires one shared `PocketBase` client and one `SplitcoreCalc` into
`sdk.auth` / `.groups` / `.expenses` / `.settlements` / `.balances`, plus
top-level `settleUp` and `previewSplit`.

Hard boundary rule: **no PocketBase type ever crosses the public surface.**
`RecordModel` is converted to `AppUser`, `Group`, `Expense`, etc. at the edge of
`lib/src/remote/`. `lib/splitcore_sdk.dart` is the sole export file; everything
under `lib/src/` is internal.

The facade also installs a 15-second HTTP timeout on every request. Without it,
a dead or slow server leaves requests — and the `FutureBuilder`s waiting on
them — hanging forever instead of surfacing a retryable error.

## Layer 4 — `app` (Flutter)

Screens: login, home (groups + balances), group detail, add expense, settle up,
activity, new group, receipt viewer. Plus `theme.dart` (a `ThemeExtension`
carrying design tokens for light and dark) and small shared widgets.

State management is deliberately plain: `StatefulWidget` + `setState` +
`Future`, no state-management package. Each screen loads what it needs through
the SDK and rebuilds. For an app whose screens each make three or four calls and
render a list, anything more is machinery without a payer.

The app holds no domain logic. `money.dart` formats cents for display,
`activity.dart` merges expenses and settlements into one date-sorted feed, and
`display_name.dart` resolves who a member is on screen. That is all.

## Why these boundaries

**Why is the math its own package instead of living in the server?** Because
the client needs it too — to preview a split live as the user types, and to
recompute balances after a stale sync. Two implementations of rounding is how
you end up with a client and server that disagree by one cent and no way to say
which is right.

**Why FFI instead of reimplementing in Dart?** Same reason, taken seriously. A
port is a second implementation no matter how carefully it is tested; tests
prove agreement on the cases you thought of. Shared compiled code is agreement
by construction.

**Why does the SDK own all PocketBase traffic instead of the app?** So the wire
format has exactly one consumer. Field renames, auth changes, and the shift
from a collection read to a custom route (which is what happened with
`listMembers`) stay inside the SDK. The app was never touched.

**Why is `balances` a server-written cache and not client-computed on read?**
Reading a precomputed row is one request; recomputing means fetching every
expense, split entry, and settlement in the group. The client keeps the ability
to recompute for the case that actually needs it — the pre-settlement staleness
resync — and reads the cache the rest of the time.
