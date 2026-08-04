import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/account.dart';
import 'package:splitcore_app/theme.dart';

const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');
final _groups = [Group(id: 'g1', name: 'Trip', currency: 'USD', version: 1, ownerId: 'u1')];

Widget _host({
  bool verified = true,
  Future<void> Function()? resend,
  Future<String> Function()? deleteAccount,
  Future<String> Function(String groupId)? exportCsv,
  VoidCallback? onSignedOut,
}) => MaterialApp(
  theme: sliceLightTheme(),
  home: AccountScreen(
    sdk: null,
    me: _me,
    groups: _groups,
    onSignedOut: onSignedOut ?? () {},
    isVerifiedOverride: verified,
    resendVerificationOverride: resend,
    deleteOverride: deleteAccount,
    exportOverride: exportCsv,
  ),
);

void main() {
  testWidgets('an unverified account shows the prompt and can resend', (tester) async {
    var resent = 0;

    await tester.pumpWidget(_host(verified: false, resend: () async => resent++));
    await tester.pumpAndSettle();

    expect(find.textContaining('not verified'), findsOneWidget);

    await tester.tap(find.text('Resend'));
    await tester.pumpAndSettle();
    expect(resent, 1);
  });

  testWidgets('a verified account shows no prompt', (tester) async {
    await tester.pumpWidget(_host(verified: true));
    await tester.pumpAndSettle();

    expect(find.textContaining('not verified'), findsNothing);
  });

  testWidgets('deleting requires typing DELETE before the button arms', (tester) async {
    var deleted = 0;

    await tester.pumpWidget(
      _host(
        deleteAccount: () async {
          deleted++;
          return 'deleted';
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();

    final confirm = find.widgetWithText(FilledButton, 'Delete forever');
    expect(
      tester.widget<FilledButton>(confirm).onPressed,
      isNull,
      reason: 'irreversible action armed without typed confirmation',
    );

    await tester.enterText(find.byType(TextField).last, 'DELETE');
    await tester.pumpAndSettle();

    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(deleted, 1);
  });

  testWidgets('cancelling the delete dialog deletes nothing', (tester) async {
    var deleted = 0;

    await tester.pumpWidget(
      _host(
        deleteAccount: () async {
          deleted++;
          return 'deleted';
        },
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(deleted, 0);
  });

  testWidgets('an anonymized outcome is reported honestly, not as a deletion', (tester) async {
    await tester.pumpWidget(_host(deleteAccount: () async => 'anonymized'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'DELETE');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete forever'));
    await tester.pumpAndSettle();

    // The server kept the membership rows so other people's balances stay
    // correct. Claiming "everything was deleted" would be a lie.
    expect(find.textContaining('anonymized'), findsOneWidget);
  });

  testWidgets('exporting a group copies its CSV to the clipboard', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (
      call,
    ) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(_host(exportCsv: (groupId) async => 'date,type\n2026-07-01,expense'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(copied.single, contains('date,type'));
    expect(find.textContaining('Copied'), findsOneWidget);
  });
}
