# Decisions

Every non-obvious choice, what it rules out, and why it was worth it. Decisions
marked **(resolved with user)** were settled before implementation started — the
money-math semantics were not guessed at.

## Money

**`int64` minor units everywhere, never a float.** (resolved with user)
There is no `float` in any money path — not in Go, not in Dart, not in the JSON
crossing FFI. Floating-point cents are the canonical way to lose a cent per
thousand transactions and never be able to explain where it went.

**Leftover cents go by largest remainder, ties broken by input order.** (resolved with user)
Splitting 100.00 three ways gives 33.34 / 33.33 / 33.33 — someone gets the extra
cent, and *which* someone must be deterministic or two clients computing the
same split disagree. All four split functions route through one
`splitByWeights`, so there is exactly one rounding rule in the codebase.
Callers pass a stable member order.

**Percentages are basis points, rejected unless they sum to 10000.** (resolved with user)
Integer basis points keep percentages out of the float path entirely. Rejecting
sums ≠ 10000 rather than normalizing them means a UI bug surfaces as an error
instead of a silently rescaled split.

**Overflow is a checked error, not a wrap.** Every addition uses `addChecked`.
This was not there originally: a final review found that a wrapped `int64` in
the settle loop would spin forever, since the loop terminates on balances
reaching zero and a wrapped sum never does. It is guarded in all three packages
now. The duplicated helper across `money`, `settle`, and `balance` is
deliberate — sharing it would mean one of the packages importing another purely
for a five-line function.

**Settlements may exceed what is owed.** (resolved with user)
Overpaying flips the balance direction, which is exactly what happens when
someone rounds up. Rejecting it would mean rejecting a payment that really
occurred.

**Zero-amount split entries are legal; zero-amount expenses are not.**
A member can appear on a bill owing nothing. An expense of zero is a data-entry
error. The asymmetry is intentional.

## Architecture

**One math implementation, shared as compiled code.**
The alternative — a Go implementation on the server and a Dart port on the
client — means two rounding implementations that must be kept in agreement
forever, verified by tests that can only cover the cases someone thought of. FFI
makes agreement structural. The cost is a cgo build step and per-platform
cross-compilation, paid once at build time.

**JSON across the FFI boundary, four exports.** (resolved with user)
A struct-based ABI would be marginally faster and would break every time a field
is added. Payloads here are tens of members. Four symbols plus `SplitcoreFree`
is a surface small enough to audit in one sitting.

**Nothing crosses the cgo boundary but a string.** Every export goes through
`safeCall`, which converts a NULL pointer or any panic into a JSON error. A
panic unwinding into the host process is undefined behaviour — an app crash with
no stack trace, on a user's phone.

**Mutable records plus recompute — not an append-only event table.** (resolved with user)
The expenses/splits/settlements record set *is* the log. Editing an expense
edits the row and triggers a recompute. A true append-only event store would
give free history and audit, at the cost of every read becoming a fold and every
edit becoming a compensating event. For a group of six people splitting dinner,
that machinery has no payer.

**Balances are a cache, and the cache is rewritten whole.**
Never patched incrementally. A full rewrite over one group's records cannot
drift; an incremental update eventually does, and the bug surfaces weeks later
as a balance nobody can explain. The whole rewrite is one transaction with the
version bump.

**A monotonic per-group `version` counter for staleness.** (resolved with user)
Alternatives were a `last_modified` timestamp (clock skew, equal timestamps
within a second) or hashing the record set (requires reading the record set,
which defeats the point). An integer bumped by the same hook that recomputes
balances is one indexed read and one comparison.

**The server exposes no calculation endpoint.**
It imports `splitcore` for its own validation and recompute only. Clients
compute locally via the SDK. This keeps the server from becoming the place the
math lives, which would make the FFI layer pointless.

**PocketBase as the backend framework.** (resolved with user)
Supplies auth, REST, file storage, admin UI, and SQLite. What remains to build
is schema, rules, and domain hooks — which is the actual product. The constraint
accepted in exchange: PocketBase's rule DSL and hook model set the shape of the
access-control layer, and there is no batch-create API (see below).

**The official `pocketbase` pub.dev package, not a hand-rolled HTTP client.** (resolved with user)
Auth token handling, file uploads, and the `AsyncAuthStore` persistence path all
come free and correct.

## Server

**Every access rule is "must have a `group_members` row for this record's group."**
Three filter expressions, differing only in how they reach the group id. One
idea, uniformly applied, and a non-member sees nothing rather than an empty
filtered list.

