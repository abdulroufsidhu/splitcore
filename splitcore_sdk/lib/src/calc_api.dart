// Public compute API: split/settlement/balance math, always off the UI
// thread via IsolateCalc. This is the "sdk.balances" / "sdk.settleUp"
// surface from the design spec's foundation phase — no PocketBase
// communication lives here.
import 'isolate_calc.dart';
import 'models.dart';

class SplitcoreCalc {
  SplitcoreCalc._(this._isolateCalc);

  /// Opens the splitcore shared library at [libraryPath] (e.g. the linux
  /// .so for desktop/tests, or a platform-resolved path for mobile).
  factory SplitcoreCalc.open(String libraryPath) => SplitcoreCalc._(IsolateCalc(libraryPath));

  final IsolateCalc _isolateCalc;

  /// Computes a split (equal/exact/percent/shares) via splitcore, matching
  /// the same math the server uses for validation.
  Future<List<Split>> computeSplits(SplitSpec spec) => _isolateCalc.computeSplits(spec);

  /// Recomputes balances from an expense/settlement log, deterministically.
  Future<List<Balance>> computeBalances({
    required List<ExpenseInput> expenses,
    required List<SettlementInput> settlements,
  }) => _isolateCalc.computeBalances(expenses: expenses, settlements: settlements);

  /// Suggests the minimal set of transfers to zero out a group's balances.
  Future<List<Transfer>> settleUp(List<Balance> balances) => _isolateCalc.simplifyDebts(balances);
}
