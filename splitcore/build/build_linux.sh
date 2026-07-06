#!/usr/bin/env bash
# Builds libsplitcore.so for the host Linux machine.
# Output: splitcore/build/out/linux/libsplitcore.so (+ generated header)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/linux"
mkdir -p "$OUT"

cd "$SCRIPT_DIR/.."
CGO_ENABLED=1 go build -buildmode=c-shared \
  -o "$OUT/libsplitcore.so" ./ffi

echo "Built: $OUT/libsplitcore.so"
