// Off-UI-thread wrapper around NativeCalc. Every FFI computation runs via
// Isolate.run so callers never block the calling isolate (the Flutter UI
// isolate, in practice) and never need to know isolates are involved.
//
// Native library handles cannot cross isolate boundaries, so each call
// re-opens the shared library inside the spawned isolate rather than
// reusing a SplitcoreBindings instance created on the caller's isolate.
import 'dart:isolate';

import 'ffi/bindings.dart';
import 'ffi/native_calc.dart';
import 'models.dart';

class IsolateCalc {
  IsolateCalc(this._libraryPath);

  final String _libraryPath;

  Future<List<Split>> computeSplits(SplitSpec spec) {
    final libraryPath = _libraryPath;
    return Isolate.run(() {
      final calc = NativeCalc(SplitcoreBindings.open(libraryPath));
      return calc.computeSplits(spec);
    });
  }

  Future<List<Transfer>> simplifyDebts(List<Balance> balances) {
    final libraryPath = _libraryPath;
    return Isolate.run(() {
      final calc = NativeCalc(SplitcoreBindings.open(libraryPath));
      return calc.simplifyDebts(balances);
    });
  }

  Future<List<Balance>> computeBalances({
    required List<ExpenseInput> expenses,
    required List<SettlementInput> settlements,
  }) {
    final libraryPath = _libraryPath;
    return Isolate.run(() {
      final calc = NativeCalc(SplitcoreBindings.open(libraryPath));
      return calc.computeBalances(expenses: expenses, settlements: settlements);
    });
  }
}
