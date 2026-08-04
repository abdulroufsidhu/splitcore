// Flutter's navigator also exports a `Page`; the SDK's paging type is the
// one this screen deals in.
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/group_detail.dart';
import 'package:splitcore_app/theme.dart';

final _group = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 1, ownerId: 'u1');
const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');
const _members = [
  GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me'),
  GroupMember(id: 'm2', groupId: 'g1', userId: 'u2', role: 'member', name: 'Sam'),
];

Expense _expense(String id, String description, {int amountCents = 5000}) => Expense(
  id: id,
  groupId: 'g1',
  payerMemberId: 'm1',
  description: description,
  amountCents: amountCents,
  splitType: 'equal',
  date: DateTime.utc(2026, 7, 1),
);

Page<Expense> _page(List<Expense> items, {int page = 1, int perPage = 50, int? totalItems}) =>
    Page<Expense>(
      items: items,
      page: page,
      perPage: perPage,
      totalItems: totalItems ?? items.length,
      totalPages: ((totalItems ?? items.length) / perPage).ceil(),
    );

Widget _host({
  required Future<GroupDetailData> Function() load,
  Future<Page<Expense>> Function(int page)? loadMore,
}) => MaterialApp(
  theme: sliceLightTheme(),
  home: GroupDetailScreen(
    sdk: null,
    me: _me,
    group: _group,
    loadOverride: load,
    loadMoreOverride: loadMore,
  ),
);

void main() {
  testWidgets('renders the group name, members and its activity', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [Balance(memberId: 'm1', netCents: 2500)],
          expenses: _page([_expense('e1', 'Dinner')]),
          settlements: const Page<Settlement>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Dinner'), findsOneWidget);
  });

  testWidgets('a failed load offers a retry that succeeds', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _host(
        load: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return GroupDetailData(
            members: _members,
            balances: const [],
            expenses: _page(const []),
            settlements: const Page<Settlement>.empty(),
          );
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
    expect(attempts, 2);
  });

  testWidgets('offers to load older expenses only when more pages exist', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: _page([_expense('e1', 'Dinner')], perPage: 1, totalItems: 3),
          settlements: const Page<Settlement>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('older'), findsOneWidget);
  });

  testWidgets('a single-page list offers no load-more affordance', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: _page([_expense('e1', 'Dinner')]),
          settlements: const Page<Settlement>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('older'), findsNothing);
  });

  testWidgets('loading more appends the next page to the list', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: _page([_expense('e1', 'Newest')], perPage: 1, totalItems: 2),
          settlements: const Page<Settlement>.empty(),
        ),
        loadMore: (page) async =>
            _page([_expense('e2', 'Older')], page: page, perPage: 1, totalItems: 2),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Older'), findsNothing);

    await tester.tap(find.textContaining('older'));
    await tester.pumpAndSettle();

    // Both pages on screen at once — appended, not replaced.
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Older'), findsOneWidget);
    // Nothing left to fetch, so the affordance is gone.
    expect(find.textContaining('older expense'), findsNothing);
  });

  testWidgets('a refresh resets paging instead of stacking duplicates', (tester) async {
    var loads = 0;
    late final GroupDetailScreenState state;

    await tester.pumpWidget(
      _host(
        load: () async {
          loads++;
          return GroupDetailData(
            members: _members,
            balances: const [],
            expenses: _page([_expense('e1', 'Newest')], perPage: 1, totalItems: 2),
            settlements: const Page<Settlement>.empty(),
          );
        },
        loadMore: (page) async =>
            _page([_expense('e2', 'Older')], page: page, perPage: 1, totalItems: 2),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.textContaining('older'));
    await tester.pumpAndSettle();
    expect(find.text('Older'), findsOneWidget);

    state = tester.state<GroupDetailScreenState>(find.byType(GroupDetailScreen));
    await state.refresh();
    await tester.pumpAndSettle();

    expect(loads, 2);
    expect(find.text('Newest'), findsOneWidget);
    expect(find.text('Older'), findsNothing, reason: 'refresh kept a stale appended page');
    expect(find.textContaining('older'), findsOneWidget);
  });

  testWidgets('long-pressing an expense offers edit and delete', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: _page([_expense('e1', 'Dinner')]),
          settlements: const Page<Settlement>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Dinner'));
    await tester.pumpAndSettle();

    expect(find.text('Edit expense'), findsOneWidget);
    expect(find.text('Delete expense'), findsOneWidget);
  });

  testWidgets('deleting asks for confirmation before touching anything', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: _page([_expense('e1', 'Dinner')]),
          settlements: const Page<Settlement>.empty(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Dinner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete expense'));
    await tester.pumpAndSettle();

    // A confirmation dialog that names the consequence, not a bare "sure?".
    expect(find.text('Delete this expense?'), findsOneWidget);
    expect(find.textContaining('balances'), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);

    // Backing out leaves the expense alone — sdk is null here, so any real
    // delete call would throw.
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Dinner'), findsOneWidget);
  });
}
