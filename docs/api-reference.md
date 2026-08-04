# API reference

Two surfaces: the HTTP routes the server adds on top of PocketBase's generated
REST API, and the Dart SDK's public API — the only thing a frontend should ever
touch.

## HTTP

Everything under `/api/collections/...` is PocketBase's standard generated REST
API, gated by the rules in [data-model.md](data-model.md). Three custom routes
exist beyond it.

### `GET /api/splitcore/staleness`

Is a client's cached group snapshot still current? One indexed row read — never
a recompute.

| Param | Type | |
|---|---|---|
| `group` | string | required |
| `version` | int | required — the client's last known version |

```json
200 → { "current": true, "serverVersion": 3 }
```

`current` is `clientVersion == serverVersion`. `serverVersion` is returned so
the client knows what to compare against next time.

- `401` — no auth
- `400` — `group` missing, or `version` missing/non-integer
- `404` — the caller is not a member **or** the group does not exist. The two
  are deliberately indistinguishable.

### `POST /api/splitcore/invite`

Add someone to a group by email. Caller must own the group.

```json
{ "group_id": "...", "email": "a@b.com", "role": "member" }   // role defaults to "member"
```

```json
200 → { "status": "added" }     // the email had an account (or was already a member)
200 → { "status": "invited" }   // no account yet — a pending invite was recorded
```

A pending invite is fulfilled automatically the moment that email signs up.
There is no accept step.

- `401` — no auth
- `400` — `group_id` or `email` missing
- `404` — caller does not own the group (or it does not exist)

### `GET /api/splitcore/members`

Members of a group with names and avatars resolved. Exists because PocketBase's
default `users` rules are self-only, so a member cannot read another member's
record directly.

| Param | Type | |
|---|---|---|
| `group_id` | string | required |

```json
200 → [ { "id": "<group_members id>", "user": "<users id>",
          "role": "owner", "name": "Alice", "avatar": "photo.jpg" } ]
```

`id` is the **membership** id — the id that expenses, settlements, and balances
reference. `avatar` is a filename; build the URL as
`{baseUrl}/api/files/users/{user}/{avatar}`.

- `401` — no auth
- `400` — `group_id` missing
- `404` — caller is not a member of the group

## Dart SDK

Sole import:

```dart
import 'package:splitcore_sdk/splitcore_sdk.dart';
```

Everything under `lib/src/` is internal and no PocketBase type ever appears in
these signatures.

### Initialization

```dart
final sdk = SplitcoreSdk.initialize(
  pocketbaseUrl: 'http://host:8090',
  libraryPath: 'libsplitcore.so',   // bare soname on mobile; absolute path on desktop
  authStore: asyncAuthStore,        // optional — omit and sessions die on restart
);
```

All sub-APIs share one `PocketBase` client, so signing in on `sdk.auth`
authenticates everything else. Every request carries a 15-second timeout.

### `sdk.auth`

| Member | |
|---|---|
| `AppUser? get currentUser` | from the (possibly restored) auth store; synchronous |
| `Future<AppUser> signUp({email, password})` | creates the account, then signs in |
| `Future<AppUser> signIn({email, password})` | |
| `Future<AppUser> updateProfile({name, avatarBytes, avatarFilename})` | both optional; refreshes the session after |
| `Future<AppUser?> tryRefresh()` | `null` means "treat as signed out" — clears the store on failure |
| `void signOut()` | |

### `sdk.groups`

| Member | |
|---|---|
| `Future<Group> createGroup({name, currency, isDirect = false})` | `owner` and `version` are set server-side |
| `Future<List<Group>> listMyGroups()` | |
| `Future<Group> getGroup(String id)` | fetch the current `version` before settling |
| `Future<List<GroupMember>> listMembers(String groupId)` | via `/api/splitcore/members` |
| `Future<GroupMember> addMember({groupId, userId, role})` | direct row create; needs a known user id |
| `Future<void> removeMember(String memberId)` | |
| `Future<bool> inviteOrAddMember({groupId, email, role})` | `true` = added now, `false` = invite pending |

