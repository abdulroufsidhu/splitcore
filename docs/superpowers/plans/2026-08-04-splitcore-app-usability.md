# Splitcore App Usability & Production Readiness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the Flutter client from a working prototype into an app that is testable, survives a bad network, covers the whole product loop (edit, delete, search, recover an account, export), and is usable by people who do not read English or cannot see the screen.

**Architecture:** The screens keep their current shape — `StatefulWidget` per screen, SDK passed down. What changes is that the duplicated `(data, error, loading)` triple in every screen becomes one `Loadable<T>` + `AsyncSection<T>` pair. That is the whole "state management" fix: it removes the duplication, gives every screen a real retry path, and — the reason it comes first — makes every screen widget-testable by injecting a loader instead of a live SDK.

**Tech Stack:** Flutter (Dart 3.9+), `flutter_localizations` + `intl` ARB files, `shared_preferences` (already a dependency) for the offline snapshot cache, `flutter_test`.

## Global Constraints

- **Prerequisites:** `2026-08-04-splitcore-foundation.md` (all tasks) and `2026-08-04-splitcore-sdk-correctness.md` (all tasks). This plan calls `updateExpense`, `searchExpenses`, `Page<T>`, `requestPasswordReset`, `deleteAccount`, and `sdk.export` — all of which land in the SDK plan.
- `app/lib/` must never import `package:pocketbase` (enforced by SDK plan Task 8) and must never compute a split, a balance, or a settlement amount. Money math is the Go engine's job, reached through `sdk.previewSplit` / `sdk.settleUp`.
- All money is `int64` minor units. Formatting lives in `app/lib/money.dart`.
- No new dependency without checking the ladder first: stdlib → existing dependency → native Flutter widget → new package. `flutter_localizations` and `intl` (already present) are the only additions this plan makes.
- Every user-visible string added after Task 8 goes through the localization lookup, not a literal.
- Run `make check` before every commit step.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `app/lib/loadable.dart` | `Loadable<T>` — one async value with loading/error/data + retry | **new** |
| `app/lib/widgets/async_section.dart` | Renders a `Loadable<T>` as skeleton / error+retry / content | **new** |
| `app/lib/screens/home.dart` | Group list | modify |
| `app/lib/screens/group_detail.dart` | Balances, activity, search, paging | modify |
| `app/lib/screens/activity.dart` | Global activity feed | modify |
| `app/lib/screens/add_expense.dart` | Create **and edit** an expense | modify |
| `app/lib/screens/login.dart` | Sign in / sign up / forgot password | modify |
| `app/lib/screens/account.dart` | Profile, verification banner, export, delete account | **new** |
| `app/lib/offline_cache.dart` | Persistent last-known-good snapshots | **new** |
| `app/lib/l10n/app_en.arb`, `app/lib/l10n/app_ur.arb` | Translatable strings | **new** |

---

### Task 1: `Loadable<T>` and `AsyncSection<T>`

**Files:**
- Create: `app/lib/loadable.dart`
- Create: `app/lib/widgets/async_section.dart`
- Create: `app/test/loadable_test.dart`
- Create: `app/test/widgets/async_section_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `class Loadable<T> extends ChangeNotifier { Loadable(this._load); T? get value; Object? get error; bool get isLoading; Future<void> load(); Future<void> retry(); void setValue(T); }`
  - `class AsyncSection<T> extends StatelessWidget { const AsyncSection({required this.loadable, required this.builder, required this.skeleton, this.errorLabel}); }`

**Why this is first:** every screen currently repeats `T? _data; Object? _error; bool _loading;` plus a `_load()` with a `try/catch` and two `setState` blocks — `home.dart:63-107`, `group_detail.dart:30-64`, `activity.dart:34-54`. Beyond the duplication, that shape has no retry: `group_detail.dart` stores the error and renders it, and the user's only recovery is to back out and re-enter the screen. And because the loading is welded to the SDK inside `initState`, none of these screens can be widget-tested without a live server. One small type fixes all three.

- [ ] **Step 1: Write the failing test**

Create `app/test/loadable_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/loadable.dart';

void main() {
  test('starts idle, then holds the loaded value', () async {
    final loadable = Loadable<int>(() async => 42);

    expect(loadable.value, isNull);
    expect(loadable.isLoading, isFalse);

    await loadable.load();

    expect(loadable.value, 42);
    expect(loadable.error, isNull);
    expect(loadable.isLoading, isFalse);
  });

  test('captures a failure instead of throwing', () async {
    final loadable = Loadable<int>(() async => throw StateError('boom'));

    await loadable.load();

    expect(loadable.error, isA<StateError>());
    expect(loadable.value, isNull);
  });

  test('retry clears the previous error and can succeed', () async {
    var attempt = 0;
    final loadable = Loadable<int>(() async {
      attempt++;
      if (attempt == 1) throw StateError('first attempt fails');
      return attempt;
    });

    await loadable.load();
    expect(loadable.error, isNotNull);

    await loadable.retry();

    expect(loadable.error, isNull);
    expect(loadable.value, 2);
  });

  test('a successful reload keeps the old value visible while loading', () async {
    final gate = Completer<int>();
    var call = 0;
    final loadable = Loadable<int>(() {
      call++;
      return call == 1 ? Future.value(1) : gate.future;
    });

    await loadable.load();
    final reload = loadable.load();

    // Mid-reload: still showing the previous value, and marked loading.
    expect(loadable.value, 1, reason: 'reload blanked the screen');
    expect(loadable.isLoading, isTrue);

    gate.complete(2);
    await reload;
    expect(loadable.value, 2);
  });

  test('notifies listeners on every state change', () async {
    final loadable = Loadable<int>(() async => 1);
    var notifications = 0;
    loadable.addListener(() => notifications++);

    await loadable.load();

    expect(notifications, greaterThanOrEqualTo(2), reason: 'loading start and finish');
  });
}
```

Add `import 'dart:async';` at the top for `Completer`.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/loadable_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'splitcore_app' ... loadable.dart`.

- [ ] **Step 3: Implement Loadable**

Create `app/lib/loadable.dart`:

```dart
// One async value with the three states every screen actually has:
// loading, failed (with a way to try again), and loaded. Every screen was
// hand-rolling this as a (data, error, loading) triple plus two setState
// blocks, and none of them offered a retry — the only recovery from a
// failed load was to leave the screen and come back.
//
// The loader is injected rather than reached for, which is also what makes
// a screen widget-testable: a test hands it a function returning fixtures
// instead of a live SDK and server.
import 'package:flutter/foundation.dart';

class Loadable<T> extends ChangeNotifier {
  Loadable(this._loader);

  final Future<T> Function() _loader;

  T? _value;
  Object? _error;
  bool _isLoading = false;

  T? get value => _value;
  Object? get error => _error;
  bool get isLoading => _isLoading;

  /// True on the very first load, when there is nothing to show yet — the
  /// difference between "show a skeleton" and "keep the list on screen
  /// while it refreshes".
  bool get isInitialLoad => _isLoading && _value == null;

  /// Runs the loader. A reload keeps the previous value visible: blanking
  /// a populated list back to a skeleton on every pull-to-refresh reads as
  /// the app losing the data.
  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();
    try {
      _value = await _loader();
    } catch (e) {
      _error = e;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Same as [load]; named separately so call sites read as what the user
  /// did ("tapped Retry") rather than what the code does.
  Future<void> retry() => load();

  /// Replaces the value without a round trip — for a screen that just
  /// created or edited a row and already knows the new state.
  void setValue(T value) {
    _value = value;
    _error = null;
    notifyListeners();
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/loadable_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Write the failing widget test**

Create `app/test/widgets/async_section_test.dart`:

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/loadable.dart';
import 'package:splitcore_app/theme.dart';
import 'package:splitcore_app/widgets/async_section.dart';

Widget _host(Loadable<String> loadable) => MaterialApp(
      theme: sliceLightTheme(),
      home: Scaffold(
        body: AsyncSection<String>(
          loadable: loadable,
          skeleton: const Text('skeleton'),
          builder: (context, value) => Text(value),
        ),
      ),
    );

void main() {
  testWidgets('shows the skeleton during the first load', (tester) async {
    final gate = Completer<String>();
    final loadable = Loadable<String>(() => gate.future);
    unawaited(loadable.load());

    await tester.pumpWidget(_host(loadable));
    await tester.pump();

    expect(find.text('skeleton'), findsOneWidget);

    gate.complete('done');
    await tester.pumpAndSettle();
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('shows the error with a retry that reloads', (tester) async {
    var attempts = 0;
    final loadable = Loadable<String>(() async {
      attempts++;
      if (attempts == 1) throw StateError('network down');
      return 'recovered';
    });
    await loadable.load();

    await tester.pumpWidget(_host(loadable));
    await tester.pumpAndSettle();

    expect(find.textContaining('went wrong'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('recovered'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('keeps content on screen during a reload', (tester) async {
    final gate = Completer<String>();
    var call = 0;
    final loadable = Loadable<String>(() {
      call++;
      return call == 1 ? Future.value('first') : gate.future;
    });
    await loadable.load();

    await tester.pumpWidget(_host(loadable));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);

    unawaited(loadable.load());
    await tester.pump();

    expect(find.text('first'), findsOneWidget, reason: 'reload blanked the content');
    expect(find.text('skeleton'), findsNothing);

    gate.complete('second');
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  });
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd app && flutter test test/widgets/async_section_test.dart`
Expected: FAIL — `async_section.dart` does not exist.

