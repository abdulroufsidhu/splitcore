import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/screens/login.dart';
import 'package:splitcore_app/theme.dart';

Widget _host({required Future<void> Function(String email) reset}) => MaterialApp(
  theme: sliceLightTheme(),
  home: LoginScreen(sdk: null, onSignedIn: (_) {}, resetOverride: reset),
);

void main() {
  testWidgets('forgot password sends a reset without revealing the account', (tester) async {
    final requested = <String>[];

    await tester.pumpWidget(_host(reset: (email) async => requested.add(email)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'someone@example.com');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(requested, ['someone@example.com']);
    // Must not confirm the address exists — that would turn this button
    // into an account-enumeration oracle.
    expect(find.textContaining('If that address has an account'), findsOneWidget);
  });

  testWidgets('forgot password with an empty email asks for one first', (tester) async {
    final requested = <String>[];

    await tester.pumpWidget(_host(reset: (email) async => requested.add(email)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(requested, isEmpty);
    expect(find.textContaining('Enter your email'), findsOneWidget);
  });

  testWidgets('the reset affordance is hidden while creating an account', (tester) async {
    await tester.pumpWidget(_host(reset: (email) async {}));
    await tester.pumpAndSettle();

    expect(find.text('Forgot password?'), findsOneWidget);

    await tester.tap(find.text('New here? Create account'));
    await tester.pumpAndSettle();

    // Nothing to reset for an account that does not exist yet.
    expect(find.text('Forgot password?'), findsNothing);
  });

  testWidgets('a whitespace-only email is treated as empty', (tester) async {
    final requested = <String>[];

    await tester.pumpWidget(_host(reset: (email) async => requested.add(email)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(find.text('Forgot password?'));
    await tester.pumpAndSettle();

    expect(requested, isEmpty);
  });
}
