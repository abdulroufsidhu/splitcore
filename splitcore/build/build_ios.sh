#!/usr/bin/env bash
# Cross-compiles splitcore as a static library for iOS arm64.
# MUST run on macOS with Xcode installed (cgo needs Apple clang + SDK).
# Go does not support -buildmode=c-shared on iOS; c-archive is the
# supported route — link the .a into the app and expose via a module map.
# Output: build/out/ios/libsplitcore.a + libsplitcore.h
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: iOS build requires macOS with Xcode" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/ios"
mkdir -p "$OUT"

cd "$SCRIPT_DIR/.."
env CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  SDK=iphoneos \
  CC="$(xcrun --sdk iphoneos --find clang)" \
  CGO_CFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64" \
  CGO_LDFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64" \
  go build -buildmode=c-archive -o "$OUT/libsplitcore.a" ./ffi

echo "Built: $OUT/libsplitcore.a"
