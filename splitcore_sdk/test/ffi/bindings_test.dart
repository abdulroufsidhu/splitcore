import 'package:ffi/ffi.dart';
import 'package:splitcore_sdk/src/ffi/bindings.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';

void main() {
  test('opens libsplitcore.so and resolves all four exports', () {
    final bindings = SplitcoreBindings.open(resolveLinuxLibPath());

    // Constructing SplitcoreBindings resolves every symbol via
    // lookupFunction; a missing export throws ArgumentError at open time.
    // Exercise computeSplits end to end (malformed request -> {"error":...})
    // to prove the resolved pointers actually work, then free the result.
    final reqPtr = 'not json'.toNativeUtf8();
    final resPtr = bindings.computeSplits(reqPtr.cast());
    final result = resPtr.cast<Utf8>().toDartString();
    bindings.free(resPtr);
    calloc.free(reqPtr);

    expect(result, contains('error'));
  });

  test('throws when the library path does not exist', () {
    expect(() => SplitcoreBindings.open('/nonexistent/libsplitcore.so'), throwsA(anything));
  });
}