- [ ] **Step 7: Implement AsyncSection**

Create `app/lib/widgets/async_section.dart`:

```dart
// Renders a Loadable as the three things a user can be looking at:
// a skeleton, a failure they can act on, or the content.
//
// The error state is deliberately a real recovery affordance, not a red
// string: a failed load with no retry button forces the user to back out
// of the screen and come in again to try the same request.
import 'package:flutter/material.dart';

import '../loadable.dart';
import '../theme.dart';

class AsyncSection<T> extends StatelessWidget {
  const AsyncSection({
    super.key,
    required this.loadable,
    required this.builder,
    required this.skeleton,
    this.errorLabel,
  });

  final Loadable<T> loadable;
  final Widget Function(BuildContext context, T value) builder;
  final Widget skeleton;

  /// What failed, in the user's terms — "Couldn't load your groups".
  /// Falls back to a generic line when omitted.
  final String? errorLabel;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: loadable,
      builder: (context, _) {
        final value = loadable.value;
        if (value != null) return builder(context, value);
        if (loadable.error != null) {
          return _ErrorState(
            label: errorLabel ?? 'Something went wrong.',
            error: loadable.error!,
            onRetry: loadable.retry,
          );
        }
        return skeleton;
      },
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.label, required this.error, required this.onRetry});

  final String label;
  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(label, style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 6),
            // The raw error is second-class: useful when someone reports a
            // problem, never the headline.
            Text(
              '$error',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      ),
    );
  }
}
```

If `theme.dart` does not expose `colorScheme.outline` in the app's palette,
use the nearest muted color it does define — match the file, do not add a
color.

- [ ] **Step 8: Run the widget test to verify it passes**

Run: `cd app && flutter test test/widgets/async_section_test.dart`
Expected: `All tests passed!` (3 tests)

- [ ] **Step 9: Commit**

```bash
git add app/lib/loadable.dart app/lib/widgets/async_section.dart \
        app/test/loadable_test.dart app/test/widgets/async_section_test.dart
git commit -m "feat(app): add Loadable and AsyncSection

Every screen hand-rolled a (data, error, loading) triple with no retry
path, and none could be widget-tested without a live server because the
load was welded into initState. One injected loader fixes both."
```

---

### Task 2: Migrate the screens onto `Loadable`, with paging and retry

**Files:**
- Modify: `app/lib/screens/home.dart:63-115` (state + `_load`), and its `build`
- Modify: `app/lib/screens/group_detail.dart:29-70` (state + `_load`), and its `build`
- Modify: `app/lib/screens/activity.dart:30-60`
- Create: `app/test/screens/group_detail_test.dart`
- Create: `app/test/screens/home_test.dart`

**Interfaces:**
- Consumes: `Loadable<T>`/`AsyncSection<T>` from Task 1; `Page<Expense>`, `Page<Settlement>`, `listAllExpenses`, `listAllSettlements` from SDK plan Task 2.
- Produces: each screen gains an optional `@visibleForTesting` loader override so widget tests can supply fixtures.

**Two things happen here at once, deliberately:** the SDK plan changed `listExpenses`/`listSettlements` to return `Page<T>`, so `group_detail.dart:43-44` and `activity.dart:34-35` must change anyway. Doing the `Loadable` migration in the same edit means touching each `_load` once instead of twice.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/screens/group_detail_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/group_detail.dart';
import 'package:splitcore_app/theme.dart';

final _group = Group(id: 'g1', name: 'Trip', currency: 'USD', isDirect: false, version: 1);
final _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');

