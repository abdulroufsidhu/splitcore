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

/// Sam, signed in as themselves — a plain member, not the group's owner.
const _sam = AppUser(id: 'u2', email: 'sam@example.com', name: 'Sam', avatarUrl: '');

/// A third party, so "a member acting on someone else" is neither the
/// caller nor the owner.
const _withRobin = [
  ..._members,
  GroupMember(id: 'm3', groupId: 'g1', userId: 'u3', role: 'member', name: 'Robin'),
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
  Future<String> Function(String memberId)? transferOwnership,
  Future<void> Function()? deleteGroup,
  int unsent = 0,
}) => MaterialApp(
  theme: sliceLightTheme(),
  home: GroupDetailScreen(
    sdk: null,
    me: me,
    group: _group,
    loadOverride: load,
    removeMemberOverride: removeMember,
    transferOwnershipOverride: transferOwnership,
    deleteGroupOverride: deleteGroup,
    unsentCountOverride: () async => unsent,
  ),
);

/// Opens the app bar's overflow menu, which only the owner has.
Future<void> _openGroupMenu(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.tap(find.byType(PopupMenuButton<String>));
  await tester.pumpAndSettle();
}

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

  testWidgets("a plain member tapping the owner's card is offered nothing", (tester) async {
    await tester.pumpWidget(_host(load: () async => _data(), me: _sam));
    await tester.pumpAndSettle();
    // Sam is "You" from this account, so open the other card.
    await tester.tap(find.text('Me'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining("owner can't be removed"), findsOneWidget);
  });

  testWidgets("the group's owner is never removable", (tester) async {
    await tester.pumpWidget(_host(load: () async => _data()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Leave group'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining('You own this group'), findsOneWidget);
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

  testWidgets('nobody can be removed while writes are still unsent', (tester) async {
    // The server judges a removal on what it can see. A queued expense that
    // splits with this member is invisible to it, so they would look like
    // someone with no history and nothing owed, get deleted outright, and
    // take the queued expense down with them when it failed to replay.
    final removed = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(),
        unsent: 2,
        removeMember: (id) async {
          removed.add(id);
          return 'removed';
        },
      ),
    );
    await _openSamsSheet(tester);

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining("haven't reached the server"), findsOneWidget);
    expect(removed, isEmpty);
  });

  testWidgets('the group owner is tagged in the member strip', (tester) async {
    await tester.pumpWidget(_host(load: () async => _data()));
    await tester.pumpAndSettle();

    // Exactly one card carries it — the tag marks the owner, not everybody.
    expect(find.text('OWNER'), findsOneWidget);
  });

  testWidgets('a plain member can leave, and the screen closes behind them', (tester) async {
    final left = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(),
        me: _sam,
        removeMember: (id) async {
          left.add(id);
          return 'removed';
        },
      ),
    );
    await tester.pumpAndSettle();
    // Sam's own card reads "You" from this account.
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Leave group'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Leave group'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Leave'));
    await tester.pumpAndSettle();

    expect(left, ['m2']);
  });

  testWidgets('a plain member still cannot remove a third party', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _withRobin,
          balances: const [Balance(memberId: 'm3', netCents: 0)],
          expenses: const <Expense>[],
          settlements: const <Settlement>[],
        ),
        me: _sam,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    expect(find.textContaining('Only the group owner'), findsOneWidget);
  });

  testWidgets('leaving is blocked while you still owe money', (tester) async {
    await tester.pumpWidget(_host(load: () async => _data(samNetCents: -800), me: _sam));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Leave group'), findsNothing);
    expect(find.textContaining('Settle up before leaving'), findsOneWidget);
  });

  // ------------------------------------------------------------------
  // Deleting the group
  // ------------------------------------------------------------------

  testWidgets('only the owner is offered the group menu', (tester) async {
    await tester.pumpWidget(_host(load: () async => _data(), me: _sam));
    await tester.pumpAndSettle();

    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('the owner can delete a settled group, after confirming', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(_host(load: () async => _data(), deleteGroup: () async => deleted++));
    await _openGroupMenu(tester);

    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();
    // Confirmed before it happens: this destroys everyone's history.
    expect(deleted, 0);
    expect(find.textContaining('not just for you'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(deleted, 1);
  });

  testWidgets('cancelling the confirmation deletes nothing', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(_host(load: () async => _data(), deleteGroup: () async => deleted++));
    await _openGroupMenu(tester);
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(deleted, 0);
  });

  testWidgets('a group where money is owed cannot be deleted, and says why', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(
      _host(load: () async => _data(samNetCents: -1250), deleteGroup: () async => deleted++),
    );
    await _openGroupMenu(tester);
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Settle up before deleting'), findsOneWidget);
    // The reason replaces the confirmation rather than following a tap on it.
    expect(find.widgetWithText(TextButton, 'Delete'), findsNothing);
    expect(deleted, 0);
  });

  testWidgets('unsent writes block the delete', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(
      _host(load: () async => _data(), unsent: 2, deleteGroup: () async => deleted++),
    );
    await _openGroupMenu(tester);
    await tester.tap(find.text('Delete group'));
    await tester.pumpAndSettle();

    expect(find.textContaining("haven't reached the server"), findsOneWidget);
    expect(deleted, 0);
  });

  // ------------------------------------------------------------------
  // Handing the group over
  // ------------------------------------------------------------------

  testWidgets('the owner can make another member the owner', (tester) async {
    final handedTo = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(),
        transferOwnership: (id) async {
          handedTo.add(id);
          return 'transferred';
        },
      ),
    );
    await _openSamsSheet(tester);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Make owner'));
    await tester.pumpAndSettle();
    expect(handedTo, isEmpty, reason: 'handing over is confirmed first');

    await tester.tap(find.widgetWithText(TextButton, 'Make owner'));
    await tester.pumpAndSettle();

    expect(handedTo, ['m2']);
  });

  testWidgets('the owner cannot hand the group to themselves', (tester) async {
    await tester.pumpWidget(_host(load: () async => _data()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('You'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Make owner'), findsNothing);
  });

  testWidgets('a plain member cannot hand the group to anyone', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => GroupDetailData(
          members: _withRobin,
          balances: const [Balance(memberId: 'm3', netCents: 0)],
          expenses: const <Expense>[],
          settlements: const <Settlement>[],
        ),
        me: _sam,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Robin'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(OutlinedButton, 'Make owner'), findsNothing);
  });

  // An outstanding balance stops a removal but not a handover: transferring
  // moves no money, and it is exactly what an owner who wants out has to do
  // first.
  testWidgets('a member who owes money can still be made owner', (tester) async {
    final handedTo = <String>[];
    await tester.pumpWidget(
      _host(
        load: () async => _data(samNetCents: -1250),
        transferOwnership: (id) async {
          handedTo.add(id);
          return 'transferred';
        },
      ),
    );
    await _openSamsSheet(tester);

    expect(find.widgetWithText(FilledButton, 'Remove from group'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Make owner'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Make owner'));
    await tester.pumpAndSettle();

    expect(handedTo, ['m2']);
  });
}
