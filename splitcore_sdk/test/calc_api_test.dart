import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import 'support/lib_path.dart';

void main() {
  late SplitcoreCalc calc;

  setUp(() {
    calc = SplitcoreCalc.open(resolveLinuxLibPath());
  });

  test('computeSplits delegates to the FFI equal-split implementation', () async {
    final splits = await calc.computeSplits(
      SplitSpec.equal(totalCents: 10000, memberIds: ['a', 'b', 'c']),
    );

    expect(splits.fold<int>(0, (sum, s) => sum + s.amountCents), 10000);
  });

  test('computeBalances sums to zero for a single equal-split expense', () async {
    final balances = await calc.computeBalances(
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

    expect(balances.fold<int>(0, (sum, b) => sum + b.netCents), 0);
  });

  test('settleUp returns the minimal transfer set for a two-member imbalance', () async {
    final transfers = await calc.settleUp(const [
      Balance(memberId: 'a', netCents: 500),
      Balance(memberId: 'b', netCents: -500),
    ]);

    expect(transfers, [
      const Transfer(fromMemberId: 'b', toMemberId: 'a', amountCents: 500),
    ]);
  });

  test('errors from the native layer surface as SplitcoreException through the public API', () {
    expect(
      () => calc.computeSplits(
        SplitSpec.percent(
          totalCents: 1000,
          entries: const [PercentSplitEntry(memberId: 'a', basisPoints: 1000)],
        ),
      ),
      throwsA(isA<SplitcoreException>()),
    );
  });
}
