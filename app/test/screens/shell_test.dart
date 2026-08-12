// What the shell puts on screen at each width.
//
// The interesting assertions are structural — is there a rail, is there a
// second pane, does tapping a group push a route or fill the pane — so
// each test states the window it is about rather than inheriting Flutter's
// default 800x600, which is a size no phone or desktop actually is.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/screens/home.dart';
import 'package:splitcore_app/screens/shell.dart';
import 'package:splitcore_app/theme.dart';

const _me = AppUser(id: 'u1', email: 'me@example.com', name: 'Me', avatarUrl: '');

final _trip = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 1, ownerId: 'u1');
final _flat = Group(id: 'g2', name: 'Flat', currency: 'USD', version: 1, ownerId: 'u1');

List<GroupRow> _rows() => [
  GroupRow(_trip, 'm1', 2400, 3, '', ''),
  GroupRow(_flat, 'm2', -1200, 2, '', ''),
];

/// Renders the shell in a window of exactly [size], undoing it afterwards
/// so one test's window cannot leak into the next.
Future<void> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      theme: sliceLightTheme(),
      home: AppShell(
        sdk: null,
        me: _me,
        onSignedOut: () {},
        onProfileUpdated: (_) {},
        homeLoadOverride: () async => _rows(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a phone gets no rail and no second pane', (tester) async {
    await _pumpAt(tester, const Size(393, 852));

    expect(find.byType(NavigationRail), findsNothing);
    expect(find.text('Select a group'), findsNothing);
    // The home screen keeps its own Activity and Account affordances,
    // because nothing else is offering them.
    expect(find.bySemanticsLabel('Account'), findsOneWidget);
  });

  testWidgets('a tablet in portrait gets the rail but still one pane', (tester) async {
    await _pumpAt(tester, const Size(700, 1000));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Select a group'), findsNothing);
    // The rail carries Account now, so the header does not draw a second
    // one beside it.
    expect(find.bySemanticsLabel('Account'), findsNothing);
  });

  testWidgets('a desktop window gets the list beside a detail pane', (tester) async {
    await _pumpAt(tester, const Size(1280, 900));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Select a group'), findsOneWidget);
    // Both groups are in the list pane, which is still on screen.
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Flat'), findsOneWidget);
  });

  testWidgets('selecting a group fills the pane instead of covering the list', (tester) async {
    await _pumpAt(tester, const Size(1280, 900));

    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(find.text('Select a group'), findsNothing);
    // The whole point of a second pane: the list you selected from is
    // still there to select something else from.
    expect(find.text('Flat'), findsOneWidget);
  });

  testWidgets('the detail pane has no back arrow, because nothing is behind it', (tester) async {
    await _pumpAt(tester, const Size(1280, 900));
    await tester.tap(find.text('Trip'));
    await tester.pumpAndSettle();

    expect(find.byType(BackButton), findsNothing);
  });

  testWidgets('the rail switches what fills the window', (tester) async {
    await _pumpAt(tester, const Size(1280, 900));

    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();

    // The groups list is gone, replaced rather than pushed over.
    expect(find.text('Trip'), findsNothing);
  });

  testWidgets('an ultrawide still shows one list and one detail', (tester) async {
    await _pumpAt(tester, const Size(3440, 1440));

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.text('Trip'), findsOneWidget);
    expect(find.text('Select a group'), findsOneWidget);
  });

  testWidgets('nothing overflows on a folded cover screen', (tester) async {
    // 320 is the narrowest thing the app claims to support. Two labelled
    // pill buttons do not fit on one line there, which is what the Wrap in
    // the home screen's action row is for.
    await _pumpAt(tester, const Size(320, 700));

    expect(tester.takeException(), isNull);
    expect(find.text('Trip'), findsOneWidget);
  });
}
