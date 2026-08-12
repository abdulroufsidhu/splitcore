# Splitcore SDK & Server Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the correctness, safety, and completeness gaps in `splitcore_sdk` and the server hooks that back it, so the data layer is trustworthy before the UI is built on top of it.

**Architecture:** Everything here lives in `splitcore_sdk/lib/src/remote/` and `server/hooks/`. The layering rule is unchanged and enforced harder: no PocketBase type crosses out of `remote/`, and the app never imports `package:pocketbase`. Money math stays in the Go engine — no task here computes an amount in Dart.

**Tech Stack:** Dart 3.9 (`splitcore_sdk`), PocketBase Dart client 0.22, Go 1.26.4 + PocketBase 0.39 (server hooks), `dart test` against a real PocketBase subprocess (`test/support/pb_server.dart`).

## Global Constraints

- **Prerequisite:** `2026-08-04-splitcore-foundation.md` Tasks 1-3 must be done. Go imports are `github.com/abdulroufsidhu/splitcore/...`, and `make native` produces `splitcore/build/out/linux/libsplitcore.so`, which every FFI test resolves by path.
- All money is `int64` minor units. Never a `double`.
- No PocketBase type (`PocketBase`, `RecordModel`, `AuthStore`, `ClientException`) may appear in `splitcore_sdk/lib/splitcore_sdk.dart`'s exports or anywhere under `app/lib/`.
- Every new public SDK method is exported through `splitcore_sdk/lib/splitcore_sdk.dart` — nothing under `lib/src/` is imported directly by the app.
- Tests run against the real server via `PbTestServer.start()`. No mocks for wire behavior.
- Run `make check` before every commit step.
- Dart formatting: `dart format --line-length 100`.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `splitcore_sdk/lib/src/remote/filters.dart` | Building parameterized PocketBase filter expressions | **new** |
| `splitcore_sdk/lib/src/models.dart` | Domain models + `Page<T>` | modify |
| `splitcore_sdk/lib/src/remote/expenses_api.dart` | Expenses + split entries: paged listing, atomic create, edit | modify |
| `splitcore_sdk/lib/src/remote/settlements_api.dart` | Settlements: paged listing, parameterized resync | modify |
| `splitcore_sdk/lib/src/remote/balances_api.dart` | Balances read | modify |
| `splitcore_sdk/lib/src/remote/auth_api.dart` | Auth: dedup refresh, password reset, verification, deletion | modify |
| `splitcore_sdk/lib/src/remote/token_store.dart` | Platform-agnostic token persistence interface | **new** |
| `splitcore_sdk/lib/src/remote/export_api.dart` | Group export to CSV | **new** |
| `server/hooks/account.go` | Account deletion: membership cleanup + balance guard | **new** |

---

### Task 1: Parameterize every PocketBase filter

**Files:**
- Create: `splitcore_sdk/lib/src/remote/filters.dart`
- Create: `splitcore_sdk/test/remote/filters_test.dart`
- Modify: `splitcore_sdk/lib/src/remote/expenses_api.dart:56,63`
- Modify: `splitcore_sdk/lib/src/remote/settlements_api.dart:51,58,64,79`
- Modify: `splitcore_sdk/lib/src/remote/balances_api.dart:15`

**Interfaces:**
- Consumes: nothing.
- Produces: `String byGroup(PocketBase pb, String groupId)` and `String byExpense(PocketBase pb, String expenseId)` in `filters.dart`. Later tasks build every filter through these or through `pb.filter(...)` directly — never string interpolation.

**The bug:** every list call interpolates the id straight into the filter expression, e.g. `filter: "group = '$groupId'"`. PocketBase's filter language is not SQL, so this is not SQL injection — but it *is* filter injection: an id containing `'` terminates the literal and the rest is parsed as filter syntax. Today all ids are server-issued so nothing is exploitable; the moment any user-controlled value reaches a filter (Task 2 adds search, which is exactly that), it becomes a live vulnerability. The PocketBase Dart client already ships the fix: `pb.filter('group = {:g}', {'g': groupId})` binds and escapes.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/filters_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/filters.dart';
import 'package:test/test.dart';

void main() {
  final pb = PocketBase('http://127.0.0.1:1');

  test('byGroup binds the id instead of interpolating it', () {
    expect(byGroup(pb, 'abc123'), "group = 'abc123'");
  });

  test('a quote in the id cannot escape the literal', () {
    // Interpolation would produce  group = 'x' || id != ''  — a filter that
    // matches every row the caller may read. Binding must keep it a literal.
    final injected = byGroup(pb, r"x' || id != '");
    expect(injected.contains('||'), isFalse, reason: 'filter injection: $injected');
  });

  test('byExpense binds the same way', () {
    expect(byExpense(pb, 'exp1'), "expense = 'exp1'");
    expect(byExpense(pb, r"x' || id != '").contains('||'), isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/filters_test.dart`
Expected: FAIL — `Error: Couldn't resolve ... filters.dart` (the file does not exist).

- [ ] **Step 3: Write the implementation**

Create `splitcore_sdk/lib/src/remote/filters.dart`:

```dart
// Every PocketBase filter in this package is built here. Interpolating a
// value into a filter string lets a quote in that value terminate the
// literal and inject filter syntax — pb.filter() binds and escapes
// instead. There is no "the id is trusted" exception: the point of
// funnelling every filter through one place is that no future caller has
// to remember which values are trusted.
import 'package:pocketbase/pocketbase.dart';

/// Rows belonging to [groupId].
String byGroup(PocketBase pb, String groupId) => pb.filter('group = {:g}', {'g': groupId});

/// Split entries belonging to [expenseId].
String byExpense(PocketBase pb, String expenseId) =>
    pb.filter('expense = {:e}', {'e': expenseId});
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/filters_test.dart`
Expected: `+3: All tests passed!`

- [ ] **Step 5: Replace every interpolated filter**

In `splitcore_sdk/lib/src/remote/expenses_api.dart`, add the import:

```dart
import 'filters.dart';
```

then replace the two filters:

```dart
        .getFullList(filter: "group = '$groupId'", sort: '-date');
```
→
```dart
        .getFullList(filter: byGroup(_pb, groupId), sort: '-date');
```

```dart
        .getFullList(filter: "expense = '$expenseId'");
```
→
```dart
        .getFullList(filter: byExpense(_pb, expenseId));
```

In `splitcore_sdk/lib/src/remote/settlements_api.dart`, add the same import and replace all four:

```dart
        .getFullList(filter: "group = '$groupId'", sort: '-date');   → byGroup(_pb, groupId)
        .getFullList(filter: "group = '$groupId'");                  → byGroup(_pb, groupId)
        .getFullList(filter: "expense = '${expense.id}'");            → byExpense(_pb, expense.id)
        .getFullList(filter: "group = '$groupId'");                  → byGroup(_pb, groupId)
```

In `splitcore_sdk/lib/src/remote/balances_api.dart`, add the import and replace:

```dart
    final records = await _pb.collection('balances').getFullList(filter: "group = '$groupId'");
```
→
```dart
    final records = await _pb.collection('balances').getFullList(filter: byGroup(_pb, groupId));
```

- [ ] **Step 6: Verify no interpolated filter survives**

Run:
```bash
cd /home/abdul/Projects/slice_pay
grep -rn "filter: \"" splitcore_sdk/lib | grep '\$'
```
Expected: no output.

- [ ] **Step 7: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all tests pass — the existing expenses/settlements/balances tests prove the rewritten filters still match the same rows.

- [ ] **Step 8: Commit**

```bash
git add splitcore_sdk/lib/src/remote/filters.dart splitcore_sdk/test/remote/filters_test.dart \
        splitcore_sdk/lib/src/remote/expenses_api.dart \
        splitcore_sdk/lib/src/remote/settlements_api.dart \
        splitcore_sdk/lib/src/remote/balances_api.dart
git commit -m "fix(sdk): bind PocketBase filter parameters instead of interpolating

Every list call built its filter by interpolating an id into the filter
expression, so a quote in the value could terminate the literal and inject
filter syntax. Not exploitable with server-issued ids, but search (next
task) puts user input on that exact path."
```

