#!/usr/bin/env bash
# Builds splitcore.dll for Windows x86_64.
# On Linux this cross-compiles via mingw-w64 (dnf install mingw64-gcc /
# apt install gcc-mingw-w64-x86-64). On Windows run this from Git Bash
# with a native gcc (MSYS2/TDM-GCC) on PATH and CC unset.
# Output: build/out/windows/splitcore.dll
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/windows"
mkdir -p "$OUT"

if [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]]; then
  CC_BIN="${CC:-gcc}"
else
  CC_BIN="${CC:-x86_64-w64-mingw32-gcc}"
  command -v "$CC_BIN" >/dev/null || {
    echo "error: $CC_BIN not found — install mingw-w64 to cross-compile" >&2
    exit 1
  }
fi

cd "$SCRIPT_DIR/.."
env CGO_ENABLED=1 GOOS=windows GOARCH=amd64 CC="$CC_BIN" \
  go build -buildmode=c-shared -o "$OUT/splitcore.dll" ./ffi

echo "Built: $OUT/splitcore.dll"
