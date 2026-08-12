// Flutter's navigator also exports a `Page`; the SDK's paging type is the
// one this screen deals in.
import 'package:flutter/material.dart' hide Page;
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/group_detail.dart';
import 'package:splitcore_app/theme.dart';

const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');
const _members = [GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me')];
final _group = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 1, ownerId: 'u1');

Expense _expense(String id, String description) => Expense(
  id: id,
  groupId: 'g1',
  payerMemberId: 'm1',
  description: description,
  amountCents: 5000,
  splitType: 'equal',
  date: DateTime.utc(2026, 7, 1),
);

Widget _host({
  required Future<List<Expense>> Function(String query) search,
  List<Expense> initial = const [],
}) => MaterialApp(
  theme: sliceLightTheme(),
  home: GroupDetailScreen(
    sdk: null,
    me: _me,
    group: _group,
    loadOverride: () async => GroupDetailData(
      members: _members,
      balances: const [],
      expenses: initial,
      settlements: const <Settlement>[],
    ),
    searchOverride: search,
  ),
);

void main() {
  testWidgets('typing a query searches once, after the debounce', (tester) async {
    final queries = <String>[];

    await tester.pumpWidget(
      _host(
        search: (query) async {
          queries.add(query);
          return const [];
        },
      ),
    );
    await tester.pumpAndSettle();

    final field = find.byType(TextField).first;
    await tester.enterText(field, 'din');
    await tester.enterText(field, 'dinn');
    await tester.enterText(field, 'dinner');
    await tester.pump(const Duration(milliseconds: 100));

    expect(queries, isEmpty, reason: 'searched before the debounce elapsed');

    await tester.pump(const Duration(milliseconds: 400));

    expect(queries, ['dinner'], reason: 'one search for the final text, not three');
  });

  testWidgets('results replace the activity list', (tester) async {
    await tester.pumpWidget(
      _host(
        initial: [_expense('e1', 'Groceries')],
        search: (query) async => [_expense('e2', 'Dinner')],
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'dinner');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Dinner'), findsOneWidget);
    expect(find.text('Groceries'), findsNothing);
  });

  testWidgets('clearing the query restores the full list without searching', (tester) async {
    var searches = 0;

    await tester.pumpWidget(
      _host(
        initial: [_expense('e1', 'Groceries')],
        search: (query) async {
          searches++;
          return [_expense('e2', 'Dinner')];
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'dinner');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(searches, 1);

    await tester.enterText(find.byType(TextField).first, '');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    expect(searches, 1, reason: 'an empty query must not hit the server');
  });

  testWidgets('a query with no matches says so instead of looking broken', (tester) async {
    await tester.pumpWidget(
      _host(initial: [_expense('e1', 'Groceries')], search: (query) async => const []),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'nothing matches this');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();

    expect(find.textContaining('No expenses match'), findsOneWidget);
  });
}