---

### Task 2: Paginated and searchable listings

**Files:**
- Modify: `splitcore_sdk/lib/src/models.dart` (append `Page<T>`)
- Modify: `splitcore_sdk/lib/src/remote/expenses_api.dart` (`listExpenses`, new `searchExpenses`, new `listAllExpenses`)
- Modify: `splitcore_sdk/lib/src/remote/settlements_api.dart` (`listSettlements`, `_resync`)
- Modify: `splitcore_sdk/lib/splitcore_sdk.dart` (export `Page`)
- Create: `splitcore_sdk/test/remote/pagination_test.dart`
- Modify: `splitcore_sdk/test/remote/expenses_api_test.dart` (the `listExpenses` test now reads `.items`)

**Interfaces:**
- Consumes: `byGroup`/`byExpense` from Task 1.
- Produces:
  - `class Page<T> { final List<T> items; final int page; final int perPage; final int totalItems; final int totalPages; bool get hasMore; }`
  - `Future<Page<Expense>> ExpensesApi.listExpenses(String groupId, {int page = 1, int perPage = 50})`
  - `Future<Page<Expense>> ExpensesApi.searchExpenses(String groupId, String query, {int page = 1, int perPage = 50})`
  - `Future<List<Expense>> ExpensesApi.listAllExpenses(String groupId)`
  - `Future<Page<Settlement>> SettlementsApi.listSettlements(String groupId, {int page = 1, int perPage = 50})`
  - `Future<List<Settlement>> SettlementsApi.listAllSettlements(String groupId)`

**The bug:** every listing calls `getFullList`, which walks every page and materializes the entire collection. A group with 5,000 expenses transfers all 5,000 rows to render one screen. `Page<T>` is the fix; `listAll*` stays for the two places that genuinely need everything (balance resync and export), where the set is bounded by what the math requires.

**Breaking change:** `listExpenses` and `listSettlements` change return type from `List<T>` to `Page<T>`. Both are called from `app/lib/` — those call sites are updated in the app plan, but Step 8 here keeps them compiling.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/pagination_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember owner;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final user = await auth.signUp(
      email: 'pager-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Paging', currency: 'USD');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == user.id);

    for (var i = 0; i < 7; i++) {
      await expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: owner.id,
        description: 'Expense $i',
        date: DateTime.utc(2026, 7, i + 1),
        split: SplitSpec.equal(totalCents: 100 * (i + 1), memberIds: [owner.id]),
      );
    }
  });

  test('listExpenses returns one page, newest first, with total metadata', () async {
    final first = await expensesApi.listExpenses(group.id, perPage: 3);

    expect(first.items.length, 3);
    expect(first.items.map((e) => e.description), ['Expense 6', 'Expense 5', 'Expense 4']);
    expect(first.page, 1);
    expect(first.totalItems, 7);
    expect(first.totalPages, 3);
    expect(first.hasMore, isTrue);
  });

  test('the last page reports no more pages', () async {
    final last = await expensesApi.listExpenses(group.id, page: 3, perPage: 3);

    expect(last.items.length, 1);
    expect(last.items.single.description, 'Expense 0');
    expect(last.hasMore, isFalse);
  });

  test('listAllExpenses still returns every row for balance math', () async {
    final all = await expensesApi.listAllExpenses(group.id);
    expect(all.length, 7);
  });

  test('searchExpenses matches on description, case-insensitively', () async {
    final hits = await expensesApi.searchExpenses(group.id, 'expense 3');

    expect(hits.items.length, 1);
    expect(hits.items.single.description, 'Expense 3');
  });

  test('a search term with filter syntax matches nothing instead of everything', () async {
    // Unbound, this term would close the literal and OR in a match-all
    // clause. Bound, it is just a description nothing has.
    final hits = await expensesApi.searchExpenses(group.id, r"x' || id != '");

    expect(hits.items, isEmpty);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/pagination_test.dart`
Expected: FAIL — `The named parameter 'perPage' isn't defined` and `The method 'searchExpenses' isn't defined`.

- [ ] **Step 3: Add the `Page<T>` model**

Append to `splitcore_sdk/lib/src/models.dart`:

```dart
/// One page of a listing, with enough metadata for a UI to decide whether
/// to fetch the next one. Returned instead of a bare List so a caller
/// physically cannot ask for "all rows" by accident.
class Page<T> {
  const Page({
    required this.items,
    required this.page,
    required this.perPage,
    required this.totalItems,
    required this.totalPages,
  });

  final List<T> items;
  final int page;
  final int perPage;
  final int totalItems;
  final int totalPages;

  bool get hasMore => page < totalPages;

  /// Convenience for the empty case — a group with no expenses yet.
  static Page<T> empty<T>({int perPage = 50}) =>
      Page<T>(items: const [], page: 1, perPage: perPage, totalItems: 0, totalPages: 0);
}
```

- [ ] **Step 4: Implement paging and search in ExpensesApi**

In `splitcore_sdk/lib/src/remote/expenses_api.dart`, replace the whole `listExpenses` method:

```dart
  /// A group's expenses, newest first — powers the group-detail expense list.
  Future<List<Expense>> listExpenses(String groupId) async {
    final records = await _pb
        .collection('expenses')
        .getFullList(filter: byGroup(_pb, groupId), sort: '-date');
    return [for (final r in records) _expenseFromRecord(r)];
  }
```

with:

```dart
  /// One page of a group's expenses, newest first — powers the group-detail
  /// list. Paged rather than exhaustive: an active group accumulates
  /// thousands of expenses and a screen shows a dozen.
  Future<Page<Expense>> listExpenses(
    String groupId, {
    int page = 1,
    int perPage = 50,
  }) async {
    final result = await _pb.collection('expenses').getList(
          page: page,
          perPage: perPage,
          filter: byGroup(_pb, groupId),
          sort: '-date',
        );
    return _pageFrom(result);
  }

  /// Expenses in [groupId] whose description contains [query]
  /// (case-insensitive — PocketBase's `~` operator). An empty [query]
  /// degrades to a plain listing rather than matching everything twice.
  Future<Page<Expense>> searchExpenses(
    String groupId,
    String query, {
    int page = 1,
    int perPage = 50,
  }) async {
    if (query.trim().isEmpty) return listExpenses(groupId, page: page, perPage: perPage);
    final result = await _pb.collection('expenses').getList(
          page: page,
          perPage: perPage,
          // query is user input — it MUST go through pb.filter, never into
          // the expression by interpolation.
          filter: _pb.filter('group = {:g} && description ~ {:q}', {'g': groupId, 'q': query}),
          sort: '-date',
        );
    return _pageFrom(result);
  }

  /// Every expense in the group. Only for callers that genuinely need the
  /// full set — balance recomputation and export — never for rendering.
  Future<List<Expense>> listAllExpenses(String groupId) async {
    final records = await _pb
        .collection('expenses')
        .getFullList(batch: 200, filter: byGroup(_pb, groupId), sort: '-date');
    return [for (final r in records) _expenseFromRecord(r)];
  }

  Page<Expense> _pageFrom(ResultList<RecordModel> result) => Page<Expense>(
        items: [for (final r in result.items) _expenseFromRecord(r)],
        page: result.page,
        perPage: result.perPage,
        totalItems: result.totalItems,
        totalPages: result.totalPages,
      );
```

- [ ] **Step 5: Run the pagination tests**

Run: `cd splitcore_sdk && dart test test/remote/pagination_test.dart`
Expected: `+5: All tests passed!`

- [ ] **Step 6: Do the same for settlements**

In `splitcore_sdk/lib/src/remote/settlements_api.dart`, replace `listSettlements`:

```dart
  /// One page of a group's settlements, newest first — powers per-group and
  /// global activity history alongside [ExpensesApi.listExpenses].
  Future<Page<Settlement>> listSettlements(
    String groupId, {
    int page = 1,
    int perPage = 50,
  }) async {
    final result = await _pb.collection('settlements').getList(
          page: page,
          perPage: perPage,
          filter: byGroup(_pb, groupId),
          sort: '-date',
        );
    return Page<Settlement>(
      items: [for (final r in result.items) _settlementFromRecord(r)],
      page: result.page,
      perPage: result.perPage,
      totalItems: result.totalItems,
      totalPages: result.totalPages,
    );
  }

  /// Every settlement in the group — for balance recomputation and export.
  Future<List<Settlement>> listAllSettlements(String groupId) async {
    final records = await _pb
        .collection('settlements')
        .getFullList(batch: 200, filter: byGroup(_pb, groupId), sort: '-date');
    return [for (final r in records) _settlementFromRecord(r)];
  }
```

`_resync` in the same file already uses `getFullList` directly against the
collection and is correct as-is — it needs the complete set to recompute
balances. Add `batch: 200` to each of its three `getFullList` calls so a
large group resyncs in bounded chunks:

```dart
        .getFullList(batch: 200, filter: byGroup(_pb, groupId));
```

- [ ] **Step 7: Export `Page`**

In `splitcore_sdk/lib/splitcore_sdk.dart`, add `Page,` to the `models.dart`
export list, alphabetically between `GroupMember,` and `PercentSplitEntry,`:

```dart
        GroupMember,
        Page,
        PercentSplitEntry,
```

- [ ] **Step 8: Fix the existing test that assumed a List**

In `splitcore_sdk/test/remote/expenses_api_test.dart`, the `listExpenses returns a group's expenses newest first` test ends with:

```dart
    final expenses = await expensesApi.listExpenses(group.id);

    expect(expenses.map((e) => e.id), [second.id, first.id]);
```

Change to:

```dart
    final expenses = await expensesApi.listExpenses(group.id);

    expect(expenses.items.map((e) => e.id), [second.id, first.id]);
    expect(expenses.totalItems, 2);
```

- [ ] **Step 9: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all pass. Any other compile error points at a caller of the old
`List` return — fix it to read `.items`.

- [ ] **Step 10: Commit**

```bash
git add splitcore_sdk/lib splitcore_sdk/test
git commit -m "feat(sdk): paginate expense and settlement listings, add search

getFullList transferred an entire collection to render one screen.
listExpenses/listSettlements now return Page<T>; listAllExpenses and
listAllSettlements remain for balance recompute and export, which need the
full set. Search binds the user's query through pb.filter."
```

---

### Task 3: Make expense creation atomic

**Files:**
- Modify: `splitcore_sdk/lib/src/remote/expenses_api.dart:19-51` (`createExpense`)
- Create: `splitcore_sdk/test/remote/expense_atomicity_test.dart`

**Interfaces:**
- Consumes: `SplitcoreCalc.computeSplits` (unchanged).
- Produces: `createExpense` with the same signature, now all-or-nothing.

**The bug:** `createExpense` writes the `expenses` row, then loops writing `split_entries` one at a time. If the third of four writes fails — dropped connection, server restart, rule rejection — the expense row and two orphan split entries are left behind permanently. The server's incomplete-expense rule (`server/hooks/recompute.go`: skip any expense whose splits do not sum to the total) means balances stay *correct*, which is why this has never been noticed: instead it manifests as a ghost expense that appears in the list, is never counted, and can only be cleared by hand.

The fix is a compensating delete: on any failure, delete the expense row. Its `split_entries` cascade with it (`split_entries.expense` is a `CascadeDelete: true` relation), so one delete cleans up everything.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/expense_atomicity_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember owner;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final user = await auth.signUp(
      email: 'atomic-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Atomic', currency: 'USD');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == user.id);
  });

  test('a split entry write failure leaves no orphan expense behind', () async {
    // A member id from no group at all: the expense row is accepted (its
    // own payer is valid) but the server's split_entries validation
    // rejects "member must belong to the expense's group" partway through.
    final before = await expensesApi.listAllExpenses(group.id);

    await expectLater(
      expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: owner.id,
        description: 'Doomed',
        date: DateTime.utc(2026, 7, 9),
        split: SplitSpec.exact(
          totalCents: 1000,
          entries: [
            ExactSplitEntry(memberId: owner.id, amountCents: 500),
            const ExactSplitEntry(memberId: 'nonexistentmember', amountCents: 500),
          ],
        ),
      ),
      throwsA(anything),
    );

    final after = await expensesApi.listAllExpenses(group.id);
    expect(after.length, before.length, reason: 'orphan expense row survived a failed create');
    expect(after.any((e) => e.description == 'Doomed'), isFalse);
  });

  test('a successful create still writes the expense and all its splits', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Fine',
      date: DateTime.utc(2026, 7, 10),
      split: SplitSpec.equal(totalCents: 900, memberIds: [owner.id]),
    );

    final entries = await expensesApi.listSplitEntries(expense.id);
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 900);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/expense_atomicity_test.dart`
Expected: the first test FAILS on `orphan expense row survived a failed create` — `after.length` is one greater than `before.length`. The second test passes already.

If `SplitSpec.exact` has a different constructor shape in `models.dart`, match the real one; the test only needs a split whose second entry references a member outside the group.

- [ ] **Step 3: Make the create compensating**

In `splitcore_sdk/lib/src/remote/expenses_api.dart`, replace the body of `createExpense` after the `expenseRecord` creation:

```dart
    for (final s in splits) {
      await _pb.collection('split_entries').create(
        body: {
          'expense': expenseRecord.id,
          'member': s.memberId,
          'amount_cents': s.amountCents,
        },
      );
    }

    return _expenseFromRecord(expenseRecord);
