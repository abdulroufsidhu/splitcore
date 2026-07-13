// The one money-path check: MoneyText's whole job is "positive = green,
// negative = coral, unsigned = plain ink" — if that mapping ever breaks,
// this fails.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app/theme.dart';
import 'package:app/widgets/money_text.dart';

void main() {
  testWidgets('MoneyText colors by sign and formats +/- with currency symbol', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Column(
        children: [
          MoneyText(6210, 'USD'),
          MoneyText(-3820, 'EUR'),
          MoneyText(0, 'USD', signed: false),
        ],
      ),
    ));

    final positive = tester.widget<Text>(find.text(r'+$62.10'));
    expect((positive.style!.color), SliceColors.positive);

    final negative = tester.widget<Text>(find.text('−€38.20'));
    expect((negative.style!.color), SliceColors.negative);

    final unsigned = tester.widget<Text>(find.text(r'$0.00'));
    expect((unsigned.style!.color), SliceColors.ink);
  });
}
