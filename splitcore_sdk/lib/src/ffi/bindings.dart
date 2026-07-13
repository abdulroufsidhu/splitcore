// Raw dlopen + symbol bindings for libsplitcore's 4 exports (see
// splitcore/ffi/main.go). This layer knows nothing about JSON payloads or
// isolates — it only resolves and calls the native functions.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart' show Utf8;

typedef _JsonCallNative = Pointer<Utf8> Function(Pointer<Utf8> req);

/// Dart-side signature of the 3 JSON-in/JSON-out native exports.
typedef JsonCallDart = Pointer<Utf8> Function(Pointer<Utf8> req);

typedef _FreeNative = Void Function(Pointer<Utf8> p);

/// Dart-side signature of SplitcoreFree.
typedef FreeDart = void Function(Pointer<Utf8> p);

/// Thin wrapper around the 4 native exports of libsplitcore. Opening a
/// missing library or a library missing one of the expected symbols throws
/// (ArgumentError from lookupFunction, or a dlopen failure) rather than
/// deferring the failure to first call.
class SplitcoreBindings {
  SplitcoreBindings._(
    this._library,
    this.computeSplits,
    this.simplifyDebts,
    this.computeBalances,
    this.free,
  );

  factory SplitcoreBindings.open(String libraryPath) {
    final library = _openLibrary(libraryPath);
    return SplitcoreBindings._(
      library,
      library.lookupFunction<_JsonCallNative, JsonCallDart>('SplitcoreComputeSplits'),
      library.lookupFunction<_JsonCallNative, JsonCallDart>('SplitcoreSimplifyDebts'),
      library.lookupFunction<_JsonCallNative, JsonCallDart>('SplitcoreComputeBalances'),
      library.lookupFunction<_FreeNative, FreeDart>('SplitcoreFree'),
    );
  }

  static DynamicLibrary _openLibrary(String libraryPath) {
    if (!File(libraryPath).existsSync()) {
      throw ArgumentError.value(libraryPath, 'libraryPath', 'shared library not found');
    }
    return DynamicLibrary.open(libraryPath);
  }

  // Kept alive for the lifetime of this binding; dlclose is intentionally
  // never called — the process owns the mapping for its whole lifetime.
  // ignore: unused_field
  final DynamicLibrary _library;

  final JsonCallDart computeSplits;
  final JsonCallDart simplifyDebts;
  final JsonCallDart computeBalances;
  final FreeDart free;
}
