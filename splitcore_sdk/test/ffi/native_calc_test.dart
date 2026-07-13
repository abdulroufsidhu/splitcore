import 'package:splitcore_sdk/src/ffi/bindings.dart';
import 'package:splitcore_sdk/src/ffi/native_calc.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';

void main() {
  late SplitcoreBindings bindings;
  late NativeCalc calc;

  setUpAll(() {
    bindings = SplitcoreBindings.open(resolveLinuxLibPath());
    calc = NativeCalc(bindings);
  });

  group('computeSplits', () {
    test('100.00 over 3 members — leftover cent to first, matches Go fixture', () {
      final splits = calc.computeSplits(
        SplitSpec.equal(totalCents: 10000, memberIds: ['a', 'b', 'c']),
      );

      expect(splits, [
        const Split(memberId: 'a', amountCents: 3334),
        const Split(memberId: 'b', amountCents: 3333),
        const Split(memberId: 'c', amountCents: 3333),
      ]);
      expect(splits.fold<int>(0, (sum, s) => sum + s.amountCents), 10000);
    });

    test('percent split whose basis points do not sum to 10000 throws SplitcoreException', () {
      expect(
        () => calc.computeSplits(
          SplitSpec.percent(
            totalCents: 1000,
            entries: const [
              PercentSplitEntry(memberId: 'a', basisPoints: 4000),
              PercentSplitEntry(memberId: 'b', basisPoints: 4000),
            ],
          ),
        ),
        throwsA(isA<SplitcoreException>()),
      );
    });
  });

  group('simplifyDebts', () {
    test('simple pair collapses to one transfer, matches Go fixture', () {
      final transfers = calc.simplifyDebts(const [
        Balance(memberId: 'a', netCents: 500),
        Balance(memberId: 'b', netCents: -500),
      ]);

      expect(transfers, [
        const Transfer(fromMemberId: 'b', toMemberId: 'a', amountCents: 500),
      ]);
    });
  });

  group('computeBalances', () {
    test('one expense split equally between payer and one other nets to zero-sum', () {
      final balances = calc.computeBalances(
        expenses: const [
          ExpenseInput(
            payerId: 'a',
            amountCents: 1000,
            splits: [
              Split(memberId: 'a', amountCents: 500),
              Split(memberId: 'b', amountCents: 500),
            ],
          ),
        ],
        settlements: const [],
      );

      final total = balances.fold<int>(0, (sum, b) => sum + b.netCents);
      expect(total, 0);
      expect(
        balances.firstWhere((b) => b.memberId == 'b').netCents,
        -500,
      );
    });
  });

  test('repeated calls do not corrupt state (no leak/use-after-free regressions)', () {
    for (var i = 0; i < 200; i++) {
      final splits = calc.computeSplits(
        SplitSpec.equal(totalCents: 100, memberIds: ['a', 'b', 'c']),
      );
      expect(splits.fold<int>(0, (sum, s) => sum + s.amountCents), 100);
    }
  });
}
