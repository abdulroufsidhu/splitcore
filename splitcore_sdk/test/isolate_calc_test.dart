import 'package:splitcore_sdk/src/ffi/native_calc.dart' show SplitcoreException;
import 'package:splitcore_sdk/src/isolate_calc.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:test/test.dart';

import 'support/lib_path.dart';

void main() {
  late IsolateCalc calc;

  setUp(() {
    calc = IsolateCalc(resolveLinuxLibPath());
  });

  test('computeSplits returns a Future and matches the direct-call result', () async {
    final future = calc.computeSplits(
      SplitSpec.equal(totalCents: 10000, memberIds: ['a', 'b', 'c']),
    );
    expect(future, isA<Future<List<Split>>>());

    final splits = await future;

    expect(splits, [
      const Split(memberId: 'a', amountCents: 3334),
      const Split(memberId: 'b', amountCents: 3333),
      const Split(memberId: 'c', amountCents: 3333),
    ]);
  });

  test('simplifyDebts runs off the calling isolate and returns expected transfers', () async {
    final transfers = await calc.simplifyDebts(const [
      Balance(memberId: 'a', netCents: 500),
      Balance(memberId: 'b', netCents: -500),
    ]);

    expect(transfers, [
      const Transfer(fromMemberId: 'b', toMemberId: 'a', amountCents: 500),
    ]);
  });

  test('computeBalances propagates errors as SplitcoreException across isolate boundary', () {
    expect(
      () => calc.computeBalances(
        expenses: const [
          ExpenseInput(payerId: 'a', amountCents: 1000, splits: []),
        ],
        settlements: const [],
      ),
      throwsA(isA<SplitcoreException>()),
    );
  });
}