**Non-members get `404`, not `403`.** On `/api/splitcore/staleness`, an unknown
group and a real group the caller does not belong to return the same response.
A `403` confirms the group exists.

**`version` and `owner` are restored from storage on every group update.**
Not validated — overwritten. And if the stored record cannot be read, the update
fails closed. A guard that cannot be applied must not be skipped.

**Group re-parenting is rejected outright.** Moving an expense or settlement to
a different group would leave the old group's balances stale, since the
recompute only touches one group per hook. Recomputing both was possible;
disallowing a move nobody needs was one condition.

**Incomplete expenses are skipped by the recompute.** PocketBase has no batch
create, so an expense and its split entries arrive as separate requests. Rather
than inventing a client-side transaction protocol, the recompute ignores any
expense whose splits do not sum to its amount. The completeness check *is* the
protocol.

**One app-privileged route for member names, instead of loosening the `users` rule.**
PocketBase's default is self-only. The UI needs other members' names. One route
that checks shared membership first keeps the global deny in place and puts the
exception somewhere auditable.

**Invites have no accept/decline step.** Being invited to a group means being in
the group; the pending `invites` row exists only to cover the case where the
email has no account yet. A full invitation lifecycle is a friends-network
feature, and this is not a friends network.

**1:1 "direct" groups are a boolean, not an entity.** `groups.is_direct` changes
how the UI draws a group. Same schema, same rules, same expense and settlement
machinery. A separate direct-message entity would duplicate all of it.

**Automigrate is on under `go run`, off for a compiled binary.** `main.go`
detects a temp-dir `os.Args[0]`. Local dev never needs a migration step;
production never applies migrations as a side effect of starting.

## SDK

**Every FFI computation runs via `Isolate.run`; no PocketBase call does.**
FFI is synchronous and would block the UI isolate. Network I/O is already async.
Wrapping HTTP calls in isolates would add spawn cost for nothing.

**Each isolate re-opens the shared library.** Native library handles cannot
cross isolate boundaries. Reusing a handle created on the calling isolate is a
crash, not a compile error.

**No PocketBase type crosses the public surface.** `RecordModel` is converted at
the edge of `lib/src/remote/`. When `listMembers` changed from a collection
query to a custom route, no consumer changed.

**No shared "PB client wrapper" class.** Every remote class takes a `PocketBase`
instance directly, because there was no shared behaviour worth abstracting. This
was an explicit deviation from the plan, taken once the code showed the wrapper
would be an empty layer.

**In-memory local store, no persistence in v1.** Fetch-on-demand, lost on
restart. The interface is narrow enough that a persistent implementation could
be swapped in without touching callers — which is the correct amount of
provision for a feature nobody has asked for.

**A 15-second timeout on every request.** Without it, a dead or slow server
leaves requests and their `FutureBuilder`s hanging forever. A retryable error
beats an eternal spinner.

**Receipts are compressed client-side.** Downscale to 1600px + JPEG re-encode
before upload. The server never resizes images and needs no image toolchain.

## App

**Plain `StatefulWidget` + `setState` + `Future`. No state-management package.**
Each screen makes three or four calls and renders a list. Provider, Riverpod, or
BLoC here would be machinery serving no need.

**Fonts are bundled, runtime fetching disabled.** `GoogleFonts.config.allowRuntimeFetching = false`
with the TTFs in `assets/fonts`. No fallback-font flash, no first-launch failure
offline.

**Design tokens live in a `ThemeExtension`, read via `context.slice`.** Light and
dark palettes resolve automatically from the system setting, and money colour
means the same thing on every screen: green is owed to you, coral is you owe,
grey is settled.

**`intl`'s built-in currency table for symbols**, not a hand-maintained map.
Falls back to the code itself for anything it does not recognize.

## Known limits, accepted

- **`settle`'s inner scan is O(n²)** in members per group. Determinism was worth
  more than speed at realistic group sizes.
- **`json.Marshal` errors are discarded** in four spots in the FFI handler. The
  inputs are `map[string]string` and fixed structs — unreachable in practice.
- **iOS is unverified.** `build_ios.sh` produces the right artifacts by
  construction but has never run on macOS in this project. Explicitly flagged,
  not quietly assumed. See [development.md](development.md).
- **Simulator builds on Apple Silicon** need a separate `iphonesimulator` SDK
  build combined via `lipo`/`xcframework`. Deferred until there is a real iOS
  target.
- **Schema drift on pre-existing collections is not detected.** `InitCollections`
  skips a collection that already exists; it does not diff the schema.
