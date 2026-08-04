#!/usr/bin/env bash
# Builds a universal libsplitcore.dylib for macOS (arm64 + x86_64).
# MUST run on macOS with Xcode command line tools (cgo needs Apple clang).
# Output: build/out/macos/libsplitcore.dylib
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: macOS build requires macOS with Xcode command line tools" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/macos"
mkdir -p "$OUT"

cd "$SCRIPT_DIR/.."
for arch in arm64 amd64; do
  env CGO_ENABLED=1 GOOS=darwin GOARCH="$arch" \
    go build -buildmode=c-shared -o "$OUT/libsplitcore-$arch.dylib" ./ffi
done

# Flutter's macOS runner links one binary; lipo the two slices together so
# the same dylib works on Apple Silicon and Intel without a per-arch build.
lipo -create -output "$OUT/libsplitcore.dylib" \
  "$OUT/libsplitcore-arm64.dylib" "$OUT/libsplitcore-amd64.dylib"
rm -f "$OUT/libsplitcore-arm64.dylib" "$OUT/libsplitcore-amd64.dylib"

echo "Built: $OUT/libsplitcore.dylib"
