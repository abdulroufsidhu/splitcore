# splitcore native build guide

`splitcore/ffi` compiles to a C shared library with four exports
(`SplitcoreComputeSplits`, `SplitcoreSimplifyDebts`,
`SplitcoreComputeBalances`, `SplitcoreFree`). Every client — the Flutter
app via `dart:ffi`, the Python smoke test via `ctypes` — talks to that
same ABI: **JSON string in, malloc'd JSON string out, caller must call
`SplitcoreFree` on the result.**

All scripts output under `splitcore/build/out/` (gitignored).

## Verification status

| Target | Script | Output | Verified in dev environment? |
|---|---|---|---|
| Linux x86_64 `.so` | `build_linux.sh` | `out/linux/libsplitcore.so` | ✅ built + ctypes smoke test |
| Android (4 ABIs) | `build_android.sh` | `out/android/jniLibs/<abi>/libsplitcore.so` | ✅ built 4/4 ABIs with NDK r30.0.14904198 |
| iOS arm64 `.a` | `build_ios.sh` | `out/ios/libsplitcore.a` | ❌ requires macOS/Xcode — **user must verify** |
| macOS universal `.dylib` | `build_macos.sh` | `out/macos/libsplitcore.dylib` | ❌ requires macOS/Xcode CLT — **user must verify** |
| Windows x86_64 `.dll` | `build_windows.sh` | `out/windows/splitcore.dll` | ⚠️ untested — no mingw-w64 on the dev host |

## Verifying a build

```bash
./build_linux.sh
nm -D out/linux/libsplitcore.so | grep Splitcore   # 4 symbols
python3 smoke_test.py                              # "smoke test OK"
```

`smoke_test.py` is the ABI contract test: it calls all three JSON exports
plus the error path through raw `ctypes`, with no Dart or Go in the loop.
If it passes, the library is loadable by any FFI client.

## Linux (host)

    ./build_linux.sh
    python3 smoke_test.py        # end-to-end ABI check

## Android

Requires NDK. Set `ANDROID_NDK_HOME`, or the script auto-detects the
newest NDK under `$ANDROID_HOME/ndk`.

    ./build_android.sh

Produces `out/android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libsplitcore.so`.
`make bundle-native` from the repository root copies that tree into
`app/android/app/src/main/jniLibs/`.

Min API: 24 (change `API=` in the script if you need lower; Go requires ≥21).

## iOS

Run **on macOS**:

    ./build_ios.sh

Produces a static archive `out/ios/libsplitcore.a` + `libsplitcore.h`.
Integration: add the `.a` and header to the Xcode project (or wrap in a
CocoaPod/SwiftPM target), then Dart FFI resolves symbols from the process
image via `DynamicLibrary.process()` — static libs are linked into the
app binary on iOS.

Simulator note: for the iOS *simulator* on Apple Silicon you need a
separate `GOOS=ios GOARCH=arm64` build against the `iphonesimulator`
SDK, combined with the device build via `lipo`/`xcodebuild
-create-xcframework`. Deferred until there's an actual iOS app target.

## macOS

Run **on macOS** with the Xcode command line tools:

    ./build_macos.sh

Builds arm64 and x86_64 slices and `lipo`s them into one universal
`out/macos/libsplitcore.dylib`, because Flutter's macOS runner links a
single binary. Add it to the Runner target's "Copy Files" (Frameworks)
phase.

## Windows

    ./build_windows.sh

On Linux this cross-compiles with mingw-w64 (`dnf install mingw64-gcc`,
`apt install gcc-mingw-w64-x86-64`). On Windows, run from Git Bash with a
native gcc (MSYS2 / TDM-GCC) on `PATH` and `CC` unset. Place the resulting
`splitcore.dll` beside the built `.exe` in `app/windows/runner/`.

## Wiring the output into Flutter

- **Android** → `app/android/app/src/main/jniLibs/<abi>/libsplitcore.so`
  (`make bundle-native`); loaded by soname `libsplitcore.so`.
- **Linux desktop** → pass
  `--dart-define=SPLITCORE_LIB_PATH=<abs path to .so>` (`make app` does this).
- **macOS** → `libsplitcore.dylib` in the Runner's embed phase.
- **Windows** → `splitcore.dll` beside the executable.
- **iOS** → link `libsplitcore.a` into the Runner target; Dart opens it
  with `DynamicLibrary.process()` (see
  `splitcore_sdk/lib/src/ffi/bindings.dart`).

## Cross-compilation gotchas

- **Go does not support `-buildmode=c-shared` on iOS.** `c-archive` (a
  static `.a`) is the only supported route; that is why `build_ios.sh`
  differs from every other script here.
- **cgo needs a real cross-compiler**, not just `GOOS`/`GOARCH`. Every
  script sets `CC` explicitly for that reason.
- **`armeabi-v7a` needs `GOARM=7`**, otherwise Go targets ARMv6 and the
  library refuses to load on modern devices.
