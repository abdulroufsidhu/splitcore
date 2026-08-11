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

Widget _host({
  required Future<GroupDetailData> Function() load,
  AppUser me = _me,
  Future<String> Function(String memberId)? removeMember,
}) => MaterialApp(
  theme: sliceLightTheme(),
  home: GroupDetailScreen(
    sdk: null,
    me: me,
    group: _group,
    loadOverride: load,
    removeMemberOverride: removeMember,
  ),
);

/// Opens the member sheet for Sam (m2), who is not the group's owner.
Future<void> _openSamsSheet(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.text('Sam'));
  await tester.pumpAndSettle();
}

GroupDetailData _data({int samNetCents = 0, List<GroupMember> former = const []}) =>
    GroupDetailData(
      members: _members,
      formerMembers: former,
      balances: [Balance(memberId: 'm2', netCents: samNetCents)],
      expenses: const <Expense>[],
      settlements: const <Settlement>[],
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

  testWidgets('the owner can remove a settled member', (tester) async {
    final removed = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(),
        removeMember: (id) async {
          removed.add(id);
          return 'removed';
        },
      ),
    );
    await _openSamsSheet(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove from group'));
    await tester.pumpAndSettle();
    // Removal is confirmed before it happens, never on the first tap.
    expect(removed, isEmpty);

    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();

    expect(removed, ['m2']);
  });

  testWidgets('cancelling the confirmation removes nobody', (tester) async {
    final removed = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(),
        removeMember: (id) async {
          removed.add(id);
          return 'removed';
        },
      ),
    );
    await _openSamsSheet(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Remove from group'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(removed, isEmpty);
  });

  testWidgets('a member who owes money cannot be removed, and is told why', (tester) async {
    await tester.pumpWidget(_host(load: () async => _data(samNetCents: -1250)));
    await _openSamsSheet(tester);

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining('unsettled balance'), findsOneWidget);
  });

  testWidgets('a non-owner is offered no removal at all', (tester) async {
    const notTheOwner = AppUser(id: 'u2', email: 'sam@example.com', name: 'Sam', avatarUrl: '');
    await tester.pumpWidget(_host(load: () async => _data(), me: notTheOwner));
    await tester.pumpAndSettle();
    // Sam is "You" from this account, so open the other card.
    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining('Only the group owner'), findsOneWidget);
  });

  testWidgets("the group's owner is never removable", (tester) async {
    await tester.pumpWidget(_host(load: () async => _data()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining("owner can't be removed"), findsOneWidget);
  });

  testWidgets('former members stay visible as a muted line', (tester) async {
    const gone = GroupMember(
      id: 'm3',
      groupId: 'g1',
      userId: 'u3',
      role: 'member',
      name: 'Robin',
      isActive: false,
    );
    await tester.pumpWidget(_host(load: () async => _data(former: const [gone])));
    await tester.pumpAndSettle();

    expect(find.textContaining('Former members: Robin'), findsOneWidget);
  });
}
