import 'package:flutter/material.dart' hide Split;
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/add_expense.dart';
import 'package:splitcore_app/theme.dart';

const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');
const _members = [
  GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Me'),
  GroupMember(id: 'm2', groupId: 'g1', userId: 'u2', role: 'member', name: 'Sam'),
];
final _group = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 1, ownerId: 'u1');

final _existing = Expense(
  id: 'e1',
  groupId: 'g1',
  payerMemberId: 'm2',
  description: 'Dinner',
  amountCents: 4250,
  splitType: 'equal',
  date: DateTime.utc(2026, 7, 1),
);

const _existingSplits = [
  SplitEntry(id: 's1', expenseId: 'e1', memberId: 'm1', amountCents: 2125),
  SplitEntry(id: 's2', expenseId: 'e1', memberId: 'm2', amountCents: 2125),
];

Widget _host({Expense? existing, List<SplitEntry>? splits}) => MaterialApp(
  theme: sliceLightTheme(),
  home: AddExpenseScreen(
    sdk: null,
    group: _group,
    members: _members,
    me: _me,
    existing: existing,
    existingSplits: splits,
  ),
);

void main() {
  testWidgets('editing pre-fills the description and amount from the expense', (tester) async {
    await tester.pumpWidget(_host(existing: _existing, splits: _existingSplits));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(TextField, 'Dinner'), findsOneWidget);
    // 4250 minor units must render as 42.50, never 42.5 or a float artifact.
    expect(find.widgetWithText(TextField, '42.50'), findsOneWidget);
  });

  testWidgets('editing announces itself as an edit, not a new expense', (tester) async {
    await tester.pumpWidget(_host(existing: _existing, splits: _existingSplits));
    await tester.pumpAndSettle();

    expect(find.text('Edit expense'), findsOneWidget);
    expect(find.text('New expense'), findsNothing);
  });

  testWidgets('creating shows the new-expense affordances and empty fields', (tester) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('New expense'), findsOneWidget);
    expect(find.text('Edit expense'), findsNothing);
    expect(find.widgetWithText(TextField, 'Dinner'), findsNothing);
  });

  testWidgets('editing restores the original payer, not the signed-in user', (tester) async {
    await tester.pumpWidget(_host(existing: _existing, splits: _existingSplits));
    await tester.pumpAndSettle();

    // Sam (m2) paid; the screen must not silently reassign that to Me.
    final state = tester.state<AddExpenseScreenState>(find.byType(AddExpenseScreen));
    expect(state.debugPayerMemberId, 'm2');
  });
}
