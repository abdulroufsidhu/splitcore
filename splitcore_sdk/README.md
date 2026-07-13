# splitcore_sdk

Dart SDK for the `slice_pay` expense-splitting backend. This package wraps
`splitcore` — the pure-Go split/settlement/balance engine that also powers
the PocketBase server — via `dart:ffi`, so client and server math can never
drift: they run the exact same compiled code.

## Status: foundation phase

This is step 5 of the monorepo build order (see
`docs/superpowers/specs/2026-07-06-splitcore-design.md`). What's implemented:

- FFI bindings to `libsplitcore`'s 4 exports (`SplitcoreComputeSplits`,
  `SplitcoreSimplifyDebts`, `SplitcoreComputeBalances`, `SplitcoreFree`).
- An isolate wrapper (`IsolateCalc`) so every computation runs off the
  calling isolate via `Isolate.run` — callers never block, never see
  isolates.
- The public compute API, `SplitcoreCalc`, exposing `computeSplits`,
  `computeBalances`, and `settleUp`.

**Not yet implemented** (deferred to a follow-up plan): the PocketBase
client (auth, groups/expenses/splits/settlements CRUD), the receipt
compress-and-upload pipeline, local event-log sync, and the
pre-settlement staleness/resync flow against
`GET /api/splitcore/staleness`.

## Usage

```dart
import 'package:splitcore_sdk/splitcore_sdk.dart';

final calc = SplitcoreCalc.open(pathToLibsplitcore);

final splits = await calc.computeSplits(
  SplitSpec.equal(totalCents: 10000, memberIds: ['alice', 'bob', 'carol']),
);

final balances = await calc.computeBalances(
  expenses: [...],
  settlements: [...],
);

final transfers = await calc.settleUp(balances);
```

Every `SplitcoreCalc` method returns a `Future` and internally hops onto a
fresh isolate for the native call; errors from the Go side surface as
`SplitcoreException`.

## Loading the native library

`SplitcoreCalc.open` takes an explicit path to the shared library, matching
how each platform ships it:

- **Linux / tests:** `splitcore/build/out/linux/libsplitcore.so`, built by
  `splitcore/build/build_linux.sh`.
- **Android:** the `jniLibs/<abi>/libsplitcore.so` produced by
  `splitcore/build/build_android.sh`; a Flutter app bundling this package
  can resolve it via `DynamicLibrary.open('libsplitcore.so')` once packaged
  under `android/app/src/main/jniLibs`.
- **iOS:** a static `.a` from `splitcore/build/build_ios.sh` (not
  dynamically loadable the same way — iOS integration is unverified in
  this environment and needs to be linked into the app target directly;
  flagged for user verification per the build scripts' docs).

## Running tests

Tests exercise the real linux `.so`, not a mock:

```bash
# from the repo root, if the .so isn't already built:
bash splitcore/build/build_linux.sh

cd splitcore_sdk
dart pub get
dart test
```

`test/support/lib_path.dart` resolves the `.so` relative to this package's
location in the monorepo (`../splitcore/build/out/linux/libsplitcore.so`);
if it's missing, tests fail with a clear message telling you to run the
build script first.

## Package layout

```
lib/
  splitcore_sdk.dart   # sole public export
  src/
    models.dart        # wire-format types matching splitcore/ffi/handler
    ffi/
      bindings.dart     # dlopen + raw symbol lookups
      native_calc.dart  # JSON encode/call/free/decode, sync
    isolate_calc.dart   # Isolate.run wrapper around native_calc
    calc_api.dart       # SplitcoreCalc, the public surface
test/
  models_test.dart
  ffi/bindings_test.dart
  ffi/native_calc_test.dart
  isolate_calc_test.dart
  calc_api_test.dart
  support/lib_path.dart
```
