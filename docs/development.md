# Development

## Prerequisites

| Tool | Needed for |
|---|---|
| Go 1.26+ | `splitcore`, `server`, and the Dart SDK's integration tests (which spawn the real server) |
| Dart 3.9+ | `splitcore_sdk` |
| Flutter 3.9+ | `app` |
| gcc / clang | cgo, for building the shared library |
| Android NDK | Android `.so` builds (auto-detected under `$ANDROID_HOME/ndk`, or set `ANDROID_NDK_HOME`) |
| macOS + Xcode | iOS builds only — not available in this project's dev environment |

`go.work` ties `./splitcore` and `./server` into one workspace.

## Running the server

```bash
cd server
go run . serve --http=0.0.0.0:8090
```

API at `/api/`, admin UI at `/_/`. Create the first superuser through the admin
UI, or non-interactively:

```bash
./server superuser upsert <email> <password>
```

**`--http=0.0.0.0:8090` is not optional if a device is involved.** PocketBase
binds `127.0.0.1` by default, and a phone, emulator, or Waydroid guest cannot
reach that. Point the app at whatever host address the guest sees:

| Client | Host address |
|---|---|
| Waydroid | `192.168.240.1` (gateway) |
| Android emulator | `10.0.2.2` |
| Physical device | the machine's LAN IP |

### Migrations

Under `go run`, `main.go` detects a temp-dir `os.Args[0]` and enables
PocketBase's automigrate — pending migrations apply on `serve`, no extra step.

For a compiled binary, automigrate is off. Apply them explicitly:

```bash
go build && go run . migrate up && ./server serve
```

## Building the native library

Scripts live in [splitcore/build/](../splitcore/build/); all output lands in
`splitcore/build/out/` (gitignored).

```bash
./splitcore/build/build_linux.sh      # libsplitcore.so for desktop + tests
python3 splitcore/build/smoke_test.py # ctypes ABI check, end to end

./splitcore/build/build_android.sh    # out/android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64,x86}/
./splitcore/build/build_ios.sh        # macOS only — out/ios/libsplitcore.a + .h
```

### Verification status — read this before trusting a target

| Target | Status |
|---|---|
| Linux x86_64 `.so` | ✅ built and smoke-tested |
| Android, 4 ABIs | ✅ built 4/4 with NDK r30.0.14904198 (2026-07-06) |
| iOS arm64 `.a` | ❌ **never run** — requires macOS/Xcode. The script's refusal path was tested; the build itself was not. Verify on real hardware before shipping. |

Android minimum API is 24 (Go requires ≥21; change `API=` in the script to lower
it). Copy the produced `jniLibs` folder into
`app/android/app/src/main/jniLibs/`.

On iOS the artifact is a static `.a`, not a dynamic library — link it into the
app target and Dart FFI resolves symbols from the process image via
`DynamicLibrary.process()`. Simulator builds on Apple Silicon additionally need
a separate `iphonesimulator`-SDK build combined via `lipo` or
`xcodebuild -create-xcframework`; deferred until there is an iOS target.

## Running the app

The app's built-in default is the deployed server,
`https://splitcore.orgolink.ch`. Working against a local server means saying
so:

```bash
cd app
flutter pub get
flutter run --dart-define=POCKETBASE_URL=http://<host>:8090
```

On desktop, also point at the built library:

```bash
flutter run -d linux \
  --dart-define=POCKETBASE_URL=http://127.0.0.1:8090 \
  --dart-define=SPLITCORE_LIB_PATH=$PWD/../splitcore/build/out/linux/libsplitcore.so
```

On Android and iOS the path is the bare soname `libsplitcore.so`, resolved by
the OS loader from the app's bundled native libs.

## Tests

```bash
go test ./splitcore/... ./server/...     # 126 tests, 10 packages — verified 2026-08-04

bash splitcore/build/build_linux.sh      # the Dart tests need the real .so
cd splitcore_sdk && dart pub get && dart test && dart analyze

cd app && flutter test
```

**Tests run against real dependencies, not mocks.** The Go server suite uses
PocketBase's `tests.NewTestApp()` against real PocketBase. The Dart remote-layer
tests spawn the actual `server` binary as a subprocess — one per test file, on
an ephemeral port with a temp data dir — so a green test means the wire contract
holds, not that a hand-written mock agrees with itself. `dart test` runs files in
parallel, so expect a dozen or more PocketBase processes at peak, all isolated
and all torn down in `tearDownAll`.

This means `dart test` needs the `go` toolchain on `PATH`, and network access on
first run to populate `server/`'s module cache.

Development was TDD throughout: test first, watch it fail, minimum code to pass.

## Traps worth knowing

**Drain the child process's pipes.** PocketBase logs heavily at startup (SQL +
request logs). When spawning it as a subprocess, the stdout/stderr pipes must be
drained or the OS pipe buffer fills and the server hangs before it ever binds.
Every first-pass integration test timed out until this was diagnosed. See
`splitcore_sdk/test/support/pb_server.dart`.

**Under `go.work`, use `go build ./splitcore/...`, not `./...` from the root.**
The workspace root is not a module.

**Collection rules cannot reference a collection that does not exist yet.**
PocketBase's rule validator resolves references against what is already
persisted. `InitCollections` therefore saves `groups` with only the rules that
do not mention `group_members`, creates `group_members`, then backfills the
membership rules. Order matters, and the migration is written to be idempotent
because `tests.NewTestApp()` runs migrations during bootstrap before a test can
call `InitCollections` itself.

**Deleting a group needs settlements cleared first.** PocketBase cascades in
alphabetical collection order and `settlements` sorts after `group_members`,
whose rows it still references. The `groups` delete hook pre-deletes them inside
the same transaction. Details in [data-model.md](data-model.md).

**A receipt-compression test needs a realistic fixture.** Writing "the output is
smaller than the input" is harder than it looks: a flat-colour image lets
lossless PNG trivially beat JPEG, per-pixel noise is adversarial for JPEG's DCT
and ideal for PNG's deflate, and a smooth gradient is near-optimal for PNG's row
filters. Gradient-plus-bounded-noise (real photo grain) is the fixture where
JPEG legitimately wins — same as it would on an actual receipt photo.

## Repo layout reference

```
splitcore/
  money/ settle/ balance/    pure math, one test file per source file
  ffi/                       cgo shim (main.go) + handler/ (JSON encode/decode)
  build/                     build_{linux,android,ios}.sh, BUILD.md, smoke_test.py
server/
  main.go                    PocketBase bootstrap + automigrate detection
  migrations/                collections as code, three migrations
  hooks/                     hooks.go (validation, wiring), recompute.go,
                             staleness.go, invite.go, members.go
  internal/testfix/          shared test fixtures
  rules_test.go              access-rule coverage for every collection
splitcore_sdk/
  lib/splitcore_sdk.dart     the sole public export
  lib/src/                   models, ffi/, isolate_calc, calc_api, remote/, sdk
  test/                      mirrors lib/src/; support/ spawns the real server
app/
  lib/main.dart              SDK init, auth-store persistence, lifecycle refresh
  lib/screens/               login, home, group_detail, add_expense, settle_up,
                             activity, new_group, receipt_viewer
  lib/widgets/               avatar, money_text, skeleton, page_body, currency_picker
  lib/theme.dart             design tokens as a ThemeExtension (light + dark)
  lib/{money,activity,display_name}.dart   formatting and feed helpers
docs/
  this wiki + superpowers/   the original spec and the three implementation plans
```
