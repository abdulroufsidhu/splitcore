import 'package:flutter_test/flutter_test.dart';

import 'package:splitcore_app/money.dart';

void main() {
  test('formatAmountForEditing renders minor units as an exact decimal', () {
    expect(formatAmountForEditing(4250), '42.50');
    expect(formatAmountForEditing(100), '1.00');
    expect(formatAmountForEditing(5), '0.05');
    expect(formatAmountForEditing(0), '0.00');
    expect(formatAmountForEditing(-2125), '-21.25');
  });

  test('no amount loses a cent to floating point', () {
    // 0.1 + 0.2 territory: these are the values a double would mangle.
    for (final cents in [1, 7, 29, 3333, 99999, 100000007]) {
      final text = formatAmountForEditing(cents);
      final roundTripped = (double.parse(text) * 100).round();
      expect(roundTripped, cents, reason: '$cents rendered as $text');
    }
  });
}
