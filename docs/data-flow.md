# Data flow

End-to-end traces of what actually happens, in order, for each operation that
matters.

## Startup and auth

```
main() → SharedPreferences → AsyncAuthStore(initial: prefs['pb_auth'])
       → SplitcoreSdk.initialize(url, libraryPath, authStore)
       → currentUser = sdk.auth.currentUser        (from the restored token)
       → unawaited(_refreshSession())              (validate it, don't block UI)
```

The auth token is persisted through PocketBase's `AsyncAuthStore` backed by
`shared_preferences`, so a restart does not sign the user out. The default
in-memory store forgets the session on every launch.

A token can expire while the app sits backgrounded. Without handling, the first
request after resume just `401`s with no recovery path. So `SlicePayApp` is a
`WidgetsBindingObserver` and refreshes on `AppLifecycleState.resumed`, plus once
at startup. `tryRefresh()` returns `null` on failure and clears the store —
callers treat `null` as "signed out", which drops the UI back to the login
screen.

The native library path is resolved per platform: the bare soname
`libsplitcore.so` on Android and iOS (the OS loader finds it in the app's
bundled native libs), an absolute path from `--dart-define=SPLITCORE_LIB_PATH`
on desktop.

## Creating an expense

```
AddExpenseScreen
  │ user types amount, picks split type, edits per-member values
  │
  ├─▶ sdk.previewSplit(spec)              ── debounced, on every edit
  │     └─▶ SplitcoreCalc → Isolate.run → dlopen → SplitcoreComputeSplits
  │           → live per-member preview, computed by the same code
  │             the server will validate against
  │
  └─▶ on save: sdk.expenses.createExpense(...)
        1. calc.computeSplits(spec)              ← splits computed locally, first
        2. POST /api/collections/expenses        ← the parent row
        3. POST /api/collections/split_entries   ← one request per member, sequential
        4. (optional) attachReceipt(entryId, bytes)
```

Splits are computed **before** anything is written. The server's per-entry
validation is therefore a consistency check, not the source of the numbers —
the client already knows the answer, and the server independently agrees because
it runs the same code.

Each of steps 2 and 3 fires the server hook:

```
hook: validate → e.Next() → bumpAndRecompute(groupID)
                              └─ in one transaction:
                                 groups.version++
                                 load all expenses + split entries for the group
                                 skip any expense whose splits don't sum to its amount
                                 load all settlements
                                 splitcore/balance.ComputeBalances(...)
                                 delete every balances row for the group
                                 insert one row per member
```

Balances are rewritten wholesale rather than patched. The recompute is over one
group's records, groups are small, and a full rewrite cannot drift the way an
incremental update can. The version bump and the rewrite share one transaction,
so a failure mid-rewrite can never leave a bumped version alongside partial
balances.

While the split entries are being written one by one, the expense is incomplete
and contributes nothing — the balances stay correct throughout, then jump to the
new correct value when the last entry lands.

## Reading a group

```
GroupDetailScreen._load()
  ├─▶ sdk.groups.listMembers(groupId)      → GET /api/splitcore/members
  ├─▶ sdk.balances.getBalances(groupId)    → GET /api/collections/balances  (the cache)
  ├─▶ sdk.expenses.listExpenses(groupId)   → GET /api/collections/expenses  (-date)
  └─▶ sdk.settlements.listSettlements(id)  → GET /api/collections/settlements (-date)
        └─▶ buildActivity(...) merges expenses + settlements into one
            date-sorted feed, newest first
```

The read path never recomputes. It reads the server's cache. Recompute-from-log
is reserved for exactly one situation, below.

The home screen does the same per group, in parallel via `Future.wait`, keeping
only *this user's* net from each group's balances. A group whose row fails to
load is dropped rather than failing the whole screen.

## Settling up — the staleness protocol

This is the one flow where correctness depends on freshness, so it is the one
flow with a guard.