void main() {
  testWidgets('renders the group name and its activity', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: GroupDetailScreen(
        sdk: null,
        me: _me,
        group: _group,
        loadOverride: () async => GroupDetailData(
          members: [
            GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me', avatarUrl: ''),
          ],
          balances: [const Balance(memberId: 'm1', netCents: 2500)],
          expenses: Page<Expense>(
            items: [
              Expense(
                id: 'e1',
                groupId: 'g1',
                payerMemberId: 'm1',
                description: 'Dinner',
                amountCents: 5000,
                splitType: 'equal',
                date: DateTime.utc(2026, 7, 1),
              ),
            ],
            page: 1,
            perPage: 50,
            totalItems: 1,
            totalPages: 1,
          ),
          settlements: Page<Settlement>.empty(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Dinner'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry that succeeds', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: GroupDetailScreen(
        sdk: null,
        me: _me,
        group: _group,
        loadOverride: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return GroupDetailData(
            members: const [],
            balances: const [],
            expenses: Page<Expense>.empty(),
            settlements: Page<Settlement>.empty(),
          );
        },
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
    expect(attempts, 2);
  });
}
```

**Adjust the model constructors** to match the real ones in
`splitcore_sdk/lib/src/models.dart` — field names and whether they are
positional. The test's shape is what matters, not the exact literals.

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/screens/group_detail_test.dart`
Expected: FAIL — `No named parameter with the name 'loadOverride'`, and `GroupDetailData` is private (`_GroupData`).

- [ ] **Step 3: Migrate group_detail.dart**

Rename the private `_GroupData` to a public `GroupDetailData` and give it
the four fields the loader produces:

```dart
/// Everything the group detail screen needs, fetched as one unit. Public
/// so a widget test can construct it without an SDK.
class GroupDetailData {
  GroupDetailData({
    required this.members,
    required this.balances,
    required this.expenses,
    required this.settlements,
  });

  final List<GroupMember> members;
  final List<Balance> balances;
  final Page<Expense> expenses;
  final Page<Settlement> settlements;
}
```

Add the override parameter to the widget:

```dart
class GroupDetailScreen extends StatefulWidget {
  const GroupDetailScreen({
    super.key,
    required this.sdk,
    required this.me,
    required this.group,
    this.loadOverride,
  });

  final SplitcoreSdk? sdk;
  final AppUser me;
  final Group group;

  /// Test seam: supplies the screen's data without an SDK or a server.
  @visibleForTesting
  final Future<GroupDetailData> Function()? loadOverride;
```

Replace the state triple and `_load`:

```dart
class _GroupDetailScreenState extends State<GroupDetailScreen> {
  late final Loadable<GroupDetailData> _data = Loadable(widget.loadOverride ?? _fetch);

  @override
  void initState() {
    super.initState();
    _data.load();
  }

  @override
  void dispose() {
    _data.dispose();
    super.dispose();
  }

  Future<GroupDetailData> _fetch() async {
    final sdk = widget.sdk!;
    final members = await sdk.groups.listMembers(widget.group.id);
    final balances = await sdk.balances.getBalances(widget.group.id);
    final expenses = await sdk.expenses.listExpenses(widget.group.id);
    final settlements = await sdk.settlements.listSettlements(widget.group.id);
    return GroupDetailData(
      members: members,
      balances: balances,
      expenses: expenses,
      settlements: settlements,
    );
  }

  void _refresh() => _data.load();
```

In `build`, wrap the body:

```dart
      body: PageBody(
        child: AsyncSection<GroupDetailData>(
          loadable: _data,
          errorLabel: "Couldn't load this group.",
          skeleton: const SkeletonList(),
          builder: (context, data) => _content(context, data),
        ),
      ),
```

Move the existing body-building code into `Widget _content(BuildContext context, GroupDetailData data)`, replacing every `_data!.members` with `data.members` and so on. The `buildActivity` call moves into `_content`, taking `data.expenses.items` and `data.settlements.items`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/screens/group_detail_test.dart`
Expected: `All tests passed!` (2 tests)

- [ ] **Step 5: Add "load more" for the expense list**

The group's activity list now shows only the first page. Below the list, when
`data.expenses.hasMore`, render a button that fetches and appends:

```dart
  /// Pages already appended past the first. Kept separate from the
  /// Loadable's value so a refresh resets paging to page 1, which is what
  /// "pull to refresh" should mean.
  final List<Expense> _extraExpenses = [];
  int _loadedPage = 1;
  bool _loadingMore = false;

  Future<void> _loadMore(Page<Expense> current) async {
    if (_loadingMore || !current.hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final next = await widget.sdk!.expenses.listExpenses(
        widget.group.id,
        page: _loadedPage + 1,
        perPage: current.perPage,
      );
      if (!mounted) return;
      setState(() {
        _extraExpenses.addAll(next.items);
        _loadedPage = next.page;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }
```

and in `_content`, build the activity from `[...data.expenses.items, ..._extraExpenses]`,
followed by:

```dart
            if (data.expenses.hasMore && _loadedPage < data.expenses.totalPages)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Center(
                  child: _loadingMore
                      ? const CircularProgressIndicator()
                      : TextButton(
                          onPressed: () => _loadMore(data.expenses),
                          child: Text('Show older expenses '
                              '(${data.expenses.totalItems - data.expenses.items.length - _extraExpenses.length} more)'),
                        ),
                ),
              ),
```

Reset paging whenever the underlying load re-runs: in `_refresh`, clear
`_extraExpenses` and set `_loadedPage = 1` before calling `_data.load()`.

- [ ] **Step 6: Migrate home.dart the same way**

`home.dart` already degrades gracefully per group (`_loadRow` returns null on
failure, so one broken group does not take down the list) — keep that. Replace
only the outer triple:

```dart
class _HomeScreenState extends State<HomeScreen> {
  late final Loadable<List<_GroupRow>> _rows = Loadable(widget.loadOverride ?? _fetchRows);
```

with `_fetchRows` holding the existing body of `_load`, and the build wrapped in:

```dart
        child: AsyncSection<List<_GroupRow>>(
          loadable: _rows,
          errorLabel: "Couldn't load your groups.",
          skeleton: const SkeletonList(),
          builder: (context, rows) => _list(context, rows),
        ),
```

Add the same `@visibleForTesting Future<List<_GroupRow>> Function()? loadOverride`
parameter. Since `_GroupRow` is private, also make it public as `GroupRow` so a
test can build fixtures.

- [ ] **Step 7: Write the home screen test**

Create `app/test/screens/home_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/home.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  final me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');

  Widget host({required Future<List<GroupRow>> Function() load}) => MaterialApp(
        theme: sliceLightTheme(),
        home: HomeScreen(
          sdk: null,
          me: me,
          onSignedOut: () {},
          onProfileUpdated: (_) {},
          loadOverride: load,
        ),
      );

  testWidgets('lists groups with the signed-in user\'s net balance', (tester) async {
    await tester.pumpWidget(host(load: () async => [
          GroupRow(
            Group(id: 'g1', name: 'Trip', currency: 'USD', isDirect: false, version: 1),
            'm1',
            2500,
            3,
            '',
            '',
          ),
        ]));
    await tester.pumpAndSettle();

    expect(find.text('Trip'), findsOneWidget);
    expect(find.textContaining('25.00'), findsOneWidget);
  });

  testWidgets('an empty group list shows the empty state, not an error', (tester) async {
    await tester.pumpWidget(host(load: () async => []));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a failed load offers retry', (tester) async {
    await tester.pumpWidget(host(load: () async => throw StateError('offline')));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
  });
}
```

- [ ] **Step 8: Migrate activity.dart**

`activity.dart:34-35` fetches per group and must move to the `listAll*`
methods — the global feed genuinely wants everything, and it is already
bounded by the number of groups the user belongs to:

```dart
      final expenses = await widget.sdk.expenses.listAllExpenses(group.id);
      final settlements = await widget.sdk.settlements.listAllSettlements(group.id);
```

Replace its `FutureBuilder<List<ActivityItem>>` with a `Loadable` +
`AsyncSection`, matching the other two screens.

- [ ] **Step 9: Run every app test**

Run: `cd app && flutter analyze --fatal-infos && flutter test`
Expected: `No issues found!` and all tests pass.

- [ ] **Step 10: Commit**

```bash
git add app/lib app/test
git commit -m "refactor(app): move home, group detail, and activity onto Loadable

Removes the duplicated (data, error, loading) triple from three screens,
gives every one of them a retry path it did not have, absorbs the SDK's
new Page<T> return types, and adds 'show older expenses' paging to the
group detail list. Each screen now takes a test-only loader override, so
all three are widget-testable without a server."
```

---

### Task 3: Edit and delete an expense

**Files:**
- Modify: `app/lib/screens/add_expense.dart` (accept an existing expense)
- Modify: `app/lib/screens/group_detail.dart` (tap to edit, swipe/menu to delete)
- Create: `app/test/screens/add_expense_test.dart`

**Interfaces:**
- Consumes: `sdk.expenses.updateExpense` and `sdk.expenses.deleteExpense` (SDK plan Task 4).
- Produces: `AddExpenseScreen({..., Expense? existing, List<SplitEntry>? existingSplits})` — when `existing` is non-null the screen edits instead of creates.

**Reuse over addition:** `add_expense.dart` already builds the whole split editor with live preview (`sdk.previewSplit`). An edit screen is that screen with its fields pre-filled and `updateExpense` on save. A second screen would be 500 duplicated lines.

- [ ] **Step 1: Write the failing test**

Create `app/test/screens/add_expense_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/add_expense.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  final members = [
    GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me', avatarUrl: ''),
    GroupMember(id: 'm2', groupId: 'g1', userId: 'u2', role: 'member', name: 'Sam', avatarUrl: ''),
  ];
  final group = Group(id: 'g1', name: 'Trip', currency: 'USD', isDirect: false, version: 1);

  testWidgets('editing pre-fills the description and amount from the expense', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: AddExpenseScreen(
        sdk: null,
        group: group,
        members: members,
        myMemberId: 'm1',
        existing: Expense(
          id: 'e1',
          groupId: 'g1',
          payerMemberId: 'm2',
          description: 'Dinner',
          amountCents: 4250,
          splitType: 'equal',
          date: DateTime.utc(2026, 7, 1),
        ),
        existingSplits: const [
          SplitEntry(id: 's1', expenseId: 'e1', memberId: 'm1', amountCents: 2125),
          SplitEntry(id: 's2', expenseId: 'e1', memberId: 'm2', amountCents: 2125),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Dinner'), findsOneWidget);
    expect(find.widgetWithText(TextField, '42.50'), findsOneWidget);
    expect(find.text('Save changes'), findsOneWidget);
  });

  testWidgets('creating shows the create affordance, not the edit one', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: AddExpenseScreen(sdk: null, group: group, members: members, myMemberId: 'm1'),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Save changes'), findsNothing);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/screens/add_expense_test.dart`
Expected: FAIL — `No named parameter with the name 'existing'`.

- [ ] **Step 3: Make the screen editable**

In `app/lib/screens/add_expense.dart`, add to the widget:

```dart
  /// The expense being edited, or null when creating a new one.
  final Expense? existing;

  /// [existing]'s current split entries — needed to pre-select the members
  /// and, for an exact split, their amounts.
  final List<SplitEntry>? existingSplits;

  bool get isEditing => existing != null;
```

In `initState`, seed the controllers when editing:

```dart
  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _descriptionController.text = existing.description;
      _amountController.text = formatAmountForEditing(existing.amountCents);
      _payerMemberId = existing.payerMemberId;
      _date = existing.date;
      _splitType = existing.splitType;
      _selectedMemberIds
        ..clear()
        ..addAll(widget.existingSplits?.map((s) => s.memberId) ?? const []);
      for (final s in widget.existingSplits ?? const <SplitEntry>[]) {
        _exactControllers[s.memberId]?.text = formatAmountForEditing(s.amountCents);
      }
    } else {
      _payerMemberId = widget.myMemberId;
    }
  }
```

Match the real field and controller names in the file — the names above
are illustrative of the shape, not a guarantee of what they are called.
`formatAmountForEditing` is a plain minor-units-to-`"42.50"` helper; if
`app/lib/money.dart` already has one, use it, otherwise add it there (with
a test) rather than inline here.

In the save handler, branch on the mode:

```dart
      final expense = widget.isEditing
          ? await widget.sdk!.expenses.updateExpense(
              expenseId: widget.existing!.id,
              payerMemberId: _payerMemberId,
              description: description,
              date: _date,
              split: spec,
            )
          : await widget.sdk!.expenses.createExpense(
              groupId: widget.group.id,
              payerMemberId: _payerMemberId,
              description: description,
              date: _date,
              split: spec,
            );
```

and label the button `widget.isEditing ? 'Save changes' : <the existing label>`.
Title the app bar `widget.isEditing ? 'Edit expense' : <existing title>`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/screens/add_expense_test.dart`
Expected: `All tests passed!` (2 tests)

- [ ] **Step 5: Wire edit and delete into the group detail list**

In `app/lib/screens/group_detail.dart`, make each expense row open the editor:

```dart
  Future<void> _editExpense(Expense expense, List<GroupMember> members) async {
    final splits = await widget.sdk!.expenses.listSplitEntries(expense.id);
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddExpenseScreen(
          sdk: widget.sdk,
          group: widget.group,
          members: members,
          myMemberId: _myMemberId(members),
          existing: expense,
          existingSplits: splits,
        ),
      ),
    );
    if (changed == true) _refresh();
  }
```

and add a destructive action with a confirmation — deleting an expense
rewrites everyone's balances, so it must not be a single unconfirmed tap:

```dart
  Future<void> _deleteExpense(Expense expense) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this expense?'),
        content: Text(
          '"${expense.description}" will be removed and everyone\'s balances '
          'will be recalculated. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.sdk!.expenses.deleteExpense(expense.id);
      _refresh();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't delete: $e")),
      );
    }
  }
```

Attach both to the expense row — `onTap: () => _editExpense(...)` plus a
trailing overflow menu holding Edit and Delete. A menu rather than a swipe:
swipe-to-delete has no confirmation step on the way in and the gesture
collides with the scroll axis.

- [ ] **Step 6: Verify the whole app suite**

Run: `cd app && flutter analyze --fatal-infos && flutter test`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add app/lib/screens/add_expense.dart app/lib/screens/group_detail.dart \
        app/test/screens/add_expense_test.dart
git commit -m "feat(app): edit and delete expenses

AddExpenseScreen takes an optional existing expense and switches to
updateExpense on save, reusing the split editor and live preview rather
than duplicating them. Deletion is confirmed first — it silently
recalculates everyone's balances."
```

---

### Task 4: Search within a group

**Files:**
- Modify: `app/lib/screens/group_detail.dart` (search field + debounce)
- Create: `app/test/screens/group_search_test.dart`

**Interfaces:**
- Consumes: `sdk.expenses.searchExpenses` (SDK plan Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the failing test**

Create `app/test/screens/group_search_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/group_detail.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  testWidgets('typing a query calls search once, after the debounce', (tester) async {
    final queries = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: GroupDetailScreen(
        sdk: null,
        me: AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: ''),
        group: Group(id: 'g1', name: 'Trip', currency: 'USD', isDirect: false, version: 1),
        loadOverride: () async => GroupDetailData(
          members: const [],
          balances: const [],
          expenses: Page<Expense>.empty(),
          settlements: Page<Settlement>.empty(),
        ),
        searchOverride: (query) async {
          queries.add(query);
          return Page<Expense>.empty();
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'din');
    await tester.enterText(find.byType(TextField).first, 'dinn');
    await tester.enterText(find.byType(TextField).first, 'dinner');
    await tester.pump(const Duration(milliseconds: 100));

    expect(queries, isEmpty, reason: 'searched before the debounce elapsed');

    await tester.pump(const Duration(milliseconds: 400));

    expect(queries, ['dinner'], reason: 'one search for the final text, not three');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/screens/group_search_test.dart`
Expected: FAIL — `No named parameter with the name 'searchOverride'`.

- [ ] **Step 3: Implement debounced search**

Add to `GroupDetailScreen`:

```dart
  /// Test seam, as with loadOverride.
  @visibleForTesting
  final Future<Page<Expense>> Function(String query)? searchOverride;
```

and in the state:

```dart
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  Page<Expense>? _searchResults;

  /// Debounced because the search hits the server: firing on every
  /// keystroke would issue one request per character and race the
  /// responses, so a slow early request could overwrite a later one.
  void _onSearchChanged(String query) {
    _searchDebounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() => _searchResults = null);
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      final search = widget.searchOverride ??
          (String q) => widget.sdk!.expenses.searchExpenses(widget.group.id, q);
      try {
        final results = await search(query);
        if (mounted) setState(() => _searchResults = results);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text("Couldn't search: $e")),
          );
        }
      }
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _data.dispose();
    super.dispose();
  }
```

Put the field above the activity list, and when `_searchResults != null`
render those results in place of the normal activity list, with a "clear"
affordance and a "No expenses match" empty state.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/screens/group_search_test.dart`
Expected: `All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add app/lib/screens/group_detail.dart app/test/screens/group_search_test.dart
git commit -m "feat(app): search a group's expenses

Debounced 300ms — searching per keystroke issues one request per character
and lets a slow early response overwrite a later one."
```

---

### Task 5: Offline reads

**Files:**
- Create: `app/lib/offline_cache.dart`
- Create: `app/test/offline_cache_test.dart`
- Modify: `app/lib/screens/home.dart` (fall back to cache on load failure)
- Modify: `app/lib/screens/group_detail.dart` (same, plus an offline banner)

**Interfaces:**
- Consumes: `SharedPreferences` (already a dependency), `Loadable` from Task 1.
- Produces: `class OfflineCache { OfflineCache(SharedPreferences prefs); Future<void> putGroups(List<GroupSummary>); List<GroupSummary>? groups(); Future<void> putGroupDetail(String groupId, CachedGroupDetail); CachedGroupDetail? groupDetail(String groupId); }`

**Scope, honestly stated:** this is offline *reads* only — last-known-good data, plus a banner saying so. Offline **writes** (queue an expense on a plane, sync on landing) need conflict resolution against the server's version counter and are a separate project, not a task. Reads cover the actual complaint ("the app is a white error screen on a bad connection"); writes are a feature.

`splitcore_sdk`'s `LocalStore` is in-memory and dies with the process, which is why this cache lives in the app against `SharedPreferences` rather than extending it.

- [ ] **Step 1: Write the failing test**

Create `app/test/offline_cache_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:splitcore_app/offline_cache.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('returns null before anything is cached', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    expect(cache.groups(), isNull);
  });

  test('round-trips a group summary list', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    await cache.putGroups([
      const GroupSummary(id: 'g1', name: 'Trip', currency: 'USD', myNetCents: 2500, memberCount: 3),
    ]);

    final restored = cache.groups();

    expect(restored, isNotNull);
    expect(restored!.single.name, 'Trip');
    expect(restored.single.myNetCents, 2500);
  });

  test('a second instance sees what the first wrote (survives restart)', () async {
    final prefs = await SharedPreferences.getInstance();
    await OfflineCache(prefs).putGroups([
      const GroupSummary(id: 'g1', name: 'Trip', currency: 'USD', myNetCents: 1, memberCount: 2),
    ]);

    expect(OfflineCache(prefs).groups()!.single.id, 'g1');
  });

  test('corrupt cached JSON is discarded, not thrown', () async {
    SharedPreferences.setMockInitialValues({'offline_groups_v1': 'not json at all'});
    final cache = OfflineCache(await SharedPreferences.getInstance());

    expect(cache.groups(), isNull);
  });

  test('amounts survive as exact integers', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    await cache.putGroups([
      const GroupSummary(id: 'g1', name: 'X', currency: 'USD', myNetCents: -9007199254, memberCount: 1),
    ]);

    expect(cache.groups()!.single.myNetCents, -9007199254);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/offline_cache_test.dart`
Expected: FAIL — `offline_cache.dart` does not exist.

- [ ] **Step 3: Implement the cache**

Create `app/lib/offline_cache.dart`:

```dart
// Last-known-good data, so a failed load shows yesterday's numbers with a
// banner instead of an error screen. Reads only: writes made offline are
// not queued, and the UI must not pretend otherwise.
//
// The SDK's LocalStore is in-memory and dies with the process, which is
// exactly the case that matters here — the user reopens the app on a train.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The subset of a group needed to render the home list offline.
class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.currency,
    required this.myNetCents,
    required this.memberCount,
  });

  final String id;
  final String name;
  final String currency;
  final int myNetCents;
  final int memberCount;

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'currency': currency,
        // Minor units as an int — never a double. JSON numbers are doubles
        // in many parsers and 2^53 is not a theoretical limit for a ledger
        // denominated in cents.
        'myNetCents': myNetCents,
        'memberCount': memberCount,
      };

  static GroupSummary fromJson(Map<String, Object?> json) => GroupSummary(
        id: json['id']! as String,
        name: json['name']! as String,
        currency: json['currency']! as String,
        myNetCents: (json['myNetCents']! as num).toInt(),
        memberCount: (json['memberCount']! as num).toInt(),
      );
}

