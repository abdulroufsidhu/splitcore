// Synchronous JSON encode -> native call -> free -> decode wrapper around
// SplitcoreBindings. Runs on whatever isolate calls it; callers wanting
// off-UI-thread execution should go through IsolateCalc instead.
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../models.dart';
import 'bindings.dart';

/// Thrown when the native call returns a JSON {"error": "..."} response.
class SplitcoreException implements Exception {
  SplitcoreException(this.message);

  final String message;

  @override
  String toString() => 'SplitcoreException: $message';
}

class NativeCalc {
  NativeCalc(this._bindings);

  final SplitcoreBindings _bindings;

  List<Split> computeSplits(SplitSpec spec) {
    final json = _call(_bindings.computeSplits, spec.toJson());
    final splits = json['splits'] as List<dynamic>;
    return [for (final s in splits) Split.fromJson(s as Map<String, dynamic>)];
  }

  List<Transfer> simplifyDebts(List<Balance> balances) {
    final json = _call(_bindings.simplifyDebts, {
      'balances': [for (final b in balances) b.toJson()],
    });
    final transfers = json['transfers'] as List<dynamic>;
    return [for (final t in transfers) Transfer.fromJson(t as Map<String, dynamic>)];
  }

  List<Balance> computeBalances({
    required List<ExpenseInput> expenses,
    required List<SettlementInput> settlements,
  }) {
    final json = _call(_bindings.computeBalances, {
      'expenses': [for (final e in expenses) e.toJson()],
      'settlements': [for (final s in settlements) s.toJson()],
    });
    final balances = json['balances'] as List<dynamic>;
    return [for (final b in balances) Balance.fromJson(b as Map<String, dynamic>)];
  }

  /// Encodes [request] as JSON, calls [nativeFn] with it, frees the native
  /// response via SplitcoreFree (always, even on error), and decodes the
  /// result — throwing SplitcoreException if the response carries an
  /// {"error": "..."} key.
  Map<String, dynamic> _call(JsonCallDart nativeFn, Map<String, dynamic> request) {
    final reqPtr = jsonEncode(request).toNativeUtf8();
    Pointer<Utf8> resPtr;
    try {
      resPtr = nativeFn(reqPtr);
    } finally {
      calloc.free(reqPtr);
    }
    final String responseStr;
    try {
      responseStr = resPtr.toDartString();
    } finally {
      _bindings.free(resPtr);
    }
    final decoded = jsonDecode(responseStr) as Map<String, dynamic>;
    if (decoded.containsKey('error')) {
      throw SplitcoreException(decoded['error'] as String);
    }
    return decoded;
  }
}