```
SettleUpScreen
  └─▶ sdk.settleUp(balances)               ← FFI SimplifyDebts → suggested transfers
        │  greedy max-debtor → max-creditor, ≤ n−1 transfers, deterministic
        │
        └─▶ user taps "Record payment" on one transfer
              └─▶ sdk.groups.getGroup(id)            ← fetch the current version
                  sdk.settlements.createSettlement(groupId, localVersion, …)
                    │
                    ├─ GET /api/splitcore/staleness?group=…&version=…
                    │    → {"current": bool, "serverVersion": n}
                    │
                    ├─ current == true  → proceed silently
                    │
                    └─ current == false → resync FIRST:
                         fetch all expenses + split entries + settlements
                         calc.computeBalances(...)            ← FFI, off the UI thread
                         store.put(groupId, GroupSnapshot(version, balances))
                         then create the settlement
```

Why this exists: someone else may have added an expense since these transfers
were suggested. Writing a settlement computed against a stale view records a
payment that does not match what is actually owed. The staleness check is a
single indexed row read — one integer comparison — so it can run before every
settlement without cost. A full recompute only happens when it actually fails.

The check is a metadata read, deliberately. Re-fetching the group's whole
record set on every settlement would work and would be simpler, and would also
be a heavy request on the most common path in order to catch the rare one.

## Adding someone to a group

```
POST /api/splitcore/invite {group_id, email, role}
  │ caller must own the group (checked server-side; 404 otherwise)
  │
  ├─ email already has an account
  │    └─ already a member? → {"status":"added"}, no-op
  │       otherwise         → create group_members row → {"status":"added"}
  │
  └─ email has no account
       └─ create invites row (status: pending) → {"status":"invited"}

… later, that email signs up:
  OnRecordAfterCreateSuccess("users")
    └─ find all pending invites for this email
       for each: create the group_members row, mark the invite accepted
```

There is no accept/decline step and no friends graph. Being invited to a group
means being in the group. The auto-join fires on sign-up completion rather than
on next login, so an existing member's `listMembers` reflects the new person
immediately.

The "add a person" flow on the home screen reuses this: it creates a group with
`is_direct: true`, then invites one email into it. A 1:1 conversation is just a
two-member group that the UI draws differently.

## Receipts

```
image_picker → Uint8List
  └─▶ sdk.expenses.attachReceipt(splitEntryId, bytes)
        ├─ compressReceipt(bytes, maxDimension: 1600, quality: 85)
        │    pure-Dart downscale + JPEG re-encode — client-side, always
        └─ PATCH the split_entries row's `receipt` file field

… to display:
  sdk.expenses.receiptUrl(entry)
    → {baseUrl}/api/files/split_entries/{id}/{filename}, or null
```

Compression is client-side so the server never resizes images and never needs an
image toolchain. `receiptUrl` lives in the SDK so the app does not need to know
PocketBase's file-URL scheme or hold a PocketBase client.

## Why member names need a custom route

PocketBase's default `users` list/view rule is self-only (`id = @request.auth.id`).
A group member therefore cannot read another member's name or avatar — which the
UI needs on essentially every screen.

Two options: loosen the `users` rule so any authenticated user can read any
user, or add one app-privileged route that crosses the boundary after checking
that the caller shares the group. The second keeps the default deny in place and
puts the exception in one auditable place:

```
GET /api/splitcore/members?group_id=…
  → 401 if unauthenticated
  → 404 unless the caller has a group_members row for this group
  → [{id, user, role, name, avatar}, …]   ← membership id first; that's what
                                             everything else references
```

## The error path

Every screen's loader is `try / catch` into `_error`, rendered as a retry state.
The SDK adds a 15-second timeout to every HTTP request, so an unreachable server
produces a failure the user can retry rather than a spinner that never resolves.
FFI errors surface as `SplitcoreException` — the Go side returns `{"error": …}`
across the boundary and never panics into the host process.