```

with:

```dart
    // PocketBase gives the client no multi-record transaction, so an
    // expense and its split entries cannot be written in one shot. Without
    // compensation, a failure partway through the loop leaves an expense
    // whose splits do not sum to its total — the server then permanently
    // skips it during balance recompute (see server/hooks/recompute.go),
    // so it shows in the list, counts for nothing, and can only be removed
    // by hand. Deleting the parent unwinds the whole write: split_entries
    // cascade off expenses.
    try {
      for (final s in splits) {
        await _pb.collection('split_entries').create(
          body: {
            'expense': expenseRecord.id,
            'member': s.memberId,
            'amount_cents': s.amountCents,
          },
        );
      }
    } catch (_) {
      // Best-effort: if the rollback itself fails (server unreachable),
      // rethrow the original failure — it is the one the caller can act on.
      try {
        await _pb.collection('expenses').delete(expenseRecord.id);
      } catch (_) {}
      rethrow;
    }

    return _expenseFromRecord(expenseRecord);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/expense_atomicity_test.dart`
Expected: `+2: All tests passed!`

- [ ] **Step 5: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add splitcore_sdk/lib/src/remote/expenses_api.dart \
        splitcore_sdk/test/remote/expense_atomicity_test.dart
git commit -m "fix(sdk): roll back the expense row when a split entry write fails

A partial create left an expense whose splits did not sum to its total.
The server skips such an expense in every balance recompute, so it stayed
visible, uncounted, and unclearable. split_entries cascade off expenses,
so deleting the parent unwinds the whole write."
```

---

### Task 4: Expense editing

**Files:**
- Modify: `splitcore_sdk/lib/src/remote/expenses_api.dart` (new `updateExpense`)
- Create: `splitcore_sdk/test/remote/expense_update_test.dart`

**Interfaces:**
- Consumes: `SplitcoreCalc.computeSplits`, `listSplitEntries`.
- Produces: `Future<Expense> updateExpense({required String expenseId, required String payerMemberId, required String description, required DateTime date, required SplitSpec split})` — the app's edit screen calls exactly this.

**Why the server needs no change:** `server/hooks/hooks.go` already binds `OnRecordUpdate` for `expenses` and `split_entries` to the same validation + recompute path as create, and `rejectGroupReparent` already forbids moving an expense between groups. Editing is a client-side gap only.