class OfflineCache {
  OfflineCache(this._prefs);

  final SharedPreferences _prefs;

  static const _groupsKey = 'offline_groups_v1';

  Future<void> putGroups(List<GroupSummary> groups) => _prefs.setString(
        _groupsKey,
        jsonEncode([for (final g in groups) g.toJson()]),
      );

  /// The cached list, or null when nothing is cached or the cached blob no
  /// longer parses. A stale cache from an older app version is not worth a
  /// crash — dropping it costs one network fetch.
  List<GroupSummary>? groups() {
    final raw = _prefs.getString(_groupsKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      return [
        for (final item in decoded) GroupSummary.fromJson(item! as Map<String, Object?>),
      ];
    } catch (_) {
      return null;
    }
  }

  /// When the cached data was written, for the "showing data from ..."
  /// banner. Null when nothing is cached.
  DateTime? get lastUpdated {
    final millis = _prefs.getInt('${_groupsKey}_at');
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> markUpdated() =>
      _prefs.setInt('${_groupsKey}_at', DateTime.now().millisecondsSinceEpoch);
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/offline_cache_test.dart`
Expected: `All tests passed!` (5 tests)

- [ ] **Step 5: Fall back to the cache in home.dart**

In `_fetchRows`, write through on success and read on failure:

```dart
  Future<List<GroupRow>> _fetchRows() async {
    try {
      final rows = await _fetchFromServer();
      await _cache.putGroups([
        for (final r in rows)
          GroupSummary(
            id: r.group.id,
            name: r.group.name,
            currency: r.group.currency,
            myNetCents: r.myNetCents,
            memberCount: r.memberCount,
          ),
      ]);
      await _cache.markUpdated();
      _showingCached = false;
      return rows;
    } catch (e) {
      final cached = _cache.groups();
      if (cached == null) rethrow;   // nothing to show: the error is the truth
      _showingCached = true;
      return [for (final g in cached) GroupRow.fromCache(g)];
    }
  }
```

Add `GroupRow.fromCache(GroupSummary)` producing a row with an empty
`myMemberId` (nothing offline can be tapped through to a live action) and
no direct-chat name. Render a banner above the list when `_showingCached`:

```dart
            if (_showingCached)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Row(
                  children: [
                    const Icon(Icons.cloud_off_outlined, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _cache.lastUpdated == null
                            ? "You're offline — showing saved data."
                            : "You're offline — showing data from "
                                '${formatRelative(_cache.lastUpdated!)}.',
                      ),
                    ),
                    TextButton(onPressed: _rows.retry, child: const Text('Retry')),
                  ],
                ),
              ),
