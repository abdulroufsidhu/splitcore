import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/home.dart';
import 'package:splitcore_app/theme.dart';

const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');

Group _group({String id = 'g1', String name = 'Trip', String currency = 'USD'}) =>
    Group(id: id, name: name, currency: currency, version: 1, ownerId: 'u1');

Widget _host({required Future<List<GroupRow>> Function() load}) => MaterialApp(
  theme: sliceLightTheme(),
  home: HomeScreen(
    sdk: null,
    me: _me,
    onSignedOut: () {},
    onProfileUpdated: (_) {},
    loadOverride: load,
  ),
);

void main() {
  testWidgets("lists groups with the signed-in user's net balance", (tester) async {
    await tester.pumpWidget(_host(load: () async => [GroupRow(_group(), 'm1', 2500, 3, '', '')]));
    await tester.pumpAndSettle();

    expect(find.text('Trip'), findsOneWidget);
    expect(find.textContaining('25.00'), findsWidgets);
  });

  testWidgets('an empty group list shows an empty state, not an error', (tester) async {
    await tester.pumpWidget(_host(load: () async => []));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('a failed load offers a retry that succeeds', (tester) async {
    var attempts = 0;
    await tester.pumpWidget(
      _host(
        load: () async {
          attempts++;
          if (attempts == 1) throw StateError('offline');
          return [GroupRow(_group(), 'm1', 0, 2, '', '')];
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('Trip'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('totals are summed per currency, never across them', (tester) async {
    await tester.pumpWidget(
      _host(
        load: () async => [
          GroupRow(_group(id: 'g1', name: 'Trip'), 'm1', 2500, 2, '', ''),
          GroupRow(_group(id: 'g2', name: 'Flat'), 'm2', 1000, 2, '', ''),
          GroupRow(_group(id: 'g3', name: 'Berlin', currency: 'EUR'), 'm3', 4000, 2, '', ''),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // USD 25.00 + 10.00 = 35.00, kept apart from the EUR 40.00.
    expect(find.textContaining(r'$35.00'), findsWidgets);
    expect(find.textContaining('€40.00'), findsWidgets);
  });
}