**Ordering matters:** write the new split entries *before* deleting the old ones and the amount would double-count mid-flight; delete first and the expense is transiently incomplete. Transiently incomplete is the safe state — the server skips incomplete expenses during recompute, so balances never show a wrong number, they briefly omit this expense. That is the same window `createExpense` already has.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/expense_update_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/balances_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late ExpensesApi expensesApi;
  late BalancesApi balancesApi;
  late Group group;
  late GroupMember owner;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));
    balancesApi = BalancesApi(pb);

    final ownerUser = await auth.signUp(
      email: 'editor-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Editing', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'editee-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == ownerUser.id);
  });

  test('updateExpense rewrites fields, replaces splits, and leaves no stale entries', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    final updated = await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: other.id,
      description: 'Dinner (corrected)',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [owner.id, other.id]),
    );

    expect(updated.id, created.id);
    expect(updated.description, 'Dinner (corrected)');
    expect(updated.amountCents, 3000);
    expect(updated.payerMemberId, other.id);

    final entries = await expensesApi.listSplitEntries(created.id);
    expect(entries.length, 2, reason: 'old split entries were not replaced');
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 3000);
  });

  test('balances reflect the edit, not the original amount', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Taxi',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: owner.id,
      description: 'Taxi',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [owner.id, other.id]),
    );

    final balances = await balancesApi.listBalances(group.id);
    final ownerNet = balances.firstWhere((b) => b.memberId == owner.id).netCents;
    // Owner paid 4000, owes 2000 of it: net +2000. If the old 1000 expense
    // still counted, this would be 2500.
    expect(ownerNet, 2000);
  });

  test('changing the split shape from equal to exact is honored', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 7, 4),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: owner.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 7, 4),
      split: SplitSpec.exact(
        totalCents: 1000,
        entries: [
          ExactSplitEntry(memberId: owner.id, amountCents: 250),
          ExactSplitEntry(memberId: other.id, amountCents: 750),
        ],
      ),
    );

    final entries = await expensesApi.listSplitEntries(created.id);
    final byMember = {for (final e in entries) e.memberId: e.amountCents};
    expect(byMember[owner.id], 250);
    expect(byMember[other.id], 750);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/expense_update_test.dart`
Expected: FAIL — `The method 'updateExpense' isn't defined for the class 'ExpensesApi'`.

- [ ] **Step 3: Implement updateExpense**

Add to `splitcore_sdk/lib/src/remote/expenses_api.dart`, directly after `createExpense`:

```dart
  /// Rewrites an existing expense and replaces its split entries wholesale.
  ///
  /// The group is never changed — the server rejects re-parenting outright
  /// (`server/hooks/hooks.go`, rejectGroupReparent), because moving an
  /// expense between groups would leave the old group's cached balances
  /// stale.
  ///
  /// Old entries are deleted before new ones are written. Between the two,
  /// the expense's splits do not sum to its total, so the server's
  /// recompute skips it entirely (see the incomplete-expense rule in
  /// server/README.md) — balances briefly omit this expense rather than
  /// ever counting it twice.
  Future<Expense> updateExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    // Compute before touching anything: a rejected SplitSpec should fail
    // without having modified the stored expense at all.
    final splits = await _calc.computeSplits(split);

    final existing = await _pb.collection('split_entries').getFullList(
          batch: 200,
          filter: byExpense(_pb, expenseId),
        );

    final record = await _pb.collection('expenses').update(
      expenseId,
      body: {
        'payer': payerMemberId,
        'description': description,
        'amount_cents': split.totalCents,
        'split_type': split.type,
        'date': date.toIso8601String(),
      },
    );

    for (final entry in existing) {
      await _pb.collection('split_entries').delete(entry.id);
    }
    for (final s in splits) {
      await _pb.collection('split_entries').create(
        body: {
          'expense': expenseId,
          'member': s.memberId,
          'amount_cents': s.amountCents,
        },
      );
    }

    return _expenseFromRecord(record);
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/expense_update_test.dart`
Expected: `+3: All tests passed!`

- [ ] **Step 5: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add splitcore_sdk/lib/src/remote/expenses_api.dart \
        splitcore_sdk/test/remote/expense_update_test.dart
git commit -m "feat(sdk): add updateExpense

The server already validated and recomputed on expense/split updates; only
the client method was missing. Splits are replaced wholesale, so changing
the split shape (equal to exact, different members) works."
```

---

### Task 5: Deduplicate concurrent session refreshes

**Files:**
- Modify: `splitcore_sdk/lib/src/remote/auth_api.dart:62-70` (`tryRefresh`)
- Create: `splitcore_sdk/test/remote/auth_refresh_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `tryRefresh()` unchanged in signature, now collapsing concurrent calls onto one in-flight request.

**The bug:** `app/lib/main.dart` calls `_refreshSession()` at startup *and* on every `AppLifecycleState.resumed`. Launching the app fires both nearly simultaneously; a quick background/foreground does the same. Two concurrent `authRefresh()` calls race to write `authStore`, and if either fails, its `catch` clears the store — signing the user out while the other refresh is still in flight and about to succeed. The single-flight future is the fix: the second caller awaits the first's result.