### `sdk.expenses`

| Member | |
|---|---|
| `Future<Expense> createExpense({groupId, payerMemberId, description, date, split})` | computes splits locally first, then writes the expense and one `split_entries` row per member |
| `Future<List<Expense>> listExpenses(String groupId)` | newest first |
| `Future<List<SplitEntry>> listSplitEntries(String expenseId)` | |
| `Future<void> deleteExpense(String expenseId)` | split entries cascade |
| `Future<SplitEntry> attachReceipt(String entryId, Uint8List bytes)` | compresses, then uploads |
| `String? receiptUrl(SplitEntry entry)` | `null` when no receipt |

### `sdk.settlements`

| Member | |
|---|---|
| `Future<Settlement> createSettlement({groupId, localVersion, fromMemberId, toMemberId, amountCents, note})` | staleness-checks first; silently resyncs if stale, then writes |
| `Future<List<Settlement>> listSettlements(String groupId)` | newest first |

No update or delete. Settlements are a reimbursement log.

### `sdk.balances`

| Member | |
|---|---|
| `Future<List<Balance>> getBalances(String groupId)` | reads the server's cache; never recomputes |

### Top-level compute

| Member | |
|---|---|
| `Future<List<Transfer>> settleUp(List<Balance>)` | minimal transfer set to zero everything out |
| `Future<List<Split>> previewSplit(SplitSpec)` | the split `createExpense` would compute, without writing — for live UI preview |

Both hop to a fresh isolate internally.

### Models

`AppUser`, `Group`, `GroupMember`, `Expense`, `SplitEntry`, `Settlement`,
`Balance`, `Transfer`, `Split`, `SplitSpec`, `ExpenseInput`, `SettlementInput`,
`StalenessResult`, `SplitcoreException`.

`SplitSpec` has four constructors matching the four split types:

```dart
SplitSpec.equal(totalCents: 10000, memberIds: [...])
SplitSpec.exact(totalCents: 10000, entries: [...])    // must sum to the total
SplitSpec.percent(totalCents: 10000, entries: [...])  // basis points, must sum to 10000
SplitSpec.shares(totalCents: 10000, entries: [...])   // positive integers
```

Errors from the Go side surface as `SplitcoreException`. Balance sign convention
is the same everywhere: **positive means owed money, negative means owes.**

## Go — `splitcore`

Importable directly (`github.com/abdulroufsidhu/slice_pay/splitcore/...`). All
amounts `int64` minor units.

```go
// money
ComputeEqualSplit(totalCents int64, memberIDs []string) ([]Split, error)
ComputeExactSplit(totalCents int64, entries []ExactEntry) ([]Split, error)
ComputePercentSplit(totalCents int64, entries []PercentEntry) ([]Split, error)
ComputeShareSplit(totalCents int64, entries []ShareEntry) ([]Split, error)

// settle
SimplifyDebts(balances []Balance) ([]Transfer, error)

// balance
ComputeBalances(expenses []Expense, settlements []Settlement) ([]settle.Balance, error)
```

Enforced invariants: `sum(splits) == total` for every split function;
`sum(balances) == 0` for every balance result; applying `SimplifyDebts`'s
transfers zeroes every balance in at most n−1 transfers; identical input order
always produces identical output.

Rejected: non-positive totals, empty member lists, duplicate member ids,
non-positive shares, basis points not summing to 10000, exact entries not
summing to the total, negative amounts, and any arithmetic that would overflow
`int64`.

## C — `libsplitcore`

```c
char* SplitcoreComputeSplits(const char* requestJson);
char* SplitcoreSimplifyDebts(const char* requestJson);
char* SplitcoreComputeBalances(const char* requestJson);
void  SplitcoreFree(char* ptr);
```

Every returned pointer is malloc'd and **must** be released with
`SplitcoreFree`. Errors come back as `{"error": "..."}` — a NULL request or an
internal panic is converted to that shape rather than crossing the boundary.
