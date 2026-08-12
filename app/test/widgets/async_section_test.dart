import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/loadable.dart';
import 'package:splitcore_app/theme.dart';
import 'package:splitcore_app/widgets/async_section.dart';

Widget host(Loadable<String> loadable) => MaterialApp(
  theme: sliceLightTheme(),
  home: Scaffold(
    body: AsyncSection<String>(
      loadable: loadable,
      skeleton: const Text('skeleton'),
      builder: (context, value) => Text(value),
    ),
  ),
);

void main() {
  testWidgets('shows the skeleton during the first load', (tester) async {
    final gate = Completer<String>();
    final loadable = Loadable<String>(() => gate.future);
    unawaited(loadable.load());

    await tester.pumpWidget(host(loadable));
    await tester.pump();

    expect(find.text('skeleton'), findsOneWidget);

    gate.complete('done');
    await tester.pumpAndSettle();
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('shows the error with a retry that reloads', (tester) async {
    var attempts = 0;
    final loadable = Loadable<String>(() async {
      attempts++;
      if (attempts == 1) throw StateError('network down');
      return 'recovered';
    });
    await loadable.load();

    await tester.pumpWidget(host(loadable));
    await tester.pumpAndSettle();

    expect(find.text('Retry'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.text('recovered'), findsOneWidget);
    expect(attempts, 2);
  });

  testWidgets('the error state names what failed, in the caller\'s words', (tester) async {
    final loadable = Loadable<String>(() async => throw StateError('network down'));
    await loadable.load();

    await tester.pumpWidget(
      MaterialApp(
        theme: sliceLightTheme(),
        home: Scaffold(
          body: AsyncSection<String>(
            loadable: loadable,
            errorLabel: "Couldn't load your groups.",
            skeleton: const Text('skeleton'),
            builder: (context, value) => Text(value),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text("Couldn't load your groups."), findsOneWidget);
  });

  testWidgets('keeps content on screen during a reload', (tester) async {
    final gate = Completer<String>();
    var call = 0;
    final loadable = Loadable<String>(() {
      call++;
      return call == 1 ? Future.value('first') : gate.future;
    });
    await loadable.load();

    await tester.pumpWidget(host(loadable));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);

    unawaited(loadable.load());
    await tester.pump();

    expect(find.text('first'), findsOneWidget, reason: 'reload blanked the content');
    expect(find.text('skeleton'), findsNothing);

    gate.complete('second');
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('a failed refresh keeps the stale content instead of an error screen', (
    tester,
  ) async {
    var call = 0;
    final loadable = Loadable<String>(() async {
      call++;
      if (call == 1) return 'first';
      throw StateError('refresh failed');
    });
    await loadable.load();

    await tester.pumpWidget(host(loadable));
    await tester.pumpAndSettle();

    await loadable.load();
    await tester.pumpAndSettle();

    expect(find.text('first'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });
}