Everything else the review asked for here is already handled and needs no change: the `catch (_)` covers offline and invalid sessions alike, `record == null` short-circuits when there is no session, and the app already refreshes on resume rather than waiting for a 401.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/auth_refresh_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test('concurrent refreshes resolve to the same user and keep the session', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final user = await auth.signUp(
      email: 'refresh-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );

    // Startup refresh and a resume refresh landing at the same moment.
    final results = await Future.wait([
      auth.tryRefresh(),
      auth.tryRefresh(),
      auth.tryRefresh(),
    ]);

    expect(results.every((u) => u?.id == user.id), isTrue,
        reason: 'a concurrent refresh returned null: $results');
    expect(auth.currentUser, isNotNull, reason: 'the session was cleared by a racing refresh');
  });

  test('a refresh after sign-out returns null without throwing', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    await auth.signUp(
      email: 'signedout-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    auth.signOut();

    expect(await auth.tryRefresh(), isNull);
  });

  test('a refresh against an unreachable server clears the session and returns null', () async {
    // Port 1 refuses instantly — the offline path without a real timeout wait.
    final pb = PocketBase('http://127.0.0.1:1');
    final auth = AuthApi(pb);

    // Seed a syntactically valid session so tryRefresh gets past its null check.
    final live = PocketBase(server.baseUrl);
    final liveAuth = AuthApi(live);
    await liveAuth.signUp(
      email: 'offline-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    pb.authStore.save(live.authStore.token, live.authStore.record);

    expect(await auth.tryRefresh(), isNull);
    expect(auth.currentUser, isNull);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/auth_refresh_test.dart`
Expected: the first test FAILS — at least one concurrent refresh returns null, and/or `currentUser` is null after the batch. (It is a race, so if it passes on the first run, run it 10 times: `dart test test/remote/auth_refresh_test.dart --total-shards=1 -j1 --repeat=10`. Confirm the failure before implementing.)

- [ ] **Step 3: Implement single-flight refresh**

In `splitcore_sdk/lib/src/remote/auth_api.dart`, add the field to `AuthApi`:

```dart
  final PocketBase _pb;

  /// The refresh currently in flight, if any. The app refreshes both at
  /// startup and on every resume, so two refreshes routinely overlap; two
  /// concurrent authRefresh calls race to write authStore, and a failure
  /// in either one's catch would clear the session out from under the
  /// other. Collapsing them onto one future removes the race entirely.
  Future<AppUser?>? _inFlightRefresh;
```

and replace `tryRefresh`:

```dart
  /// Refreshes the current session's token (call on app resume/start so a
  /// long-backgrounded token doesn't sit expired). Returns the refreshed
  /// user, or null if there's no session to refresh or the refresh failed
  /// (e.g. the token already expired, or the device is offline) — callers
  /// should treat null as "signed out".
  ///
  /// Concurrent calls share one request: the second caller awaits the
  /// first's result rather than issuing its own.
  Future<AppUser?> tryRefresh() {
    if (_pb.authStore.record == null) return Future.value(null);
    return _inFlightRefresh ??= _refresh().whenComplete(() => _inFlightRefresh = null);
  }

  Future<AppUser?> _refresh() async {
    try {
      final auth = await _pb.collection('users').authRefresh();
      return _userFromRecord(auth.record);
    } catch (_) {
      _pb.authStore.clear();
      return null;
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/auth_refresh_test.dart`
Expected: `+3: All tests passed!` Re-run a few times — it must be stable, not lucky.

- [ ] **Step 5: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add splitcore_sdk/lib/src/remote/auth_api.dart \
        splitcore_sdk/test/remote/auth_refresh_test.dart
git commit -m "fix(sdk): collapse concurrent session refreshes onto one request

The app refreshes at startup and on every resume, so two refreshes overlap
routinely. Both raced to write authStore, and a failure in either one's
catch cleared the session while the other was still succeeding."
```

---

### Task 6: Password reset and email verification

**Files:**
- Modify: `splitcore_sdk/lib/src/remote/auth_api.dart` (four new methods)
- Create: `splitcore_sdk/test/remote/auth_recovery_test.dart`
- Modify: `docs/deployment.md` (SMTP section)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Future<void> requestPasswordReset(String email)`
  - `Future<void> confirmPasswordReset({required String token, required String password})`
  - `Future<void> requestEmailVerification(String email)`
  - `Future<void> confirmEmailVerification(String token)`
  - `bool get isEmailVerified`

**Design note:** PocketBase implements all four flows server-side and mails the token itself. The SDK's job is only to expose them and to make the request non-enumerable — `requestPasswordReset` must not reveal whether an address has an account, so it swallows the not-found error and always resolves. Confirmation, by contrast, must surface failure: a user typing a wrong or expired token needs to be told.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/auth_recovery_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late AuthApi auth;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() {
    auth = AuthApi(PocketBase(server.baseUrl));
  });

  test('requesting a reset for a real address succeeds', () async {
    final email = 'reset-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await auth.signUp(email: email, password: 'password123');
    auth.signOut();

    // The test server has no SMTP configured, so nothing is delivered —
    // what matters is that the request is accepted and does not throw.
    await auth.requestPasswordReset(email);
  });

  test('requesting a reset for an unknown address does not reveal that it is unknown',
      () async {
    // Must not throw: a distinguishable error turns this into an account
    // enumeration oracle.
    await auth.requestPasswordReset('nobody-${DateTime.now().microsecondsSinceEpoch}@example.com');
  });

  test('confirming a reset with a bogus token fails loudly', () async {
    await expectLater(
      auth.confirmPasswordReset(token: 'not-a-real-token', password: 'newpassword123'),
      throwsA(anything),
    );
  });

  test('requesting verification for an unknown address is also silent', () async {
    await auth.requestEmailVerification('ghost-${DateTime.now().microsecondsSinceEpoch}@example.com');
  });

  test('confirming verification with a bogus token fails loudly', () async {
    await expectLater(auth.confirmEmailVerification('not-a-real-token'), throwsA(anything));
  });

  test('isEmailVerified is false for a fresh unverified signup', () async {
    await auth.signUp(
      email: 'unverified-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    expect(auth.isEmailVerified, isFalse);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/auth_recovery_test.dart`
Expected: FAIL — `The method 'requestPasswordReset' isn't defined for the class 'AuthApi'`.

- [ ] **Step 3: Implement the four flows**

Add to `splitcore_sdk/lib/src/remote/auth_api.dart`, after `signOut`:

```dart
  /// Whether the signed-in user has confirmed their email address. False
  /// when nobody is signed in.
  bool get isEmailVerified => _pb.authStore.record?.getBoolValue('verified') ?? false;

  /// Asks the server to mail a password-reset token to [email].
  ///
  /// Always resolves, even for an address with no account: a caller that
  /// could tell the two apart would have an account-enumeration oracle.
  /// The UI must therefore say "if that address has an account, check your
  /// inbox" rather than confirming the address exists.
  Future<void> requestPasswordReset(String email) async {
    try {
      await _pb.collection('users').requestPasswordReset(email);
    } catch (_) {
      // Deliberately swallowed — see above.
    }
  }

  /// Completes a reset with the token from the emailed link. Throws when
  /// the token is wrong, expired, or already used; the caller must surface
  /// that, since the user needs to know their new password did not take.
  Future<void> confirmPasswordReset({
    required String token,
    required String password,
  }) =>
      _pb.collection('users').confirmPasswordReset(token, password, password);

  /// Asks the server to mail a verification token to [email]. Silent about
  /// unknown addresses for the same reason as [requestPasswordReset].
  Future<void> requestEmailVerification(String email) async {
    try {
      await _pb.collection('users').requestVerification(email);
    } catch (_) {
      // Deliberately swallowed — see requestPasswordReset.
    }
  }

  /// Completes verification with the token from the emailed link. Throws on
  /// a bad or expired token.
  Future<void> confirmEmailVerification(String token) =>
      _pb.collection('users').confirmVerification(token);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/auth_recovery_test.dart`
Expected: `+6: All tests passed!`

- [ ] **Step 5: Document the SMTP requirement**

Append to `docs/deployment.md`:

```markdown
## Email (password reset and verification)

Password reset and email verification are PocketBase flows: the server
generates the token and mails it. **Without SMTP configured, both silently
do nothing from the user's point of view** — the SDK request succeeds and
no mail ever arrives.

Configure it in the admin UI under **Settings → Mail settings**, or set the
equivalent environment for your deployment. You need a real sender domain
with SPF/DKIM; consumer mail providers reject unauthenticated
transactional mail.

Verify end to end after configuring:

1. Sign up a throwaway account in the app.
2. Trigger "forgot password".
3. Confirm the mail arrives and the link completes the reset.

The reset and verification templates (subject, body, and the action URL
the app handles) are edited in the same settings page. The action URL must
point at a page or deep link your app can receive, not at the PocketBase
admin UI.
```

- [ ] **Step 6: Run the full SDK suite**

Run: `cd /home/abdul/Projects/slice_pay && make test-sdk`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add splitcore_sdk/lib/src/remote/auth_api.dart \
        splitcore_sdk/test/remote/auth_recovery_test.dart docs/deployment.md
git commit -m "feat(sdk): password reset and email verification

Request calls swallow not-found so they cannot be used to enumerate
accounts; confirm calls throw so a bad token is surfaced to the user.
Both need SMTP configured server-side — documented in docs/deployment.md."
```

---

### Task 7: Account deletion

**Files:**
- Create: `server/hooks/account.go`
- Create: `server/hooks/account_test.go`
- Modify: `server/hooks/hooks.go` (register the new hook in `Register`)
- Modify: `splitcore_sdk/lib/src/remote/auth_api.dart` (new `deleteAccount`)
- Create: `splitcore_sdk/test/remote/auth_deletion_test.dart`

**Interfaces:**
- Consumes: `groupIDFor`/`bumpAndRecompute` conventions from `server/hooks/`.
- Produces: `registerAccountDeletion(app core.App)` in Go; `Future<void> deleteAccount()` in `AuthApi`.

**Why this needs a server hook, not just an SDK call:** `group_members.user` is a **required relation with `CascadeDelete: false`** (`server/migrations/1751760000_init_collections.go:72`). PocketBase therefore refuses to delete any user who is still a member of any group — which is every real user. Deleting an account has to remove the memberships first.

And it must not remove them blindly: a member with a non-zero balance owes or is owed money, and deleting them silently rewrites everyone else's balances. Deletion is refused while any of the user's memberships has a non-zero balance; the user must settle up first.

- [ ] **Step 1: Write the failing test**

Create `server/hooks/account_test.go`:

```go
package hooks_test

import (
	"testing"

	"github.com/pocketbase/dbx"

	"github.com/abdulroufsidhu/splitcore/server/internal/testfix"
)

// A user with no outstanding balance can delete their account, and their
// group memberships go with it — group_members.user is a required
// non-cascading relation, so without cleanup PocketBase refuses the delete
// outright.
func TestDeleteAccountRemovesMemberships(t *testing.T) {
	app := testfix.NewTestApp(t)

	owner := testfix.NewUser(t, app, "owner@example.com")
	group := testfix.NewGroup(t, app, owner.Id, "Trip", "USD")
	member := testfix.NewUser(t, app, "member@example.com")
	testfix.AddMember(t, app, group.Id, member.Id, "member")

	if err := app.Delete(member); err != nil {
		t.Fatalf("delete user with no balance: %v", err)
	}

	rows, err := app.FindRecordsByFilter("group_members", "user = {:u}", "", 0, 0,
		dbx.Params{"u": member.Id})
	if err != nil {
		t.Fatalf("find memberships: %v", err)
	}
	if len(rows) != 0 {
		t.Fatalf("memberships remaining after account delete = %d, want 0", len(rows))
	}
}

// Deleting a user who still owes or is owed money would silently rewrite
// every other member's balance. Refuse until they settle up.
func TestDeleteAccountBlockedByOutstandingBalance(t *testing.T) {
	app := testfix.NewTestApp(t)

	owner := testfix.NewUser(t, app, "creditor@example.com")
	group := testfix.NewGroup(t, app, owner.Id, "Trip", "USD")
	debtorUser := testfix.NewUser(t, app, "debtor@example.com")
	debtor := testfix.AddMember(t, app, group.Id, debtorUser.Id, "member")
	ownerMember := testfix.MemberFor(t, app, group.Id, owner.Id)

	// Owner pays 1000, split evenly: debtor owes 500.
	testfix.NewExpense(t, app, group.Id, ownerMember.Id, 1000, map[string]int64{
		ownerMember.Id: 500,
		debtor.Id:      500,
	})

	if err := app.Delete(debtorUser); err == nil {
		t.Fatal("delete of a user with an outstanding balance succeeded, want error")
	}
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd server && go test ./hooks/ -run TestDeleteAccount -v`
Expected: FAIL — either a compile error naming the `testfix` helpers that do not exist yet, or `delete of a user with an outstanding balance succeeded`.

**If the helpers are missing:** open `server/internal/testfix/testfix.go` and use whatever it already provides. The existing `server/hooks/hooks_test.go` and `server/rules_test.go` build the same fixtures — copy their exact calls rather than inventing `NewUser`/`NewGroup`/`AddMember`/`NewExpense`/`MemberFor` names. Adjust the test above to match the real API before proceeding; do not add new helpers unless two tests need the same one.

- [ ] **Step 3: Implement the deletion hook**

Create `server/hooks/account.go`:

```go
package hooks

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// registerAccountDeletion makes deleting a `users` record possible and
// safe.
//
// Possible: group_members.user is a required relation with
// CascadeDelete=false (see migrations/1751760000_init_collections.go), so
// PocketBase refuses to delete any user who is still a member of a group —
// which is every user who has ever used the app. The memberships have to
// go first.
//
// Safe: a member with a non-zero balance owes money or is owed money.
// Deleting them drops their expenses' counterparty from the ledger and
// silently rewrites what everyone else owes. Refuse until they settle.
func registerAccountDeletion(app core.App) {
	app.OnRecordDelete("users").BindFunc(func(e *core.RecordEvent) error {
		memberships, err := e.App.FindRecordsByFilter("group_members",
			"user = {:u}", "", 0, 0, dbx.Params{"u": e.Record.Id})
		if err != nil {
			return err
		}

		// Check every membership before deleting any of them.
		for _, m := range memberships {
			bal, err := e.App.FindFirstRecordByFilter("balances",
				"group = {:g} && member = {:m}",
				dbx.Params{"g": m.GetString("group"), "m": m.Id})
			if err != nil {
				// No balances row means nothing owed either way.
				continue
			}
			if bal.GetInt("net_cents") != 0 {
				return apis.NewBadRequestError(
					"settle all outstanding balances before deleting your account", nil)
			}
		}

		// The membership deletes and the user delete must be one unit: a
		// failure after removing some memberships would leave the user
		// silently ejected from those groups but still holding an account.
		return e.App.RunInTransaction(func(txApp core.App) error {
			for _, m := range memberships {
				if err := txApp.Delete(m); err != nil {
					return err
				}
			}
			orig := e.App
			e.App = txApp
			defer func() { e.App = orig }()
			return e.Next()
		})
	})
}
```

- [ ] **Step 4: Register the hook**

In `server/hooks/hooks.go`, at the end of `Register`, add the call alongside the existing ones:

```go
	registerStaleness(app)
	registerInvite(app)
	registerInviteAcceptance(app)
	registerMembers(app)
	registerAccountDeletion(app)
```

- [ ] **Step 5: Run the Go test to verify it passes**

Run: `cd server && go test ./hooks/ -run TestDeleteAccount -v`
Expected: both tests PASS.

- [ ] **Step 6: Add the SDK method with its own test**

Add to `splitcore_sdk/lib/src/remote/auth_api.dart`, after `signOut`:

```dart
  /// Permanently deletes the signed-in user's account and clears the local
  /// session.
  ///
  /// The server refuses while any of the user's groups still shows a
  /// non-zero balance for them (see server/hooks/account.go) — that error
  /// is surfaced, not swallowed, because the user has to go settle up
  /// before this can succeed.
  Future<void> deleteAccount() async {
    final id = _pb.authStore.record?.id;
    if (id == null) return;
    await _pb.collection('users').delete(id);
    _pb.authStore.clear();
  }
```

Create `splitcore_sdk/test/remote/auth_deletion_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test('deleteAccount removes the account and clears the session', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groups = GroupsApi(pb);
    await auth.signUp(
      email: 'goodbye-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    // An owner membership exists from group creation — the hook must clear
    // it, or PocketBase refuses the delete.
    await groups.createGroup(name: 'Solo', currency: 'USD');

    await auth.deleteAccount();

    expect(auth.currentUser, isNull);
  });

  test('deleteAccount with no session is a no-op', () async {
    final auth = AuthApi(PocketBase(server.baseUrl));
    await auth.deleteAccount();
    expect(auth.currentUser, isNull);
  });
}
```

- [ ] **Step 7: Run the SDK deletion test**

Run: `cd splitcore_sdk && dart test test/remote/auth_deletion_test.dart`
Expected: `+2: All tests passed!`

- [ ] **Step 8: Run everything**

Run: `cd /home/abdul/Projects/slice_pay && make check`
Expected: exits 0.

- [ ] **Step 9: Commit**

```bash
git add server/hooks/account.go server/hooks/account_test.go server/hooks/hooks.go \
        splitcore_sdk/lib/src/remote/auth_api.dart \
        splitcore_sdk/test/remote/auth_deletion_test.dart
git commit -m "feat: account deletion with membership cleanup and balance guard

group_members.user is a required non-cascading relation, so PocketBase
refused to delete any user who had ever joined a group. The hook clears
memberships in the same transaction as the delete, and refuses outright
while the user has a non-zero balance anywhere — deleting them then would
silently rewrite what everyone else owes."
```

---

### Task 8: Remove the app's direct PocketBase dependency

**Files:**
- Create: `splitcore_sdk/lib/src/remote/token_store.dart`
- Modify: `splitcore_sdk/lib/src/sdk.dart:35-52` (`initialize` signature and body)
- Modify: `splitcore_sdk/lib/splitcore_sdk.dart` (export `TokenStore`)
- Create: `splitcore_sdk/test/token_store_test.dart`
- Modify: `app/lib/main.dart:6` (drop the PocketBase import), `app/lib/main.dart:77-91` (`_initSdk`)
- Modify: `app/pubspec.yaml` (drop the `pocketbase` dependency)

**Interfaces:**
- Consumes: `SplitcoreSdk.initialize` from Task 1's unchanged form.
- Produces: `abstract class TokenStore { String? read(); Future<void> write(String data); }` and `SplitcoreSdk.initialize({required String pocketbaseUrl, required String libraryPath, TokenStore? tokenStore})`.

**Scope note:** the repository review called this "hide PocketBase behind the SDK" and rated it Medium-High, implying an architectural refactor. It is not. Exactly one file in `app/lib/` imports `package:pocketbase` — `main.dart:6` — and it does so for one type, `AsyncAuthStore`. Every screen already goes through the SDK. This task replaces that single type with an SDK-owned interface and deletes the dependency.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/token_store_test.dart`:

```dart
import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

/// What a Flutter app supplies, backed by shared_preferences.
class _FakeStore implements TokenStore {
  _FakeStore([this._value]);

  String? _value;
  int writes = 0;

  @override
  String? read() => _value;

  @override
  Future<void> write(String data) async {
    _value = data;
    writes++;
  }
}

void main() {
  test('TokenStore is exported from the public API', () {
    final store = _FakeStore('seed');
    expect(store, isA<TokenStore>());
    expect(store.read(), 'seed');
  });

  test('the SDK persists the session through the supplied store', () async {
    final store = _FakeStore();
    // Nothing is contacted at construction time — this only proves the
    // store is wired in, not that a login round-trips.
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: 'http://127.0.0.1:1',
      libraryPath: 'libsplitcore.so',
      tokenStore: store,
    );
    expect(sdk.auth.currentUser, isNull);
  });
}
```

The second test opens the native library, so run it after `make native`.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/token_store_test.dart`
Expected: FAIL — `Undefined name 'TokenStore'`.

- [ ] **Step 3: Define the interface**

Create `splitcore_sdk/lib/src/remote/token_store.dart`:

```dart
// How the SDK persists a session across app restarts, without the caller
// needing a PocketBase type. The app supplies the storage (shared_
// preferences on mobile/desktop, anything else elsewhere); the SDK adapts
// it to PocketBase's AuthStore internally so `package:pocketbase` stops at
// this package's boundary.
import 'package:pocketbase/pocketbase.dart';

abstract class TokenStore {
  /// The previously written blob, or null on a first launch. Synchronous:
  /// the SDK needs it during construction, so read it before initializing
  /// (e.g. `await SharedPreferences.getInstance()` first).
  String? read();

  /// Persists [data]. Called by the SDK whenever the session changes —
  /// sign-in, refresh, sign-out.
  Future<void> write(String data);
}

/// Adapts a [TokenStore] to PocketBase's AuthStore. Internal.
AuthStore asAuthStore(TokenStore store) => AsyncAuthStore(
      save: store.write,
      initial: store.read(),
    );
```

- [ ] **Step 4: Take a TokenStore in initialize**

In `splitcore_sdk/lib/src/sdk.dart`, add the import:

```dart
import 'remote/token_store.dart';
```

then change the factory's parameter and body:

```dart
  /// Pass [tokenStore] to persist the signed-in session across app
  /// restarts; defaults to PocketBase's in-memory store, which forgets
  /// sign-in on every launch.
  factory SplitcoreSdk.initialize({
    required String pocketbaseUrl,
    required String libraryPath,
    TokenStore? tokenStore,
  }) {
    final pb = PocketBase(
      pocketbaseUrl,
      authStore: tokenStore == null ? null : asAuthStore(tokenStore),
      httpClientFactory: () => _TimeoutClient(http.Client(), const Duration(seconds: 15)),
    );
```

The rest of the factory is unchanged.

- [ ] **Step 5: Export it**

In `splitcore_sdk/lib/splitcore_sdk.dart`, add before the `sdk.dart` export:

```dart
export 'src/remote/token_store.dart' show TokenStore;
```

- [ ] **Step 6: Run the test to verify it passes**

Run:
```bash
cd /home/abdul/Projects/slice_pay && make native
cd splitcore_sdk && dart test test/token_store_test.dart
```
Expected: `+2: All tests passed!`

- [ ] **Step 7: Cut PocketBase out of the app**

In `app/lib/main.dart`, delete the import at line 6:

```dart
import 'package:pocketbase/pocketbase.dart';
```

Add a store implementation above `_SplitcoreAppState` (or wherever the app state class sits):

```dart
/// Session persistence for the SDK, backed by shared_preferences. The SDK
/// reads synchronously during construction, so the prefs instance must
/// already be resolved — see _initSdk.
class _PrefsTokenStore implements TokenStore {
  _PrefsTokenStore(this._prefs);

  final SharedPreferences _prefs;
  static const _key = 'pb_auth';

  @override
  String? read() => _prefs.getString(_key);

  @override
  Future<void> write(String data) => _prefs.setString(_key, data);
}
```

and replace the body of `_initSdk`:

```dart
  Future<SplitcoreSdk> _initSdk() async {
    final prefs = await SharedPreferences.getInstance();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: defaultBackendUrl(),
      libraryPath: _libraryPath(),
      tokenStore: _PrefsTokenStore(prefs),
    );
    currentUser.value = sdk.auth.currentUser;
    unawaited(_refreshSession());
    return sdk;
  }
```

- [ ] **Step 8: Drop the dependency**

In `app/pubspec.yaml`, delete the line:

```yaml
  pocketbase: ^0.22.0
```

- [ ] **Step 9: Verify no PocketBase reference survives in the app**

Run:
```bash
cd /home/abdul/Projects/slice_pay
grep -rn "pocketbase" app/lib app/pubspec.yaml
```
Expected: no output. (`app/pubspec.lock` will still list it transitively via `splitcore_sdk` — that is correct and expected.)

- [ ] **Step 10: Rebuild and test the app**

Run:
```bash
cd app && flutter pub get && flutter analyze --fatal-infos && flutter test
```
Expected: `No issues found!` then all tests pass.

- [ ] **Step 11: Commit**

```bash
git add splitcore_sdk/lib splitcore_sdk/test/token_store_test.dart app/lib/main.dart app/pubspec.yaml app/pubspec.lock
git commit -m "refactor: replace the app's AsyncAuthStore use with an SDK TokenStore

main.dart was the only file in app/lib importing package:pocketbase, and
only for one type. The SDK now owns the persistence interface, so the app
no longer depends on PocketBase at all."
```

---

### Task 9: Group data export

**Files:**
- Create: `splitcore_sdk/lib/src/remote/export_api.dart`
- Create: `splitcore_sdk/test/remote/export_api_test.dart`
- Modify: `splitcore_sdk/lib/src/sdk.dart` (expose `export`)
- Modify: `splitcore_sdk/lib/splitcore_sdk.dart` (export `ExportApi`)

**Interfaces:**
- Consumes: `ExpensesApi.listAllExpenses`, `ExpensesApi.listSplitEntries`, `SettlementsApi.listAllSettlements`, `GroupsApi.listMembers` (Task 2).
- Produces: `class ExportApi { Future<String> groupToCsv(String groupId); }`, reachable as `sdk.export.groupToCsv(id)`.

**Format:** one CSV, one row per ledger line, expenses and settlements interleaved by date. CSV rather than JSON because the destination is a spreadsheet — "let me check these numbers myself" is the whole reason this feature exists. Amounts are written as decimal strings derived from the integer minor units by string manipulation only; parsing them back into a float is the caller's problem, and no float is ever created here.

- [ ] **Step 1: Write the failing test**

Create `splitcore_sdk/test/remote/export_api_test.dart`:

```dart
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/export_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/remote/local_store.dart';
import 'package:splitcore_sdk/src/remote/settlements_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late ExportApi exportApi;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember owner;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final calc = SplitcoreCalc.open(resolveLinuxLibPath());
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, calc);
    final settlementsApi = SettlementsApi(pb, calc, LocalStore());
    exportApi = ExportApi(groupsApi, expensesApi, settlementsApi);

    final ownerUser = await auth.signUp(
      email: 'export-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Export', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'exportee-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == ownerUser.id);
  });

  test('the CSV has a header and one row per member share', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    final csv = await exportApi.groupToCsv(group.id);
    final lines = const LineSplitter().convert(csv);

    expect(lines.first, 'date,type,description,payer,member,amount,currency');
    expect(lines.length, 3, reason: 'header + one row per split entry');
    expect(lines.skip(1).every((l) => l.contains('expense')), isTrue);
    expect(lines.skip(1).every((l) => l.endsWith(',USD')), isTrue);
  });

  test('amounts are exact decimal strings, never floats', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Odd',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.exact(
        totalCents: 1,
        entries: [ExactSplitEntry(memberId: owner.id, amountCents: 1)],
      ),
    );

    final csv = await exportApi.groupToCsv(group.id);
    expect(csv.contains(',0.01,'), isTrue, reason: 'one cent must render as 0.01\n$csv');
  });

  test('a description containing a comma or quote is escaped', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner, "the good place"',
      date: DateTime.utc(2026, 7, 3),
      split: SplitSpec.equal(totalCents: 200, memberIds: [owner.id]),
    );

    final csv = await exportApi.groupToCsv(group.id);
    expect(csv.contains('"Dinner, ""the good place"""'), isTrue, reason: csv);
  });
}
```

Add `import 'dart:convert';` at the top of that test file for `LineSplitter`.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd splitcore_sdk && dart test test/remote/export_api_test.dart`
Expected: FAIL — `Couldn't resolve ... export_api.dart`.

