# splitcore build guide

All scripts output under `splitcore/build/out/` (gitignored).

## Verification status

| Target | Script | Verified in dev environment? |
|---|---|---|
| Linux x86_64 `.so` | `build_linux.sh` | ✅ built + ctypes smoke test |
| Android (4 ABIs) | `build_android.sh` | ✅ built 4/4 ABIs with NDK r30.0.14904198 on 2026-07-06 |
| iOS arm64 `.a` | `build_ios.sh` | ❌ requires macOS/Xcode — **user must verify** |

## Linux (host)

    ./build_linux.sh
    python3 smoke_test.py        # end-to-end ABI check

## Android

Requires NDK. Set `ANDROID_NDK_HOME`, or the script auto-detects the
newest NDK under `$ANDROID_HOME/ndk`.

    ./build_android.sh

Produces `out/android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libsplitcore.so`.
Copy the `jniLibs` folder into the Flutter Android app module
(`android/app/src/main/jniLibs/`), or reference from the SDK's plugin build.

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
