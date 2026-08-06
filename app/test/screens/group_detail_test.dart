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

Widget _host({required Future<GroupDetailData> Function() load}) => MaterialApp(
  theme: sliceLightTheme(),
  home: GroupDetailScreen(sdk: null, me: _me, group: _group, loadOverride: load),
);

void main() {
  testWidgets('renders the group name, members and its activity', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [Balance(memberId: 'm1', netCents: 2500)],
          expenses: [_expense('e1', 'Dinner')],
          settlements: const <Settlement>[],
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
            expenses: const [],
            settlements: const <Settlement>[],
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

  testWidgets('a single-page list offers no load-more affordance', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _members,
          balances: const [],
          expenses: [_expense('e1', 'Dinner')],
          settlements: const <Settlement>[],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('older'), findsNothing);
  });
}