- [ ] **Step 3: Implement the export**

Create `splitcore_sdk/lib/src/remote/export_api.dart`:

```dart
// Exports a group's whole ledger as CSV. The destination is a
// spreadsheet — the point of the feature is "let me check these numbers
// myself" — so the shape is one row per money movement, not a nested
// document.
import '../models.dart';
import 'expenses_api.dart';
import 'groups_api.dart';
import 'settlements_api.dart';

class ExportApi {
  ExportApi(this._groups, this._expenses, this._settlements);

  final GroupsApi _groups;
  final ExpensesApi _expenses;
  final SettlementsApi _settlements;

  /// The group's expenses (one row per member's share) and settlements
  /// (one row each), oldest first.
  Future<String> groupToCsv(String groupId) async {
    final group = await _groups.getGroup(groupId);
    final members = await _groups.listMembers(groupId);
    final nameFor = {for (final m in members) m.id: m.displayName};

    final rows = <_Row>[];

    for (final expense in await _expenses.listAllExpenses(groupId)) {
      for (final entry in await _expenses.listSplitEntries(expense.id)) {
        rows.add(_Row(
          date: expense.date,
          type: 'expense',
          description: expense.description,
          payer: nameFor[expense.payerMemberId] ?? expense.payerMemberId,
          member: nameFor[entry.memberId] ?? entry.memberId,
          amountCents: entry.amountCents,
        ));
      }
    }

    for (final s in await _settlements.listAllSettlements(groupId)) {
      rows.add(_Row(
        date: s.date,
        type: 'settlement',
        description: s.note,
        payer: nameFor[s.fromMemberId] ?? s.fromMemberId,
        member: nameFor[s.toMemberId] ?? s.toMemberId,
        amountCents: s.amountCents,
      ));
    }

    rows.sort((a, b) => a.date.compareTo(b.date));

    final buffer = StringBuffer('date,type,description,payer,member,amount,currency\n');
    for (final row in rows) {
      buffer.writeln([
        row.date.toIso8601String().substring(0, 10),
        row.type,
        row.description,
        row.payer,
        row.member,
        formatMinorUnits(row.amountCents),
        group.currency,
      ].map(_csvField).join(','));
    }
    return buffer.toString();
  }
}

/// Renders integer minor units as a decimal string by string manipulation
/// only — going through a double would reintroduce exactly the rounding
/// error the int64 representation exists to prevent.
String formatMinorUnits(int cents) {
  final negative = cents < 0;
  final digits = cents.abs().toString().padLeft(3, '0');
  final whole = digits.substring(0, digits.length - 2);
  final fraction = digits.substring(digits.length - 2);
  return '${negative ? '-' : ''}$whole.$fraction';
}

/// RFC 4180: quote a field containing a comma, quote, or newline, and
/// double any quote inside it. Without this, one expense described as
/// "Dinner, drinks" shifts every later column by one.
String _csvField(String value) {
  if (!value.contains(RegExp(r'[",\n\r]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}

class _Row {
  _Row({
    required this.date,
    required this.type,
    required this.description,
    required this.payer,
    required this.member,
    required this.amountCents,
  });

  final DateTime date;
  final String type;
  final String description;
  final String payer;
  final String member;
  final int amountCents;
}
```