```

Add `formatRelative(DateTime)` to `app/lib/money.dart`'s sibling — or a new
`app/lib/relative_time.dart` — with its own test. Do not inline date math in
a widget.

- [ ] **Step 6: Verify**

Run: `cd app && flutter analyze --fatal-infos && flutter test`
Expected: green.

- [ ] **Step 7: Commit**

```bash
git add app/lib/offline_cache.dart app/lib/screens/home.dart app/test
git commit -m "feat(app): show last-known-good data when a load fails

Reads only, and the banner says so — offline writes need conflict
resolution against the group version counter and are not attempted here."
```

---

### Task 6: Account recovery and account management screens

**Files:**
- Modify: `app/lib/screens/login.dart` (forgot password)
- Create: `app/lib/screens/account.dart` (profile, verification, export, delete)
- Modify: `app/lib/screens/home.dart` (route to the account screen)
- Create: `app/test/screens/login_test.dart`
- Create: `app/test/screens/account_test.dart`

**Interfaces:**
- Consumes: `requestPasswordReset`, `isEmailVerified`, `requestEmailVerification`, `deleteAccount` (SDK plan Tasks 6-7); `sdk.export.groupToCsv` (SDK plan Task 9).
- Produces: `AccountScreen({required sdk, required me, required onSignedOut, required onProfileUpdated})`.

- [ ] **Step 1: Write the failing login test**

Create `app/test/screens/login_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/screens/login.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  testWidgets('forgot password sends a reset and confirms without revealing the account',
      (tester) async {
    final requested = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: LoginScreen(
        sdk: null,
        onSignedIn: (_) {},
        resetOverride: (email) async => requested.add(email),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'someone@example.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(requested, ['someone@example.com']);
    // Must not say "we sent it to your account" — that confirms the address
    // is registered to anyone who types it.
    expect(find.textContaining('If that address has an account'), findsOneWidget);
  });

  testWidgets('forgot password with an empty email asks for one first', (tester) async {
    final requested = <String>[];

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: LoginScreen(
        sdk: null,
        onSignedIn: (_) {},
        resetOverride: (email) async => requested.add(email),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(requested, isEmpty);
    expect(find.textContaining('Enter your email'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/screens/login_test.dart`
Expected: FAIL — `No named parameter with the name 'resetOverride'`.

- [ ] **Step 3: Add forgot-password to the login screen**

Add the seam and the action:

```dart
  @visibleForTesting
  final Future<void> Function(String email)? resetOverride;
```

```dart
  Future<void> _forgotPassword() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _error = 'Enter your email address first.');
      return;
    }
    final request = widget.resetOverride ?? widget.sdk!.auth.requestPasswordReset;
    await request(email);
    if (!mounted) return;
    // Deliberately non-committal: confirming that an address is registered
    // turns this button into an account-enumeration oracle.
    setState(() => _error = null);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('If that address has an account, a reset link is on its way.'),
      ),
    );
  }
```

and a `TextButton(onPressed: _forgotPassword, child: const Text('Forgot password?'))`
below the sign-in button, visible only in sign-in mode.

The reset *confirmation* (entering the emailed token) is handled by the
link in the email, which opens the server's page — the app does not need a
token-entry screen for v1. Note that in `docs/deployment.md`'s email
section if it is not already clear.

- [ ] **Step 4: Run the login test to verify it passes**

Run: `cd app && flutter test test/screens/login_test.dart`
Expected: `All tests passed!` (2 tests)

- [ ] **Step 5: Write the failing account-screen test**

Create `app/test/screens/account_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/account.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  final me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');

  testWidgets('an unverified account shows the verification prompt', (tester) async {
    var resent = 0;

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: AccountScreen(
        sdk: null,
        me: me,
        onSignedOut: () {},
        onProfileUpdated: (_) {},
        isVerifiedOverride: false,
        resendVerificationOverride: () async => resent++,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('not verified'), findsOneWidget);
    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();
    expect(resent, 1);
  });

  testWidgets('a verified account shows no prompt', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: AccountScreen(
        sdk: null,
        me: me,
        onSignedOut: () {},
        onProfileUpdated: (_) {},
        isVerifiedOverride: true,
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('not verified'), findsNothing);
  });

  testWidgets('deleting the account requires typed confirmation', (tester) async {
    var deleted = 0;

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: AccountScreen(
        sdk: null,
        me: me,
        onSignedOut: () {},
        onProfileUpdated: (_) {},
        isVerifiedOverride: true,
        deleteOverride: () async => deleted++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    // The dialog's confirm button stays disabled until DELETE is typed.
    final confirm = find.widgetWithText(FilledButton, 'Delete forever');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(find.byType(TextField).last, 'DELETE');
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(deleted, 1);
  });
}
```

- [ ] **Step 6: Run it to verify it fails**

Run: `cd app && flutter test test/screens/account_test.dart`
Expected: FAIL — `account.dart` does not exist.

- [ ] **Step 7: Build the account screen**

Create `app/lib/screens/account.dart` with four sections:

1. **Profile** — name and avatar editing. Move the existing profile-editing
   code out of `home.dart` (it currently lives behind the header avatar,
   around `home.dart:341` and `home.dart:445`) rather than writing it again.
2. **Email verification** — shown only when unverified:

```dart
        if (!_isVerified)
          Card(
            child: ListTile(
              leading: const Icon(Icons.mark_email_unread_outlined),
              title: const Text('Your email is not verified'),
              subtitle: Text('Verify ${widget.me.email} so you can recover your account '
                  'if you forget your password.'),
              trailing: TextButton(onPressed: _resendVerification, child: const Text('Resend')),
            ),
          ),
