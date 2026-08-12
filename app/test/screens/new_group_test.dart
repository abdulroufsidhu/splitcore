import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/new_group.dart';
import 'package:splitcore_app/theme.dart';

/// Pushes the screen onto a second route, so its closing pop has something
/// to pop back to.
Widget _host({required List<String> invited}) => MaterialApp(
  theme: sliceLightTheme(),
  home: Builder(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => NewGroupScreen(
              sdk: null,
              createOverride: ({required String name, required String currency}) async =>
                  Group(id: 'g1', name: name, currency: currency, version: 1, ownerId: 'u1'),
              inviteOverride: ({required String groupId, required String email}) async {
                invited.add(email);
                return true;
              },
            ),
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ),
);

Future<void> _openAndFill(WidgetTester tester, {required String email}) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();

  await tester.enterText(find.byType(TextField).first, 'Trip');
  await tester.enterText(find.widgetWithText(TextField, 'Invite by email'), email);
  await tester.pump();
}

void main() {
  testWidgets('an email typed but never "+"-ed is still invited on create', (tester) async {
    // Regression: only the + button and the keyboard's submit key committed
    // an address to the pending list, so typing one and going straight for
    // "Create group" created the group with nobody invited — silently.
    final invited = <String>[];
    await tester.pumpWidget(_host(invited: invited));
    await _openAndFill(tester, email: 'friend@example.com');

    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await tester.pumpAndSettle();

    expect(invited, ['friend@example.com']);
  });

  testWidgets('an email committed with + is invited exactly once', (tester) async {
    final invited = <String>[];
    await tester.pumpWidget(_host(invited: invited));
    await _openAndFill(tester, email: 'friend@example.com');

    await tester.tap(find.byTooltip('Add this email'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Create group'));
    await tester.pumpAndSettle();

    // Flushing the field on create must not re-add an address already
    // sitting in the chip list.
    expect(invited, ['friend@example.com']);
  });
}