**Before running:** check `GroupMember` in `models.dart` for the field that
holds a member's human name. If it is not `displayName`, use the real one
(the app has a `display_name.dart` helper — match whatever the model
exposes). Same for `Group.currency`.

- [ ] **Step 4: Wire it into the facade**

In `splitcore_sdk/lib/src/sdk.dart`: add `import 'remote/export_api.dart';`, add
`this.export,` to the private constructor's parameter list and
`final ExportApi export;` to the fields (next to `balances`), and construct it
in the factory's `return`:

```dart
    final groupsApi = GroupsApi(pb);
    final expensesApi = ExpensesApi(pb, calc);
    final settlementsApi = SettlementsApi(pb, calc, store);
    return SplitcoreSdk._(
      AuthApi(pb),
      groupsApi,
      expensesApi,
      settlementsApi,
      BalancesApi(pb),
      ExportApi(groupsApi, expensesApi, settlementsApi),
      calc,
    );
```

In `splitcore_sdk/lib/splitcore_sdk.dart`, add:

```dart
export 'src/remote/export_api.dart' show ExportApi;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd splitcore_sdk && dart test test/remote/export_api_test.dart`
Expected: `+3: All tests passed!`

- [ ] **Step 6: Run everything**

Run: `cd /home/abdul/Projects/slice_pay && make check`
Expected: exits 0.

