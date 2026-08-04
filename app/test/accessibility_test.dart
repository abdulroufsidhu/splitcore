import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/theme.dart';
import 'package:splitcore_app/widgets/money_text.dart';

void main() {
  testWidgets('MoneyText announces direction in words, not only in colour', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sliceLightTheme(),
        home: const Scaffold(
          body: Column(children: [MoneyText(6210, 'USD'), MoneyText(-3820, 'EUR')]),
        ),
      ),
    );

    // Green/coral is the only cue that a number is owed to you vs owed by
    // you. A screen reader gets none of it, and neither does anyone who
    // cannot distinguish the two colours.
    final positive = tester.getSemantics(find.byType(MoneyText).first);
    expect(positive.label, contains('owed to you'));

    final negative = tester.getSemantics(find.byType(MoneyText).last);
    expect(negative.label, contains('you owe'));
  });

  testWidgets('an unsigned amount is announced plainly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sliceLightTheme(),
        home: const Scaffold(body: MoneyText(6210, 'USD', signed: false)),
      ),
    );

    final semantics = tester.getSemantics(find.byType(MoneyText));
    expect(semantics.label, isNot(contains('owed to you')));
    expect(semantics.label, contains('62.10'));
  });

  testWidgets('a zero balance is not announced as owing in either direction', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: sliceLightTheme(),
        home: const Scaffold(body: MoneyText(0, 'USD')),
      ),
    );

    final semantics = tester.getSemantics(find.byType(MoneyText));
    expect(semantics.label, isNot(contains('owe')));
  });

  testWidgets('a representative screen meets tap-target and labelling guidelines', (tester) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(
      MaterialApp(
        theme: sliceLightTheme(),
        home: Scaffold(
          appBar: AppBar(
            title: const Text('Trip'),
            actions: [
              IconButton(
                tooltip: 'Add member',
                icon: const Icon(Icons.person_add_alt_1),
                onPressed: () {},
              ),
            ],
          ),
          body: const Column(children: [MoneyText(6210, 'USD')]),
          floatingActionButton: FloatingActionButton(
            onPressed: () {},
            tooltip: 'Add expense',
            child: const Icon(Icons.add),
          ),
        ),
      ),
    );

    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(iOSTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));

    handle.dispose();
  });
}
