#!/usr/bin/env bash
# Cross-compiles libsplitcore.so for all standard Android ABIs.
# Requires ANDROID_NDK_HOME (or auto-detects newest NDK under
# $ANDROID_HOME/ndk). Output: build/out/android/jniLibs/<abi>/libsplitcore.so
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/android/jniLibs"
API=24

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  base="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk"
  if [[ -d "$base" ]]; then
    ANDROID_NDK_HOME="$base/$(ls "$base" | sort -V | tail -n1)"
  fi
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "error: ANDROID_NDK_HOME not set and no NDK found" >&2
  exit 1
fi

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

# abi:GOARCH:clang-target
targets=(
  "arm64-v8a:arm64:aarch64-linux-android"
  "armeabi-v7a:arm:armv7a-linux-androideabi"
  "x86_64:amd64:x86_64-linux-android"
  "x86:386:i686-linux-android"
)

cd "$SCRIPT_DIR/.."
for t in "${targets[@]}"; do
  IFS=: read -r abi goarch triple <<<"$t"
  mkdir -p "$OUT/$abi"
  echo "building $abi ..."
  env CGO_ENABLED=1 GOOS=android GOARCH="$goarch" \
    ${goarch:+$( [[ $goarch == arm ]] && echo GOARM=7 )} \
    CC="$TOOLCHAIN/${triple}${API}-clang" \
    go build -buildmode=c-shared -trimpath -ldflags="-s -w" \
      -o "$OUT/$abi/libsplitcore.so" ./ffi
done

echo "Done. jniLibs at: $OUT"