- [ ] **Step 7: Update the changelog and commit**

Add under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- Group data export to CSV (`sdk.export.groupToCsv`).
- Expense editing, expense search, and paginated expense/settlement listings.
- Password reset, email verification, and account deletion.
```

and under `### Fixed`:

```markdown
- PocketBase filters are parameterized rather than interpolated.
- A failed expense create no longer leaves an orphan, uncounted expense.
- Concurrent session refreshes no longer race each other into a sign-out.
```

```bash
git add splitcore_sdk/lib splitcore_sdk/test CHANGELOG.md
git commit -m "feat(sdk): export a group's ledger as CSV

Amounts are rendered from int64 minor units by string manipulation — no
double is constructed anywhere in the path. Fields are RFC 4180 escaped so
a description containing a comma cannot shift the columns."
```

---

## Self-review checklist for the implementer

Before declaring this plan done:

1. `grep -rn "filter: \"" splitcore_sdk/lib | grep '\$'` → no output (Task 1 held).
2. `grep -rn "getFullList" splitcore_sdk/lib` → only in `listAll*`, `_resync`, `updateExpense`, and `listSplitEntries`, all of which need the complete set.
3. `grep -rn "pocketbase" app/lib` → no output (Task 8 held).
4. Every new public method is exported from `splitcore_sdk/lib/splitcore_sdk.dart`.
5. `make check` passes.

## What this plan does NOT cover

- **UI for any of it.** Expense edit screens, search fields, infinite scroll, export buttons, password-reset flows, and account-deletion confirmation all live in `2026-08-04-splitcore-app-usability.md`. The SDK methods land here; the screens that call them land there.
- **Offline writes.** `LocalStore` is still in-memory and read-only-ish. Offline *reads* are in the app plan; a write queue that survives restart is a separate project and is not planned yet.
- **Receipt lifecycle beyond attach.** `attachReceipt` and `receiptUrl` exist; replacing and deleting a receipt is not covered.