```

3. **Export** — one entry per group, calling `sdk.export.groupToCsv` and
   handing the string to the platform share sheet. **Do not add a share
   package for this**: write the CSV to a temp file and open it, or copy to
   the clipboard via `Clipboard.setData` — a clipboard copy is one stdlib
   call and covers "get these numbers into a spreadsheet". Add a share
   package only if the user asks for it later.
4. **Delete account** — a destructive tile opening a dialog whose confirm
   button is disabled until the user types `DELETE`:

```dart
  Future<void> _deleteAccount() async {
    final controller = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'This removes your account and your group memberships '
                'permanently. It cannot be undone.\n\n'
                'You must settle every outstanding balance first — the '
                'server will refuse otherwise.',
              ),
              const SizedBox(height: 12),
              const Text('Type DELETE to confirm:'),
              TextField(
                controller: controller,
                onChanged: (_) => setDialogState(() {}),
                decoration: const InputDecoration(hintText: 'DELETE'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              // Typed confirmation, not just a second tap: this is
              // irreversible and destroys data the user cannot get back.
              onPressed: controller.text == 'DELETE'
                  ? () => Navigator.of(context).pop(true)
                  : null,
              style: FilledButton.styleFrom(
                backgroundColor: Theme.of(context).colorScheme.error,
              ),
              child: const Text('Delete forever'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;

    try {
      await (widget.deleteOverride ?? widget.sdk!.auth.deleteAccount)();
      widget.onSignedOut();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Couldn't delete your account: $e")),
      );
    }
  }
```

- [ ] **Step 8: Run the account test to verify it passes**

Run: `cd app && flutter test test/screens/account_test.dart`
Expected: `All tests passed!` (3 tests)

- [ ] **Step 9: Route to it from home**

Replace home's inline profile sheet with navigation to `AccountScreen`,
passing `sdk`, `me`, `onSignedOut`, and `onProfileUpdated` straight through.

- [ ] **Step 10: Verify and commit**

Run: `cd app && flutter analyze --fatal-infos && flutter test`

```bash
git add app/lib/screens app/test/screens
git commit -m "feat(app): password reset, email verification, export, account deletion

Reset confirmation stays deliberately non-committal so the button cannot
be used to check whether an address is registered. Deletion requires
typing DELETE — it is irreversible and the server refuses it anyway while
balances are outstanding."
```

---

### Task 7: Accessibility pass

**Files:**
- Modify: `app/lib/widgets/money_text.dart` (semantic label)
- Modify: `app/lib/widgets/avatar.dart` (label or exclusion)
- Modify: `app/lib/screens/*.dart` (tap targets, icon-button labels)
- Create: `app/test/accessibility_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing later tasks depend on.

**The three things that actually break the app for a screen-reader or
low-vision user:**

1. `MoneyText` colors by sign — `+$62.10` green, `−€38.20` coral. Color is
   the only encoding of "owed to you" vs "you owe" for anyone who cannot
   distinguish them, and a screen reader reads `−€38.20` as a bare number.
2. Icon-only buttons announce as "button" with no name.
3. Tap targets under 48×48 are hard to hit with a motor impairment.

Flutter's `meetsGuideline` matchers test all three; the test below is not
decorative.

- [ ] **Step 1: Write the failing test**

Create `app/test/accessibility_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/theme.dart';
import 'package:splitcore_app/widgets/money_text.dart';

void main() {
  testWidgets('MoneyText announces direction in words, not only in color', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: const Scaffold(
        body: Column(children: [MoneyText(6210, 'USD'), MoneyText(-3820, 'EUR')]),
      ),
    ));

    final semantics = tester.getSemantics(find.byType(MoneyText).first);
    expect(semantics.label, contains('owed to you'));

    final negative = tester.getSemantics(find.byType(MoneyText).last);
    expect(negative.label, contains('you owe'));
  });

  testWidgets('meets tap target, contrast, and labelling guidelines', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: Scaffold(
        appBar: AppBar(title: const Text('Trip')),
        body: const Column(children: [MoneyText(6210, 'USD')]),
        floatingActionButton: FloatingActionButton(
          onPressed: () {},
          tooltip: 'Add expense',
          child: const Icon(Icons.add),
        ),
      ),
    ));

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    handle.dispose();
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/accessibility_test.dart`
Expected: FAIL — the semantics label is the raw `+$62.10`, with no direction word.

- [ ] **Step 3: Give MoneyText a semantic label**

In `app/lib/widgets/money_text.dart`, wrap the `Text` in `Semantics`:

```dart
    // The sign is encoded as color (green/coral) and a glyph. Neither
    // reaches a screen reader, and color alone fails for anyone who cannot
    // distinguish the two — so the direction is stated in words.
    return Semantics(
      label: signed && cents != 0
          ? '${formatMoney(cents.abs(), currency)} ${cents > 0 ? 'owed to you' : 'you owe'}'
          : formatMoney(cents, currency),
      excludeSemantics: true,
      child: Text(...),   // the existing Text, unchanged
    );
```

Use whatever `money.dart` already exposes for formatting — do not add a
second formatter.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/accessibility_test.dart`
Expected: `All tests passed!` (2 tests)

- [ ] **Step 5: Sweep the screens**

For each file in `app/lib/screens/` and `app/lib/widgets/`:

- Every `IconButton` gets a `tooltip:`.
- Every decorative image or avatar gets `excludeFromSemantics: true`, or a
  real label when it identifies a person (`Semantics(label: 'Sam's avatar')`).
- Every tappable smaller than 48×48 gets wrapped so its hit area reaches it
  (`ConstrainedBox(constraints: const BoxConstraints(minWidth: 48, minHeight: 48))`).
- Every `TextField` gets a `labelText` or `hintText` that names it.

Run the guideline matchers against each migrated screen test from Tasks 2-6
by adding these four lines to each:

```dart
    final handle = tester.ensureSemantics();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
```

- [ ] **Step 6: Verify and commit**

Run: `cd app && flutter test`

```bash
git add app/lib app/test/accessibility_test.dart
git commit -m "feat(app): accessibility pass

MoneyText encoded owed-vs-owing in color alone, which is invisible to a
screen reader and to anyone who cannot distinguish the two colors. Also
labels every icon button and brings tap targets to 48dp."
```

---

### Task 8: Localization

**Files:**
- Create: `app/l10n.yaml`
- Create: `app/lib/l10n/app_en.arb`
- Create: `app/lib/l10n/app_ur.arb`
- Modify: `app/pubspec.yaml` (add `flutter_localizations`, `generate: true`)
- Modify: `app/lib/main.dart` (localization delegates + supported locales)
- Modify: every screen (literals → lookups)
- Create: `app/test/l10n_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppLocalizations.of(context)!` available in every widget.

**Why Urdu as the second locale:** it exercises right-to-left layout, which
is where hardcoded `EdgeInsets.only(left:)` and `Alignment.centerLeft`
break. A second LTR language would prove the plumbing works without
catching any of the real bugs. Use `EdgeInsetsDirectional` and
`AlignmentDirectional` throughout.

**Note:** `intl: ^0.19.0` is already a dependency and is used for date
formatting in `activity.dart` and `money.dart` — those call sites already
work per-locale once a locale is actually set.

- [ ] **Step 1: Configure generation**

Create `app/l10n.yaml`:

```yaml
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
```

In `app/pubspec.yaml`, add under `dependencies`:

```yaml
  flutter_localizations:
    sdk: flutter
```

and under the `flutter:` section:

```yaml
  generate: true
```

- [ ] **Step 2: Write the English template**

Create `app/lib/l10n/app_en.arb`:

```json
{
  "@@locale": "en",
  "appTitle": "Splitcore",
  "signIn": "Sign in",
  "signUp": "Sign up",
  "forgotPassword": "Forgot password?",
  "resetSent": "If that address has an account, a reset link is on its way.",
  "enterEmailFirst": "Enter your email address first.",
  "yourGroups": "Your groups",
  "newGroup": "New group",
  "addExpense": "Add expense",
  "editExpense": "Edit expense",
  "saveChanges": "Save changes",
  "settleUp": "Settle up",
  "deleteExpenseTitle": "Delete this expense?",
  "deleteExpenseBody": "\"{description}\" will be removed and everyone's balances will be recalculated. This cannot be undone.",
  "@deleteExpenseBody": {
    "placeholders": { "description": { "type": "String" } }
  },
  "delete": "Delete",
  "cancel": "Cancel",
  "retry": "Retry",
  "somethingWentWrong": "Something went wrong.",
  "couldntLoadGroups": "Couldn't load your groups.",
  "couldntLoadGroup": "Couldn't load this group.",
  "offlineBanner": "You're offline — showing saved data.",
  "searchExpenses": "Search expenses",
  "noMatches": "No expenses match.",
  "showOlder": "{count, plural, =1{Show 1 older expense} other{Show {count} older expenses}}",
  "@showOlder": {
    "placeholders": { "count": { "type": "int" } }
  },
  "emailNotVerified": "Your email is not verified",
  "resend": "Resend",
  "deleteAccount": "Delete account",
  "deleteAccountConfirm": "Type DELETE to confirm:",
  "owedToYou": "owed to you",
  "youOwe": "you owe"
}
```

- [ ] **Step 3: Write the Urdu translation**

Create `app/lib/l10n/app_ur.arb` with the same keys and Urdu values, e.g.:

```json
{
  "@@locale": "ur",
  "appTitle": "سپلٹ کور",
  "signIn": "سائن ان",
  "signUp": "اکاؤنٹ بنائیں",
  "forgotPassword": "پاس ورڈ بھول گئے؟",
  "retry": "دوبارہ کوشش کریں",
  "cancel": "منسوخ کریں",
  "delete": "حذف کریں"
}
```

Untranslated keys fall back to English automatically — a partial second
locale is a working second locale, and a wrong machine translation of a
money confirmation dialog is worse than English.

- [ ] **Step 4: Wire up the delegates**

In `app/lib/main.dart`:

```dart
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
```

and on the `MaterialApp`:

```dart
      onGenerateTitle: (context) => AppLocalizations.of(context)!.appTitle,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
```

Delete the hardcoded `title: 'SlicePay'`.

- [ ] **Step 5: Write the test**

Create `app/test/l10n_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Locale locale) => MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: Column(
              children: [
                Text(AppLocalizations.of(context)!.retry),
                Text(AppLocalizations.of(context)!.showOlder(3)),
              ],
            ),
          ),
        ),
      );

  testWidgets('English strings resolve, including plurals', (tester) async {
    await tester.pumpWidget(host(const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Show 3 older expenses'), findsOneWidget);
  });

  testWidgets('a singular plural form is used for one', (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Text(AppLocalizations.of(context)!.showOlder(1)),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Show 1 older expense'), findsOneWidget);
  });

  testWidgets('Urdu resolves and lays out right-to-left', (tester) async {
    await tester.pumpWidget(host(const Locale('ur')));
    await tester.pumpAndSettle();

    expect(find.text('دوبارہ کوشش کریں'), findsOneWidget);
    expect(Directionality.of(tester.element(find.byType(Scaffold))), TextDirection.rtl);
  });
}
```

- [ ] **Step 6: Generate and run**

Run:
```bash
cd app && flutter pub get && flutter gen-l10n && flutter test test/l10n_test.dart
```
Expected: `All tests passed!` (3 tests)

- [ ] **Step 7: Replace the literals**

Screen by screen, replace every user-visible string literal with its
`AppLocalizations.of(context)!.<key>` lookup, adding keys to `app_en.arb`
as needed. Convert every directional layout value while you are in the
file: `EdgeInsets.only(left:/right:)` → `EdgeInsetsDirectional.only(start:/end:)`,
`Alignment.centerLeft` → `AlignmentDirectional.centerStart`,
`TextAlign.left` → `TextAlign.start`.

Verify nothing was missed:

```bash
cd /home/abdul/Projects/slice_pay
grep -rn "EdgeInsets.only(left\|EdgeInsets.only(right\|Alignment.centerLeft\|Alignment.centerRight" app/lib
```
Expected: no output.

- [ ] **Step 8: Verify and commit**

Run: `cd app && flutter analyze --fatal-infos && flutter test`

```bash
git add app/l10n.yaml app/lib app/pubspec.yaml app/test/l10n_test.dart
git commit -m "feat(app): localization with English and Urdu

Urdu specifically, because RTL is what catches hardcoded left/right
padding and alignment — a second LTR language would prove the plumbing
works and catch none of the real bugs."
```

---

### Task 9: Fill the remaining test gaps

**Files:**
- Create: `app/test/screens/settle_up_test.dart`
- Create: `app/test/screens/new_group_test.dart`
- Create: `app/test/error_states_test.dart`

**Interfaces:**
- Consumes: the loader-override seams from Tasks 2-6.
- Produces: nothing.

The repository review asked for tests covering authentication, groups,
expenses, settlements, offline behavior, and error states. After Tasks 1-8:
auth (Task 6), groups (Task 2), expenses (Tasks 2-4), offline (Task 5), and
error states (Tasks 1-2) are covered. **Settlements and group creation are
not.** This task closes those two, plus a consolidated error-state sweep.

- [ ] **Step 1: Write the settle-up test**

Create `app/test/screens/settle_up_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/settle_up.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  final members = [
    GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me', avatarUrl: ''),
    GroupMember(id: 'm2', groupId: 'g1', userId: 'u2', role: 'member', name: 'Sam', avatarUrl: ''),
  ];
  final group = Group(id: 'g1', name: 'Trip', currency: 'USD', isDirect: false, version: 3);

  testWidgets('shows the suggested transfers from the engine', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: SettleUpScreen(
        sdk: null,
        group: group,
        members: members,
        me: AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: ''),
        transfersOverride: () async => [
          const Transfer(fromMemberId: 'm2', toMemberId: 'm1', amountCents: 2500),
        ],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sam'), findsWidgets);
    expect(find.textContaining('25.00'), findsOneWidget);
  });

  testWidgets('an already-settled group says so instead of showing an empty list',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: SettleUpScreen(
        sdk: null,
        group: group,
        members: members,
        me: AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: ''),
        transfersOverride: () async => const [],
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('settled'), findsOneWidget);
  });

  testWidgets('a failed transfer computation offers retry', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: SettleUpScreen(
        sdk: null,
        group: group,
        members: members,
        me: AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: ''),
        transfersOverride: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return const [];
        },
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(attempts, 2);
  });
}
```

Add the matching `transfersOverride` seam and `Loadable` migration to
`settle_up.dart`, exactly as Task 2 did for the other screens.

- [ ] **Step 2: Run it, implement the seam, run it again**

Run: `cd app && flutter test test/screens/settle_up_test.dart`
Expected: FAIL first (`No named parameter 'transfersOverride'`), PASS after
the seam is added.

- [ ] **Step 3: Write the group-creation test**

Create `app/test/screens/new_group_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/screens/new_group.dart';
import 'package:splitcore_app/theme.dart';

void main() {
  testWidgets('an empty name is rejected before any request is made', (tester) async {
    var created = 0;

    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: NewGroupScreen(
        sdk: null,
        createOverride: (name, currency, invites) async => created++,
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(created, 0);
    expect(find.textContaining('Enter a group name'), findsOneWidget);
  });

  testWidgets('a partially failed invite still reports the group was created',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: sliceLightTheme(),
      home: NewGroupScreen(
        sdk: null,
        createOverride: (name, currency, invites) async =>
            throw StateError("Group created, but couldn't invite: sam@example.com"),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'Trip');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Group created'), findsOneWidget);
  });
}
```

`new_group.dart:69` already produces that partial-failure message — this test
pins the behavior so a refactor cannot silently turn a partial success into a
total failure.

- [ ] **Step 4: Write the error-state sweep**

Create `app/test/error_states_test.dart` asserting that each migrated screen
renders a retry affordance when its loader throws — home, group detail,
activity, settle up. One `testWidgets` per screen, each following the shape
already used in `group_detail_test.dart`.

- [ ] **Step 5: Verify coverage of the review's list**

Run: `cd app && flutter test`
Expected: all pass. Then confirm each item the review named has a test:

| Area | Test |
|---|---|
| Authentication | `test/screens/login_test.dart`, `test/screens/account_test.dart` |
| Groups | `test/screens/home_test.dart`, `test/screens/new_group_test.dart` |
| Expenses | `test/screens/group_detail_test.dart`, `test/screens/add_expense_test.dart` |
| Settlements | `test/screens/settle_up_test.dart` |
| Offline behavior | `test/offline_cache_test.dart` |
| Error states | `test/error_states_test.dart`, `test/widgets/async_section_test.dart` |

- [ ] **Step 6: Commit**

```bash
git add app/lib/screens/settle_up.dart app/lib/screens/new_group.dart app/test
git commit -m "test(app): cover settlements, group creation, and error states

Completes the coverage the repository review asked for: auth, groups,
expenses, settlements, offline, and error states each have a test."
```

---

### Task 10: Update the docs and changelog

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `README.md` (roadmap section)
- Modify: `app/README.md` (localization + test notes)

- [ ] **Step 1: Update the changelog**

Under `## [Unreleased]` → `### Added` in `CHANGELOG.md`:

```markdown
- Expense editing and deletion, with a confirmation on delete.
- Search within a group's expenses, and paging for long expense lists.
- Offline reads: the last successful load is shown with a banner when a
  refresh fails.
- Password reset, email-verification prompt, CSV export, and account
  deletion, in a new Account screen.
- Localization (English and Urdu) with full RTL layout support.
- Accessibility: semantic labels for money direction, labelled icon
  buttons, 48dp tap targets.
- Widget tests for every screen, including error and retry states.
```

Under `### Changed`:

```markdown
- Screens share one `Loadable`/`AsyncSection` pair instead of each
  hand-rolling a (data, error, loading) triple; every screen now has a
  retry path and can be widget-tested without a server.
```

- [ ] **Step 2: Update the README roadmap**

Replace the three roadmap bullets in `README.md` with what is now true, and
list what remains: offline writes, receipt replacement/deletion, load
testing, and monitoring beyond the health check.

- [ ] **Step 3: Note the new workflows in app/README.md**

Add a localization section (how to add a string: edit `lib/l10n/app_en.arb`,
run `flutter gen-l10n`, use `AppLocalizations.of(context)!.<key>`) and a
testing note (screens take a `loadOverride` so tests inject fixtures instead
of a live SDK).

- [ ] **Step 4: Verify and commit**

Run: `cd /home/abdul/Projects/slice_pay && make check`

```bash
git add CHANGELOG.md README.md app/README.md
git commit -m "docs: record the app usability work and refresh the roadmap"
```

---

## Self-review checklist for the implementer

1. `grep -rn "setState" app/lib/screens | wc -l` is substantially lower than the 30 it started at — anything left should be genuinely local UI state (a text field, an expanded panel), not a fetch result.
2. Every screen file has a matching `app/test/screens/*_test.dart`.
3. `grep -rn "EdgeInsets.only(left\|Alignment.centerLeft" app/lib` → no output.
4. `grep -rn "pocketbase" app/lib` → no output.
5. Every user-visible string added by this plan resolves through `AppLocalizations`.
6. `make check` passes.

## What this plan does NOT cover

- **Offline writes.** Queueing an expense created offline and reconciling it against the group's server-side version counter on reconnect is a project of its own. Task 5 delivers reads and says so in the UI.
- **Receipt replacement and deletion.** `attachReceipt` and `receiptUrl` exist; changing or removing a receipt afterwards does not.
- **Load testing and recompute performance.** `bumpAndRecompute` rewrites every balance row for a group on every write. Correct, and fine at realistic group sizes. Measure before optimizing.
- **Push notifications, group archiving, recurring expenses, multi-currency within one group.** Not in the review, not planned.
