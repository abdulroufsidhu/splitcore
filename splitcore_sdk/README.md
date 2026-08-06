# splitcore_sdk

Dart SDK for the `slice_pay` expense-splitting backend. This package wraps
`splitcore` — the pure-Go split/settlement/balance engine that also powers
the PocketBase server — via `dart:ffi`, so client and server math can never
drift: they run the exact same compiled code. It also owns all PocketBase
communication, so a Flutter frontend never talks to PocketBase directly.

## Status

Step 5 of the monorepo build order (see
`docs/superpowers/specs/2026-07-06-splitcore-design.md`) is complete:

- FFI bindings to `libsplitcore`'s 4 exports (`SplitcoreComputeSplits`,
  `SplitcoreSimplifyDebts`, `SplitcoreComputeBalances`, `SplitcoreFree`).
- An isolate wrapper (`IsolateCalc`) so every computation runs off the
  calling isolate via `Isolate.run` — callers never block, never see
  isolates.
- `SplitcoreCalc`, the compute API: `computeSplits`, `computeBalances`,
  `settleUp`.
- A PocketBase remote layer: auth, groups/members, expenses/split entries
  (with a receipt compress-and-upload pipeline), settlements (with a
  pre-settlement staleness check and automatic resync), and a read-only
  balances API.
- `SplitcoreSdk`, the single facade a Flutter app should import — wires the
  compute and remote layers together behind `sdk.auth`, `sdk.groups`,
  `sdk.expenses`, `sdk.settlements`, `sdk.balances`, `sdk.settleUp`.

**Not yet built:** anything Flutter/mobile-app-shaped (UI, state
management, navigation) — out of scope for this package, tracked
separately; see `docs/superpowers/plans/2026-07-13-sdk.md`.

## Usage

```dart
import 'package:splitcore_sdk/splitcore_sdk.dart';

final sdk = SplitcoreSdk.initialize(
  pocketbaseUrl: 'https://your-pocketbase-host',
  libraryPath: pathToLibsplitcore,
);

final user = await sdk.auth.signUp(email: 'alice@example.com', password: '...');
final group = await sdk.groups.createGroup(name: 'Trip to Goa', currency: 'INR');
final member = (await sdk.groups.listMembers(group.id)).first;

await sdk.expenses.createExpense(
  groupId: group.id,
  payerMemberId: member.id,
  description: 'Dinner',
  date: DateTime.now(),
  split: SplitSpec.equal(totalCents: 10000, memberIds: [member.id]),
);

final balances = await sdk.balances.getBalances(group.id);
final transfers = await sdk.settleUp(balances);

final refreshedGroup = await sdk.groups.getGroup(group.id);
await sdk.settlements.createSettlement(
  groupId: group.id,
  localVersion: refreshedGroup.version,
  fromMemberId: transfers.first.fromMemberId,
  toMemberId: transfers.first.toMemberId,
  amountCents: transfers.first.amountCents,
);
```

Every compute call hops onto a fresh isolate internally; errors from the Go
side surface as `SplitcoreException`. `sdk.settlements.createSettlement`
checks staleness first and transparently resyncs local balances before
writing if the caller's `localVersion` is out of date — callers don't need
to handle that themselves.

## Loading the native library

This package is pure Dart — the native library is **not** bundled in the pub
archive, because it is a per-platform binary. Download
`splitcore-native-v<version>.zip` from a
[GitHub release](https://github.com/abdulroufsidhu/splitcore/releases) (it
contains every Android ABI plus Linux and Windows), or build it yourself from
`splitcore/build/`.

`SplitcoreSdk.initialize` (and `SplitcoreCalc.open`) take an explicit path
to the shared library, matching how each platform ships it:

- **Linux / tests:** `splitcore/build/out/linux/libsplitcore.so`, built by
  `splitcore/build/build_linux.sh`.
- **Android:** the `jniLibs/<abi>/libsplitcore.so` produced by
  `splitcore/build/build_android.sh`; a Flutter app bundling this package
  can resolve it via `DynamicLibrary.open('libsplitcore.so')` once packaged
  under `android/app/src/main/jniLibs`.
- **Windows:** `splitcore.dll` next to the executable, built by
  `splitcore/build/build_windows.sh`.
- **iOS:** a static `.a` from `splitcore/build/build_ios.sh` (not
  dynamically loadable the same way — iOS integration is unverified in
  this environment and needs to be linked into the app target directly;
  flagged for user verification per the build scripts' docs).

## Running tests

Tests exercise real dependencies, not mocks: the actual linux `.so` for
compute, and the actual PocketBase `server` binary (spawned as a subprocess
per test file, on an ephemeral port + temp data dir) for every remote-layer
test.

```bash
# from the repo root, if the .so isn't already built:
bash splitcore/build/build_linux.sh

cd splitcore_sdk
dart pub get
dart test
```

Requires the `go` toolchain on PATH (used to run the real server during
remote-layer tests) and network access on first run to fetch the `go`
module cache for `server/`. `test/support/lib_path.dart` resolves the `.so`
relative to this package's location in the monorepo; `test/support/pb_server.dart`
spawns/tears down the PocketBase server per test file — if either
dependency is missing, tests fail with a clear message rather than hanging.

## Package layout

```
lib/
  splitcore_sdk.dart   # sole public export
  src/
    models.dart        # wire-format types shared by the compute + remote layers
    ffi/
      bindings.dart     # dlopen + raw symbol lookups
      native_calc.dart  # JSON encode/call/free/decode, sync
    isolate_calc.dart   # Isolate.run wrapper around native_calc
    calc_api.dart       # SplitcoreCalc, the compute API
    remote/
      auth_api.dart        # sign up/in/out, currentUser
      groups_api.dart       # groups + group_members CRUD
      expenses_api.dart     # expenses + split_entries, receipt attach
      receipts.dart          # image downscale/JPEG re-encode + upload
      staleness_api.dart    # GET /api/splitcore/staleness wrapper
      settlements_api.dart  # staleness-checked settlement create
      balances_api.dart     # read-only cached balances
      local_store.dart      # in-memory per-group version-tagged cache
    sdk.dart            # SplitcoreSdk facade
test/
  models_test.dart, ffi/, isolate_calc_test.dart, calc_api_test.dart
  remote/    # one test file per remote/ source file, against a real server
  sdk_test.dart   # full facade end-to-end test
  support/
    lib_path.dart   # resolves the linux .so
    pb_server.dart  # spawns/tears down a real PocketBase server per test file
```
