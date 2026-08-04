# Splitcore Foundation & Release Infrastructure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the repository clonable, buildable, testable, and deployable by a developer with zero prior context, with every step verified by CI.

**Architecture:** Nothing about the runtime architecture changes. This plan renames the Go module paths to match the repo (`splitcore`), restores the missing native build scripts that the SDK's own tests already reference, adds a root Makefile as the single entry point for every task, writes the top-level documentation, wires GitHub Actions, and containerizes the PocketBase server.

**Tech Stack:** Go 1.26.4 (stdlib + PocketBase), cgo `-buildmode=c-shared`/`c-archive`, Dart 3.9 / Flutter stable, GitHub Actions, Docker + Compose.

## Global Constraints

- Go toolchain: **1.26.4** (matches `go.work`, `splitcore/go.mod`, `server/go.mod`).
- Dart SDK constraint: **`^3.9.2`** (app), **`^3.9.0`** (splitcore_sdk).
- `splitcore/` stays **stdlib-only**. Never add a dependency to `splitcore/go.mod`.
- Canonical Go module root after this plan: **`github.com/abdulroufsidhu/splitcore`** (matches `git@github.com:abdulroufsidhu/splitcore.git`).
- Canonical product name in all user-facing copy: **Splitcore**. `SlicePay` is retired everywhere except the Dart theme identifiers (`SliceTheme`, `sliceLightTheme`) which are internal and out of scope here.
- All money is `int64` minor units. No floats anywhere near money.
- Build outputs live under `splitcore/build/out/` and stay gitignored.
- Every task ends on a green `make check` (defined in Task 3) before the commit step.

---

### Task 1: Rename Go module paths to `splitcore`

**Files:**
- Modify: `splitcore/go.mod:1`
- Modify: `server/go.mod:1`, `server/go.mod:5-8`
- Modify: `splitcore/balance/balance.go:11-12`
- Modify: `splitcore/balance/balance_test.go:8-9`
- Modify: `splitcore/ffi/handler/handler.go:11-13`
- Modify: `splitcore/ffi/main.go:16`
- Modify: `server/main.go:11-12`
- Modify: `server/hooks/recompute.go:10-11`
- Modify: `server/hooks/hooks_test.go:9`
- Modify: `server/hooks/staleness_test.go:10`
- Modify: `server/internal/testfix/testfix.go:13-14`
- Modify: `server/rules_test.go:21`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: import prefix `github.com/abdulroufsidhu/splitcore/splitcore/...` and `github.com/abdulroufsidhu/splitcore/server/...` used by every later Go task.

**Why the `replace` directive stays:** the repository review called it obsolete. It is not. `go.work` only covers workspace builds; `server/go.mod`'s `replace github.com/abdulroufsidhu/splitcore/splitcore => ../splitcore` is what lets `cd server && go build` work outside the workspace and inside the Docker build in Task 9, where no tagged version of the `splitcore` module is published. Keep it, with the path updated.

- [ ] **Step 1: Confirm the current import surface (this is the list you must end at zero)**

Run:
```bash
cd /home/abdul/Projects/slice_pay
grep -rn "abdulroufsidhu/slice_pay" --include="*.go" --include="*.mod" . | wc -l
```
Expected: `20` (17 import lines + 2 `go.mod` module lines + 1 `replace` line). Write the number down; Step 4 must print `0`.

- [ ] **Step 2: Rewrite every occurrence**

```bash
cd /home/abdul/Projects/slice_pay
grep -rl "abdulroufsidhu/slice_pay" --include="*.go" --include="*.mod" . \
  | xargs sed -i 's|github.com/abdulroufsidhu/slice_pay|github.com/abdulroufsidhu/splitcore|g'
```

- [ ] **Step 3: Drop the stale workspace sum file and re-resolve**

```bash
cd /home/abdul/Projects/slice_pay
rm -f go.work.sum
go work sync
```

`go.work.sum` is keyed by module path; leaving the old one causes a checksum mismatch on the renamed module.

- [ ] **Step 4: Verify no occurrence survives**

Run:
```bash
cd /home/abdul/Projects/slice_pay && grep -rn "slice_pay" --include="*.go" --include="*.mod" . | wc -l
```
Expected: `0`

- [ ] **Step 5: Build and test both Go modules**

Run:
```bash
cd /home/abdul/Projects/slice_pay/splitcore && go build ./... && go test ./...
cd /home/abdul/Projects/slice_pay/server && go build ./... && go test ./...
```
Expected: `ok` for `splitcore/balance`, `splitcore/money`, `splitcore/settle`, `splitcore/ffi/handler`, `server`, `server/hooks`, `server/migrations`, `server/internal/testfix`. No `cannot find module` errors.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: rename Go module paths from slice_pay to splitcore

The repository is github.com/abdulroufsidhu/splitcore but both modules
declared github.com/abdulroufsidhu/slice_pay, so a plain 'go get' of
either module could never resolve."
```

---

### Task 2: Restore the native build scripts

**Files:**
- Create: `splitcore/build/build_linux.sh`
- Create: `splitcore/build/build_android.sh`
- Create: `splitcore/build/build_ios.sh`
- Create: `splitcore/build/build_macos.sh`
- Create: `splitcore/build/build_windows.sh`
- Create: `splitcore/build/smoke_test.py`
- Create: `splitcore/build/BUILD.md`

**Interfaces:**
- Consumes: `splitcore/ffi/main.go` exports `SplitcoreComputeSplits`, `SplitcoreSimplifyDebts`, `SplitcoreComputeBalances`, `SplitcoreFree` (all `char* fn(char*)` except `void SplitcoreFree(char*)`).
- Produces: `splitcore/build/out/linux/libsplitcore.so` — the exact path `splitcore_sdk/test/support/lib_path.dart:11` already hardcodes. CI (Task 8) and the Makefile (Task 3) depend on these script names.

**Context:** `splitcore_sdk/test/support/lib_path.dart` already throws `libsplitcore.so not found at $path — run splitcore/build/build_linux.sh first`. The script it names has never existed in the repo, so every FFI test in the SDK is currently unrunnable from a clean clone. This task closes that gap.

- [ ] **Step 1: Write the Linux build script**

Create `splitcore/build/build_linux.sh`:

```bash
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
```

- [ ] **Step 2: Build it and verify the exported symbols**

Run:
```bash
cd /home/abdul/Projects/slice_pay
chmod +x splitcore/build/build_linux.sh
./splitcore/build/build_linux.sh
nm -D splitcore/build/out/linux/libsplitcore.so | grep Splitcore
```
Expected: `Built: .../out/linux/libsplitcore.so`, then four lines containing
`T SplitcoreComputeBalances`, `T SplitcoreComputeSplits`, `T SplitcoreFree`, `T SplitcoreSimplifyDebts`.

- [ ] **Step 3: Write the ctypes smoke test**

Create `splitcore/build/smoke_test.py`:

```python
#!/usr/bin/env python3
"""Smoke test for libsplitcore.so — proves the C ABI works end to end."""
import ctypes
import json
import os

so_path = os.path.join(os.path.dirname(__file__), "out", "linux", "libsplitcore.so")
lib = ctypes.CDLL(so_path)

for fn in ("SplitcoreComputeSplits", "SplitcoreSimplifyDebts", "SplitcoreComputeBalances"):
    getattr(lib, fn).argtypes = [ctypes.c_char_p]
    getattr(lib, fn).restype = ctypes.c_void_p  # keep pointer for Free
lib.SplitcoreFree.argtypes = [ctypes.c_void_p]


def call(fn, req: dict) -> dict:
    ptr = getattr(lib, fn)(json.dumps(req).encode())
    try:
        return json.loads(ctypes.string_at(ptr).decode())
    finally:
        lib.SplitcoreFree(ptr)


splits = call("SplitcoreComputeSplits", {
    "type": "equal", "total_cents": 10000,
    "entries": [{"member_id": m} for m in ("a", "b", "c")],
})
assert splits == {"splits": [
    {"member_id": "a", "amount_cents": 3334},
    {"member_id": "b", "amount_cents": 3333},
    {"member_id": "c", "amount_cents": 3333},
]}, splits

transfers = call("SplitcoreSimplifyDebts", {
    "balances": [{"member_id": "a", "net_cents": 500},
                 {"member_id": "b", "net_cents": -500}],
})
assert transfers == {"transfers": [
    {"from_member_id": "b", "to_member_id": "a", "amount_cents": 500},
]}, transfers

balances = call("SplitcoreComputeBalances", {
    "expenses": [{"payer_id": "a", "amount_cents": 1000,
                  "splits": [{"member_id": "b", "amount_cents": 1000}]}],
    "settlements": [{"from_member_id": "b", "to_member_id": "a", "amount_cents": 400}],
})
assert balances == {"balances": [
    {"member_id": "a", "net_cents": 600},
    {"member_id": "b", "net_cents": -600},
]}, balances

err = call("SplitcoreComputeSplits", {"type": "magic", "total_cents": 1, "entries": []})
assert "error" in err, err

print("smoke test OK")
```

- [ ] **Step 4: Run the smoke test**

Run: `python3 splitcore/build/smoke_test.py`
Expected: `smoke test OK`

If any assertion fails, the FFI JSON contract drifted from `splitcore/ffi/handler/handler.go` — fix the expectation to match the handler's actual field names, not the other way around, and note it in the commit.

- [ ] **Step 5: Write the Android build script**

Create `splitcore/build/build_android.sh`:

```bash
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
    $( [[ $goarch == arm ]] && echo GOARM=7 ) \
    CC="$TOOLCHAIN/${triple}${API}-clang" \
    go build -buildmode=c-shared -o "$OUT/$abi/libsplitcore.so" ./ffi
done

echo "Done. jniLibs at: $OUT"
```

- [ ] **Step 6: Write the iOS build script**

Create `splitcore/build/build_ios.sh`:

```bash
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
```

- [ ] **Step 7: Write the macOS build script**

Create `splitcore/build/build_macos.sh`:

```bash
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
```

- [ ] **Step 8: Write the Windows build script**

Create `splitcore/build/build_windows.sh`:

```bash
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
```

- [ ] **Step 9: Make every script executable and run the ones this host supports**

Run:
```bash
cd /home/abdul/Projects/slice_pay
chmod +x splitcore/build/*.sh
./splitcore/build/build_linux.sh && python3 splitcore/build/smoke_test.py
ls "$HOME/Android/Sdk/ndk" >/dev/null 2>&1 \
  && ./splitcore/build/build_android.sh \
  || echo "NDK absent — Android build unverified on this host"
command -v x86_64-w64-mingw32-gcc >/dev/null \
  && ./splitcore/build/build_windows.sh \
  || echo "mingw-w64 absent — Windows build unverified on this host"
```
Expected: linux build + `smoke test OK`. Android/Windows either build or print the "unverified" line — both are acceptable outcomes here; record which happened in the commit body. macOS/iOS cannot be verified on Linux at all.

- [ ] **Step 10: Write the build guide**

Create `splitcore/build/BUILD.md`:

```markdown
# splitcore native build guide

`splitcore/ffi` compiles to a C shared library with four exports
(`SplitcoreComputeSplits`, `SplitcoreSimplifyDebts`,
`SplitcoreComputeBalances`, `SplitcoreFree`). Every client — the Flutter
app via `dart:ffi`, the Python smoke test via `ctypes` — talks to that
same ABI: **JSON string in, malloc'd JSON string out, caller must call
`SplitcoreFree` on the result.**

All scripts write under `splitcore/build/out/`, which is gitignored.

## Targets

| Target | Script | Output | Host required |
|---|---|---|---|
| Linux x86_64 | `build_linux.sh` | `out/linux/libsplitcore.so` | Linux + gcc |
| Android (4 ABIs) | `build_android.sh` | `out/android/jniLibs/<abi>/libsplitcore.so` | Any + Android NDK |
| iOS arm64 | `build_ios.sh` | `out/ios/libsplitcore.a` | macOS + Xcode |
| macOS universal | `build_macos.sh` | `out/macos/libsplitcore.dylib` | macOS + Xcode CLT |
| Windows x86_64 | `build_windows.sh` | `out/windows/splitcore.dll` | Any + mingw-w64 (or native gcc on Windows) |

## Verifying a build

```bash
./build_linux.sh
nm -D out/linux/libsplitcore.so | grep Splitcore   # 4 symbols
python3 smoke_test.py                              # "smoke test OK"
```

`smoke_test.py` is the ABI contract test: it calls all three JSON exports
plus the error path through raw `ctypes`, with no Dart or Go in the loop.
If it passes, the library is loadable by any FFI client.

## Wiring the output into Flutter

`make bundle-native` (root Makefile) copies build outputs into the Flutter
runner trees:

- Android → `app/android/app/src/main/jniLibs/<abi>/libsplitcore.so`
- Linux desktop → pass `--dart-define=SPLITCORE_LIB_PATH=<abs path to .so>`
- macOS → `app/macos/Runner/libsplitcore.dylib`, added to the Xcode target's
  "Embed Frameworks"/"Copy Files" phase
- Windows → `app/windows/runner/splitcore.dll` beside the built .exe
- iOS → link `libsplitcore.a` into the Runner target and expose it through a
  module map; the Dart side then opens it with `DynamicLibrary.process()`
  (see `splitcore_sdk/lib/src/ffi/bindings.dart`)

## Cross-compilation gotchas

- **Go does not support `-buildmode=c-shared` on iOS.** `c-archive` (a static
  `.a`) is the only supported route; that is why `build_ios.sh` differs.
- **cgo needs a real cross-compiler**, not just `GOOS`/`GOARCH`. Every script
  sets `CC` explicitly for that reason.
- **`armeabi-v7a` needs `GOARM=7`**, otherwise Go targets ARMv6 and the
  library refuses to load on modern devices.
```

- [ ] **Step 11: Commit**

```bash
git add splitcore/build
git commit -m "build: add native library build scripts for all five targets

splitcore_sdk/test/support/lib_path.dart already pointed at
splitcore/build/out/linux/libsplitcore.so and named build_linux.sh in its
error message, but no build script was ever committed, so the SDK's FFI
tests could not run from a clean clone."
```

---

### Task 3: Root Makefile

**Files:**
- Create: `Makefile`

**Interfaces:**
- Consumes: `splitcore/build/build_*.sh` from Task 2.
- Produces: `make check` (used as the pre-commit gate by every later task), `make native`, `make bundle-native`, `make server`, `make app`, `make test`, `make fmt`. CI (Task 8) calls the same targets so local and CI behavior cannot diverge.

- [ ] **Step 1: Write the Makefile**

Create `Makefile`:

```makefile
# Single entry point for every development task. CI runs these same
# targets, so "green locally" and "green in CI" mean the same thing.
.DEFAULT_GOAL := help
.PHONY: help native bundle-native server app test test-go test-sdk test-app \
        fmt fmt-check vet analyze check clean

SPLITCORE_SO := splitcore/build/out/linux/libsplitcore.so
JNI_LIBS     := splitcore/build/out/android/jniLibs
APP_JNI      := app/android/app/src/main/jniLibs

help: ## Show this help
	@grep -hE '^[a-z-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

native: $(SPLITCORE_SO) ## Build libsplitcore.so for this Linux host

$(SPLITCORE_SO): $(shell find splitcore -name '*.go' -not -name '*_test.go')
	./splitcore/build/build_linux.sh

bundle-native: ## Copy Android jniLibs into the Flutter runner tree
	./splitcore/build/build_android.sh
	mkdir -p $(APP_JNI)
	cp -r $(JNI_LIBS)/. $(APP_JNI)/
	@echo "Bundled jniLibs into $(APP_JNI)"

server: ## Run the PocketBase server on all interfaces, port 8090
	cd server && go run . serve --http=0.0.0.0:8090

app: native ## Run the Flutter app against a local server
	cd app && flutter run \
		--dart-define=SPLITCORE_LIB_PATH=$(CURDIR)/$(SPLITCORE_SO)

test: test-go test-sdk test-app ## Run every test suite

test-go: ## Go unit tests (splitcore + server) and the FFI ABI smoke test
	cd splitcore && go test ./...
	cd server && go test ./...
	$(MAKE) native
	python3 splitcore/build/smoke_test.py

test-sdk: native ## Dart SDK tests (spawns a real PocketBase server)
	cd splitcore_sdk && dart pub get && dart test

test-app: ## Flutter widget tests
	cd app && flutter pub get && flutter test

fmt: ## Format Go and Dart sources in place
	cd splitcore && gofmt -w .
	cd server && gofmt -w .
	cd splitcore_sdk && dart format --line-length 100 .
	cd app && dart format --line-length 100 .

fmt-check: ## Fail if anything is unformatted
	@out=$$(gofmt -l splitcore server); \
	if [ -n "$$out" ]; then echo "unformatted Go files:"; echo "$$out"; exit 1; fi
	cd splitcore_sdk && dart format --line-length 100 --set-exit-if-changed -o none .
	cd app && dart format --line-length 100 --set-exit-if-changed -o none .

vet: ## go vet both modules
	cd splitcore && go vet ./...
	cd server && go vet ./...

analyze: ## Dart/Flutter static analysis
	cd splitcore_sdk && dart pub get && dart analyze --fatal-infos
	cd app && flutter pub get && flutter analyze --fatal-infos

check: fmt-check vet analyze test ## Everything CI runs, in CI's order

clean: ## Remove build outputs
	rm -rf splitcore/build/out
	cd app && flutter clean
```

- [ ] **Step 2: Verify the help target and the formatting gate**

Run:
```bash
cd /home/abdul/Projects/slice_pay && make help && make fmt-check
```
Expected: the target list prints. `make fmt-check` either passes or lists unformatted files — if it lists files, run `make fmt`, re-run `make fmt-check`, and include the reformatting in this task's commit.

- [ ] **Step 3: Verify the full gate runs green**

Run: `cd /home/abdul/Projects/slice_pay && make check`
Expected: exits 0. The `test-sdk` leg spawns a real PocketBase subprocess via `go run` and is slow (minutes on a cold Go cache) — that is normal, not a hang.

- [ ] **Step 4: Commit**

```bash
git add Makefile
git commit -m "build: add root Makefile as the single entry point

make check is the same gate CI runs, so local green and CI green cannot
diverge."
```

---

### Task 4: Platform-correct backend URL configuration

**Files:**
- Create: `app/lib/config.dart`
- Create: `app/test/config_test.dart`
- Modify: `app/lib/main.dart:14-19` (delete `_defaultPocketbaseUrl`), `app/lib/main.dart:84` (use the new resolver)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `String resolveBackendUrl({required String override, required bool isAndroid, required bool isIos})` in `app/lib/config.dart`, plus `String defaultBackendUrl()` which calls it with the real `Platform` values and the `POCKETBASE_URL` dart-define.

**The bug:** `app/lib/main.dart:18` defaults to `http://192.168.240.1:8090` — one developer's Waydroid gateway address. Line 14's own comment says the default should be the Android emulator alias `10.0.2.2`, so the code contradicts its own documentation, and a fresh clone cannot reach a server on any other machine.

- [ ] **Step 1: Write the failing test**

Create `app/test/config_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';

import 'package:app/config.dart';

void main() {
  test('an explicit --dart-define wins on every platform', () {
    expect(
      resolveBackendUrl(override: 'https://api.example.com', isAndroid: true, isIos: false),
      'https://api.example.com',
    );
    expect(
      resolveBackendUrl(override: 'https://api.example.com', isAndroid: false, isIos: false),
      'https://api.example.com',
    );
  });

  test('Android falls back to the emulator host alias, not a LAN address', () {
    final url = resolveBackendUrl(override: '', isAndroid: true, isIos: false);
    expect(url, 'http://10.0.2.2:8090');
  });

  test('iOS simulator and desktop fall back to localhost', () {
    expect(resolveBackendUrl(override: '', isAndroid: false, isIos: true), 'http://127.0.0.1:8090');
    expect(resolveBackendUrl(override: '', isAndroid: false, isIos: false), 'http://127.0.0.1:8090');
  });

  test('no fallback is a machine-specific address', () {
    for (final url in [
      resolveBackendUrl(override: '', isAndroid: true, isIos: false),
      resolveBackendUrl(override: '', isAndroid: false, isIos: false),
    ]) {
      expect(url.contains('192.168.'), isFalse, reason: 'LAN address baked into a default: $url');
    }
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd app && flutter test test/config_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'app'` / `config.dart` does not exist.

- [ ] **Step 3: Write the implementation**

Create `app/lib/config.dart`:

```dart
// Where the app looks for the PocketBase server. A default is only ever a
// development convenience: any real build passes
// --dart-define=POCKETBASE_URL=https://... and never reaches the fallbacks.
import 'dart:io';

/// The compile-time override. Empty when no --dart-define was passed.
const _override = String.fromEnvironment('POCKETBASE_URL');

/// Port the server binds by default (`make server`).
const _devPort = 8090;

/// Picks the dev-time server URL for the running platform.
///
/// [override] wins outright when non-empty. Otherwise: Android maps to
/// `10.0.2.2`, the emulator's alias for the host machine's loopback (a
/// plain `127.0.0.1` inside the emulator is the emulator itself). Every
/// other platform — iOS simulator, Linux, macOS, Windows, web — shares the
/// host's loopback and uses `127.0.0.1` directly.
///
/// A physical device is on neither: it must be given an explicit
/// --dart-define pointing at the host's LAN address or a deployed server.
String resolveBackendUrl({
  required String override,
  required bool isAndroid,
  required bool isIos,
}) {
  if (override.isNotEmpty) return override;
  if (isAndroid) return 'http://10.0.2.2:$_devPort';
  return 'http://127.0.0.1:$_devPort';
}

/// [resolveBackendUrl] applied to the real platform and dart-defines.
String defaultBackendUrl() => resolveBackendUrl(
      override: _override,
      isAndroid: Platform.isAndroid,
      isIos: Platform.isIOS,
    );
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/config_test.dart`
Expected: `All tests passed!` (4 tests)

- [ ] **Step 5: Use it in main.dart**

In `app/lib/main.dart`, delete lines 14-19 (the `_defaultPocketbaseUrl` constant and its comment) and add the import:

```dart
import 'config.dart';
```

Then change the SDK initialization at line 84 from:

```dart
      pocketbaseUrl: _defaultPocketbaseUrl,
```

to:

```dart
      pocketbaseUrl: defaultBackendUrl(),
```

- [ ] **Step 6: Verify the app still analyzes and tests clean**

Run: `cd app && flutter analyze --fatal-infos && flutter test`
Expected: `No issues found!` then `All tests passed!`

- [ ] **Step 7: Commit**

```bash
git add app/lib/config.dart app/lib/main.dart app/test/config_test.dart
git commit -m "fix(app): resolve backend URL per platform instead of a hardcoded LAN IP

The default was 192.168.240.1 (one developer's Waydroid gateway),
contradicting the comment directly above it. Android now defaults to the
emulator alias 10.0.2.2, everything else to 127.0.0.1, and
--dart-define=POCKETBASE_URL overrides both."
```

---

### Task 5: Repository and Flutter metadata

**Files:**
- Modify: `app/pubspec.yaml:1-2` (name + description)
- Modify: `app/test/widget_test.dart:6-7` (package imports)
- Modify: `app/test/display_name_test.dart` (package imports)
- Modify: `app/test/config_test.dart:3` (package import from Task 4)
- Rewrite: `app/README.md`
- Move: `prompt.md` → `docs/prompt.md`

**Interfaces:**
- Consumes: `app/test/config_test.dart` from Task 4.
- Produces: Dart package name `splitcore_app`; every `package:app/...` import becomes `package:splitcore_app/...`.

- [ ] **Step 1: Find every import that must change**

Run:
```bash
cd /home/abdul/Projects/slice_pay && grep -rn "package:app/" app/ --include="*.dart"
```
Expected: matches only in `app/test/` (library code uses relative imports). Note the exact list — Step 3 must leave zero.

- [ ] **Step 2: Rename the package and fix the description**

In `app/pubspec.yaml`, replace lines 1-2:

```yaml
name: app
description: "A new Flutter project."
```

with:

```yaml
name: splitcore_app
description: "Splitcore mobile and desktop client: shared expense groups, split math via the splitcore FFI engine, settlements, and receipts."
```

- [ ] **Step 3: Update the imports**

```bash
cd /home/abdul/Projects/slice_pay
grep -rl "package:app/" app --include="*.dart" | xargs sed -i 's|package:app/|package:splitcore_app/|g'
grep -rn "package:app/" app --include="*.dart" | wc -l   # must print 0
```

- [ ] **Step 4: Replace the default Flutter README**

Overwrite `app/README.md`:

```markdown
# splitcore_app

The Splitcore Flutter client — groups, expenses, settlements, balances, and
receipts. It talks to **nothing** directly: all money math goes through
`splitcore_sdk`, which calls the compiled Go engine over FFI, and all
persistence goes through the same SDK's PocketBase-backed remote layer.

## Run it

From the repository root:

```bash
make server   # terminal 1 — PocketBase on :8090
make app      # terminal 2 — builds libsplitcore.so, then flutter run
```

`make app` passes `--dart-define=SPLITCORE_LIB_PATH` pointing at the
freshly built Linux library. On Android the library is loaded by soname
from the APK's bundled `jniLibs` — run `make bundle-native` once (requires
the Android NDK) before the first Android run.

## Point it at a different server

```bash
flutter run --dart-define=POCKETBASE_URL=https://splitcore.example.com
```

Without an override the app targets `10.0.2.2:8090` on Android (the
emulator's alias for the host) and `127.0.0.1:8090` everywhere else — see
`lib/config.dart`. A **physical device** matches neither and always needs
the explicit define.

## Tests

```bash
make test-app          # or: flutter test
```

## Layout

| Path | Responsibility |
|---|---|
| `lib/main.dart` | App bootstrap, session lifecycle, root routing |
| `lib/config.dart` | Backend URL resolution |
| `lib/theme.dart` | Colors, typography, light/dark themes |
| `lib/screens/` | One file per screen |
| `lib/widgets/` | Shared presentational widgets |
| `lib/money.dart`, `lib/activity.dart`, `lib/display_name.dart` | Pure formatting/derivation helpers (unit-tested, no I/O) |
```

- [ ] **Step 5: Move `prompt.md` out of the repository root**

```bash
cd /home/abdul/Projects/slice_pay
git mv prompt.md docs/prompt.md 2>/dev/null || mv prompt.md docs/prompt.md
```

- [ ] **Step 6: Verify the app still builds and tests**

Run: `cd app && flutter pub get && flutter analyze --fatal-infos && flutter test`
Expected: `No issues found!` then all tests pass (MoneyText, display name, config).

- [ ] **Step 7: Commit**

```bash
git add -A app docs/prompt.md
git rm --cached prompt.md 2>/dev/null || true
git commit -m "chore: rename Flutter package to splitcore_app, replace template metadata

Also moves prompt.md into docs/ so the repository root only holds files a
newcomer needs on arrival."
```

---

### Task 6: Root README

**Files:**
- Create: `README.md`

**Interfaces:**
- Consumes: `make` targets from Task 3, build scripts from Task 2, `POCKETBASE_URL` define from Task 4, package name from Task 5.
- Produces: the entry point every other doc links back to.

**Do not duplicate:** `server/README.md` already documents collections, access rules, the staleness endpoint, incomplete-expense semantics, and the balances cache. `splitcore/build/BUILD.md` documents native targets. `docs/` holds the architecture wiki. The root README links to them; it does not restate them.

- [ ] **Step 1: Write the README**

Create `README.md`:

```markdown
# Splitcore

A Splitwise-style expense splitter — groups record shared expenses,
Splitcore works out who owes whom, and settlements clear the balances.

**The one architectural rule:** there is exactly one implementation of the
money math, and both the server and the client run that same compiled Go
code. The server calls it as a Go package; the Flutter app calls it over
FFI. Split amounts can never disagree between client and server, because
there is no second implementation to disagree with.

```
splitcore/        Pure Go, stdlib only. money / settle / balance + cgo FFI shim.
server/           Go + PocketBase. Schema, access rules, validation hooks, balance recompute.
splitcore_sdk/    Dart. FFI bindings + PocketBase client. The only API the app may use.
app/              Flutter. UI only — no money math, no direct PocketBase access.
docs/             Architecture, data model, data flow, API reference, decisions.
```

## Quick start

Requires **Go 1.26.4**, **Flutter (Dart 3.9+)**, **Python 3** (ABI smoke
test), and a C toolchain (`gcc`) for cgo.

```bash
git clone git@github.com:abdulroufsidhu/splitcore.git
cd splitcore
make check     # builds the native library and runs every test suite
```

Then, in two terminals:

```bash
make server    # PocketBase on http://0.0.0.0:8090 (admin UI at /_/)
make app       # builds libsplitcore.so and launches the Flutter app
```

On first run, open `http://127.0.0.1:8090/_/` to create the superuser
account; migrations create all six collections automatically under
`go run`. Then sign up in the app, create a group, add an expense, and
settle up.

## Make targets

| Target | Does |
|---|---|
| `make check` | fmt check + vet + analyze + every test. What CI runs. |
| `make native` | Build `libsplitcore.so` for this Linux host |
| `make bundle-native` | Cross-compile Android ABIs and copy into the Flutter runner |
| `make server` | Run PocketBase on `0.0.0.0:8090` |
| `make app` | Run the Flutter app against a local server |
| `make test` | Go + Dart SDK + Flutter tests |
| `make fmt` | Format Go and Dart in place |
| `make clean` | Delete build outputs |

## Building the native library

`splitcore/build/` holds one script per target — Linux, Android (4 ABIs),
iOS, macOS, Windows — plus a `ctypes` smoke test that exercises the C ABI
with no Dart or Go in the loop. See
[`splitcore/build/BUILD.md`](splitcore/build/BUILD.md) for host
requirements and cross-compilation gotchas.

## Running the server

See [`server/README.md`](server/README.md) for collections, access rules,
the staleness endpoint, and the balances-cache contract.

For a container: `docker compose up -d` (see
[Deployment](#deployment) below).

## Running the app

```bash
cd app && flutter run --dart-define=POCKETBASE_URL=https://your-server
```

Without the define, the app targets the local dev server — `10.0.2.2:8090`
on Android emulators, `127.0.0.1:8090` elsewhere. Physical devices always
need the explicit define. See [`app/README.md`](app/README.md).

## Running the tests

```bash
make test        # everything
make test-go     # Go unit tests + FFI ABI smoke test
make test-sdk    # Dart SDK tests (spawns a real PocketBase subprocess)
make test-app    # Flutter widget tests
```

The SDK's integration tests start the actual server on an ephemeral port
with a temp data directory — they test the real wire contract, not a mock.

## Deployment

```bash
docker compose up -d
curl http://localhost:8090/api/health
```

See [`docs/deployment.md`](docs/deployment.md) for HTTPS termination,
backups, and restore.

## Documentation

| Doc | Covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Component boundaries and why they are where they are |
| [docs/data-model.md](docs/data-model.md) | Collections, fields, relations |
| [docs/data-flow.md](docs/data-flow.md) | A request's path from tap to balance |
| [docs/api-reference.md](docs/api-reference.md) | SDK and HTTP surface |
| [docs/decisions.md](docs/decisions.md) | Architectural decisions and their tradeoffs |
| [docs/development.md](docs/development.md) | Day-to-day workflow |
| [docs/deployment.md](docs/deployment.md) | Containers, HTTPS, backups |

## Roadmap

- **Now:** module/repo consistency, CI, native packaging, containerized server.
- **Next:** SDK correctness — parameterized filters, pagination, atomic
  expense writes, expense editing, password reset and email verification.
- **Then:** app maturity — offline reads, error and retry states,
  accessibility, localization, search, export.

## License

MIT — see [LICENSE](LICENSE).
```

- [ ] **Step 2: Verify every relative link resolves**

Run:
```bash
cd /home/abdul/Projects/slice_pay
grep -o '](\([^)#][^)]*\))' README.md | sed 's/](//;s/)$//' | while read -r f; do
  [ -e "$f" ] || echo "MISSING: $f"
done
```
Expected: only `MISSING: docs/deployment.md` and `MISSING: LICENSE` — both are created in Tasks 9 and 7. Anything else missing is a typo to fix now.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add root README

Covers overview, architecture, layout, setup, native builds, running the
server and app, tests, deployment, and the roadmap. Links to the existing
server/ and docs/ material rather than restating it."
```

---

### Task 7: LICENSE, CONTRIBUTING, SECURITY, CHANGELOG

**Files:**
- Create: `LICENSE`
- Create: `CONTRIBUTING.md`
- Create: `SECURITY.md`
- Create: `CHANGELOG.md`

**Interfaces:**
- Consumes: `make check` from Task 3 (CONTRIBUTING requires it before every PR).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Write the MIT license**

Create `LICENSE`:

```
MIT License

Copyright (c) 2026 Abdul Rauf

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Write CONTRIBUTING.md**

Create `CONTRIBUTING.md`:

```markdown
# Contributing to Splitcore

## Before you open a PR

```bash
make check
```

That is exactly what CI runs — fmt check, `go vet`, Dart/Flutter analysis,
and all three test suites. A PR that fails it will fail CI.

## Setting up

Install Go 1.26.4, Flutter (Dart 3.9+), Python 3, and a C toolchain. Then:

```bash
make native     # builds libsplitcore.so — the SDK's FFI tests need it
make check
```

The Android NDK is only needed for `make bundle-native`; macOS/Xcode only
for the iOS and macOS libraries.

## Where code goes

- **Money math** goes in `splitcore/` (Go, stdlib only) — never in Dart,
  never in a PocketBase hook. Both the server and the app run this same
  code; a second implementation is a bug by definition.
- **Server rules and validation** go in `server/hooks/` with a matching
  test in `server/hooks/*_test.go` or `server/rules_test.go`.
- **Anything touching PocketBase from the client** goes in
  `splitcore_sdk/lib/src/remote/`. No PocketBase type may cross out of that
  layer — convert to a model in `models.dart` at the boundary.
- **UI** goes in `app/lib/`. If a screen needs data, it asks the SDK.

## Tests

Write the failing test first. Every bug fix starts with a test that
reproduces the bug.

- Go: table-driven tests next to the code.
- SDK: `splitcore_sdk/test/` — integration tests spawn the real server via
  `test/support/pb_server.dart`, so they exercise the actual wire contract.
- App: `app/test/` — widget tests; keep pure logic in plain functions
  (`money.dart`, `activity.dart`, `display_name.dart`) so it can be tested
  without pumping a widget.

## Commits

Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `build:`,
`test:`, `chore:`. Explain **why** in the body when the change is not
self-evident. Small, frequent commits over one large one.

## Money rules

- `int64` minor units everywhere. Never a float, never a `double`.
- Rounding is largest-remainder, implemented once in `splitcore/money`.
- Splits must sum exactly to the expense total — the server skips any
  expense whose split entries do not, so a rounding bug silently drops the
  expense out of every balance.
```

- [ ] **Step 3: Write SECURITY.md**

Create `SECURITY.md`:

```markdown
# Security Policy

## Reporting a vulnerability

Report privately via GitHub's **Security → Report a vulnerability** on
`abdulroufsidhu/splitcore`. Do not open a public issue for an
unpatched vulnerability. Expect an acknowledgement within 7 days.

Please include: what you can access that you should not, the steps to
reproduce it, and the affected component (`splitcore`, `server`,
`splitcore_sdk`, or `app`).

## Supported versions

Splitcore is pre-1.0. Only the `master` branch receives security fixes.

## Security model

- **Authentication** is PocketBase's `users` auth collection; the client
  holds a JWT persisted by the platform's shared-preferences store.
- **Authorization** is enforced by PocketBase collection rules, not by the
  client. Every collection is member-scoped: you can only list or view
  rows belonging to a group you are a member of. `groups` update/delete is
  owner-only. `balances` has no client-facing write rule at all — only the
  server-side recompute hook can write it.
- **Server-side validation** in `server/hooks/` is authoritative. The
  client computes splits locally for a responsive UI, but the server
  re-validates every write; a malicious client cannot write a split that
  disagrees with the engine.
- **Trust boundary:** treat everything from the client as hostile. Any new
  hook that reads a client-supplied id must re-check group membership.

## Deployment expectations

- **Always terminate TLS** in front of the server. PocketBase serves plain
  HTTP by default; a token sent over HTTP is a token stolen.
- Change the default superuser credentials before exposing the admin UI.
- Restrict `/_/` (the admin UI) at the reverse proxy to trusted addresses.
- Back up `pb_data/` — it holds the SQLite database *and* uploaded
  receipts. See `docs/deployment.md`.
```

- [ ] **Step 4: Write CHANGELOG.md**

Create `CHANGELOG.md`:

```markdown
# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Root `README.md`, `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, and
  this changelog.
- Native build scripts for Linux, Android (4 ABIs), iOS, macOS, and
  Windows, plus a `ctypes` ABI smoke test (`splitcore/build/`).
- Root `Makefile` — `make check` is the single gate shared by developers
  and CI.
- GitHub Actions CI: format, vet, analyze, and all three test suites.
- `Dockerfile` and `docker-compose.yml` for the server, with a health
  check and a documented backup/restore procedure.

### Changed
- Go module paths renamed from `github.com/abdulroufsidhu/slice_pay/...`
  to `github.com/abdulroufsidhu/splitcore/...` to match the repository.
- Flutter package renamed `app` → `splitcore_app`, with a real description
  and README replacing the Flutter template.
- `prompt.md` moved to `docs/`.

### Fixed
- The app's default backend URL was a hardcoded LAN address
  (`192.168.240.1`) that only worked on one developer's machine. It is now
  resolved per platform, with `--dart-define=POCKETBASE_URL` overriding.
```

- [ ] **Step 5: Verify the README's LICENSE link now resolves**

Run:
```bash
cd /home/abdul/Projects/slice_pay && test -e LICENSE && echo "LICENSE present"
```
Expected: `LICENSE present`

- [ ] **Step 6: Commit**

```bash
git add LICENSE CONTRIBUTING.md SECURITY.md CHANGELOG.md
git commit -m "docs: add LICENSE, CONTRIBUTING, SECURITY, and CHANGELOG"
```

---

### Task 8: GitHub Actions CI

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `make fmt-check`, `make vet`, `make test-go`, `make test-sdk`, `make test-app`, `make analyze` from Task 3; `splitcore/build/build_linux.sh` from Task 2.
- Produces: the green check the First Milestone requires.

**Job split rationale:** three jobs, not one — a Go compile error should not hide a Flutter analysis failure, and the Dart SDK job is the slow one (it spawns a real PocketBase server per test group) so it should not gate the fast feedback from the others.

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:
  workflow_dispatch:

# A new push to the same branch cancels the previous run — CI minutes are
# not free and a superseded run tells you nothing.
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

env:
  GO_VERSION: '1.26.4'

jobs:
  go:
    name: Go (vet, fmt, tests, FFI ABI)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache-dependency-path: |
            splitcore/go.sum
            server/go.sum

      - name: gofmt
        run: |
          out=$(gofmt -l splitcore server)
          if [ -n "$out" ]; then
            echo "::error::unformatted Go files:"; echo "$out"; exit 1
          fi

      - name: go vet
        run: make vet

      - name: Go tests
        run: |
          cd splitcore && go test ./... -count=1
          cd ../server && go test ./... -count=1

      - name: Build libsplitcore.so and verify the C ABI
        run: |
          ./splitcore/build/build_linux.sh
          nm -D splitcore/build/out/linux/libsplitcore.so | grep -c Splitcore
          python3 splitcore/build/smoke_test.py

      - name: Upload the native library for the SDK job
        uses: actions/upload-artifact@v4
        with:
          name: libsplitcore-linux
          path: splitcore/build/out/linux/
          retention-days: 1

  sdk:
    name: Dart SDK (analyze, tests against a real server)
    runs-on: ubuntu-latest
    needs: go
    steps:
      - uses: actions/checkout@v4

      # The SDK's integration tests spawn `go run .` in ../server, so this
      # job needs the Go toolchain even though it runs Dart tests.
      - uses: actions/setup-go@v5
        with:
          go-version: ${{ env.GO_VERSION }}
          cache-dependency-path: |
            splitcore/go.sum
            server/go.sum

      - uses: dart-lang/setup-dart@v1

      # test/support/lib_path.dart resolves exactly this path.
      - name: Download libsplitcore.so
        uses: actions/download-artifact@v4
        with:
          name: libsplitcore-linux
          path: splitcore/build/out/linux/

      - name: Install dependencies
        working-directory: splitcore_sdk
        run: dart pub get

      - name: Analyze
        working-directory: splitcore_sdk
        run: dart analyze --fatal-infos

      - name: Format check
        working-directory: splitcore_sdk
        run: dart format --line-length 100 --set-exit-if-changed -o none .

      - name: Test
        working-directory: splitcore_sdk
        run: dart test --reporter expanded
        timeout-minutes: 15

  flutter:
    name: Flutter app (analyze, widget tests)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Install dependencies
        working-directory: app
        run: flutter pub get

      - name: Analyze
        working-directory: app
        run: flutter analyze --fatal-infos

      - name: Format check
        working-directory: app
        run: dart format --line-length 100 --set-exit-if-changed -o none .

      - name: Test
        working-directory: app
        run: flutter test --reporter expanded
```

- [ ] **Step 2: Verify the workflow parses**

Run:
```bash
cd /home/abdul/Projects/slice_pay
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('workflow YAML OK')"
```
Expected: `workflow YAML OK`

- [ ] **Step 3: Verify locally that what CI runs actually passes**

Run: `cd /home/abdul/Projects/slice_pay && make check`
Expected: exits 0. CI runs the same commands; if this fails, CI will too.

- [ ] **Step 4: Commit and confirm the first run is green**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: add GitHub Actions for Go, Dart SDK, and Flutter

Three jobs so a Go failure does not mask a Flutter one. The SDK job
consumes the .so built by the Go job as an artifact, since its FFI tests
resolve splitcore/build/out/linux/libsplitcore.so by path."
git push
gh run watch
```
Expected: all three jobs succeed. If `sdk` times out, raise `timeout-minutes` — the PocketBase subprocess startup dominates that job on a cold cache.

---

### Task 9: Containerize the server

**Files:**
- Create: `server/Dockerfile`
- Create: `docker-compose.yml`
- Create: `.dockerignore`
- Create: `docs/deployment.md`

**Interfaces:**
- Consumes: renamed module paths from Task 1 (the Dockerfile copies both modules and relies on `server/go.mod`'s `replace` directive).
- Produces: a container serving PocketBase on 8090 with `/api/health` as its health check.

**Why `CGO_ENABLED=0` works:** PocketBase uses `modernc.org/sqlite`, a pure-Go SQLite. The server needs no C toolchain — only `splitcore/ffi` (the client library) does, and that is not part of this image.

- [ ] **Step 1: Write the Dockerfile**

Create `server/Dockerfile`:

```dockerfile
# Build from the repository root:  docker build -f server/Dockerfile .
# The build context must be the repo root because server/go.mod replaces
# the splitcore module with ../splitcore.
FROM golang:1.26-alpine AS build

WORKDIR /src

# Copy manifests first so dependency download caches independently of
# source edits.
COPY go.work go.work.sum ./
COPY splitcore/go.mod ./splitcore/
COPY server/go.mod server/go.sum ./server/
RUN go mod download

COPY splitcore ./splitcore
COPY server ./server

# PocketBase uses modernc.org/sqlite (pure Go), so no cgo and no libc
# dependency — the result is a static binary that runs on scratch/alpine.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/splitcore-server ./server

FROM alpine:3.20

# ca-certificates: outbound TLS (SMTP for password reset, S3 backups).
# wget: the compose health check.
RUN apk add --no-cache ca-certificates wget tzdata \
    && adduser -D -u 10001 splitcore

WORKDIR /app
COPY --from=build /out/splitcore-server /app/splitcore-server

# pb_data holds the SQLite database and every uploaded receipt. It MUST be
# a volume — losing it loses all user data.
RUN mkdir -p /app/pb_data && chown -R splitcore:splitcore /app
USER splitcore

EXPOSE 8090
VOLUME ["/app/pb_data"]

# Automigrate is off for a compiled binary (see server/main.go), so apply
# migrations explicitly before serving.
ENTRYPOINT ["/bin/sh", "-c", "/app/splitcore-server migrate up && exec /app/splitcore-server serve --http=0.0.0.0:8090 \"$@\"", "--"]
```

- [ ] **Step 2: Write .dockerignore**

Create `.dockerignore`:

```
.git
.github
app
docs
splitcore_sdk
splitcore/build/out
server/pb_data
server/server
**/.dart_tool
**/build
```

`server/pb_data` and `server/server` are especially important: a local
data directory or a 33 MB stale binary copied into the build context both
slow the build and risk baking development data into an image.

- [ ] **Step 3: Write docker-compose.yml**

Create `docker-compose.yml`:

```yaml
services:
  server:
    build:
      context: .
      dockerfile: server/Dockerfile
    image: splitcore-server:latest
    restart: unless-stopped
    ports:
      # Bound to loopback: put a TLS-terminating reverse proxy in front.
      # Change to "8090:8090" only for a trusted LAN, never the internet.
      - "127.0.0.1:8090:8090"
    volumes:
      - pb_data:/app/pb_data
    healthcheck:
      # PocketBase's built-in endpoint — 200 as soon as it is serving.
      test: ["CMD", "wget", "--spider", "-q", "http://127.0.0.1:8090/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s

volumes:
  pb_data:
```

- [ ] **Step 4: Build the image and verify the container answers its health check**

Run:
```bash
cd /home/abdul/Projects/slice_pay
docker compose build
docker compose up -d
sleep 15
curl -fsS http://127.0.0.1:8090/api/health
docker compose ps
```
Expected: the curl prints `{"code":200,"message":"API is healthy.","data":{}}` (PocketBase's health payload), and `docker compose ps` shows the service as `healthy`.

- [ ] **Step 5: Verify data survives a restart, then tear down**

Run:
```bash
cd /home/abdul/Projects/slice_pay
docker compose restart server && sleep 15
curl -fsS http://127.0.0.1:8090/api/health
docker compose down          # volume persists; `down -v` would delete it
```
Expected: healthy again after restart.

- [ ] **Step 6: Write the deployment guide**

Create `docs/deployment.md`:

```markdown
# Deploying the Splitcore server

## Run it

```bash
docker compose up -d
curl http://127.0.0.1:8090/api/health   # {"code":200,...}
```

The compose file binds **127.0.0.1 only**. Splitcore must not be exposed
directly: PocketBase speaks plain HTTP, and an auth token sent over HTTP
is a stolen auth token.

## First run

1. `docker compose exec server /app/splitcore-server superuser upsert you@example.com 'a-strong-password'`
2. Open the admin UI through your proxy at `/_/` and confirm the six
   collections exist (`groups`, `group_members`, `expenses`,
   `split_entries`, `settlements`, `balances`).

Migrations run automatically at container start (the entrypoint calls
`migrate up` before `serve`) — automigrate is off for compiled binaries,
which is why the explicit step exists.

## HTTPS

Terminate TLS at a reverse proxy. Caddy needs the least configuration
because it obtains and renews certificates itself:

```caddyfile
splitcore.example.com {
    reverse_proxy 127.0.0.1:8090

    # The admin UI should not be world-reachable.
    @admin path /_/*
    handle @admin {
        @notallowed not remote_ip 203.0.113.0/24
        respond @notallowed 403
        reverse_proxy 127.0.0.1:8090
    }
}
```

nginx equivalent: `proxy_pass http://127.0.0.1:8090;` plus
`proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;` and
`client_max_body_size 10m` (receipt uploads).

Then point clients at it:

```bash
flutter build apk --dart-define=POCKETBASE_URL=https://splitcore.example.com
```

## Backups

Everything that matters is in the `pb_data` volume: the SQLite database
**and** every uploaded receipt image. Backing up the `.db` file alone
loses the receipts.

**Built-in (preferred).** PocketBase's admin UI → Settings → Backups
creates a consistent archive of the whole data directory while the server
runs, and can upload to S3. Enable a daily schedule there.

**From the host**, snapshot the volume:

```bash
docker run --rm \
  -v splitcore_pb_data:/data:ro \
  -v "$PWD/backups:/backup" \
  alpine tar czf "/backup/pb_data-$(date +%F-%H%M).tar.gz" -C /data .
```

Run it from cron. Keep at least 7 daily and 4 weekly copies, and store one
copy off the host — a backup on the same disk as the database is not a
backup.

## Restore

```bash
docker compose down
docker run --rm \
  -v splitcore_pb_data:/data \
  -v "$PWD/backups:/backup" \
  alpine sh -c "rm -rf /data/* && tar xzf /backup/pb_data-2026-08-04-0300.tar.gz -C /data"
docker compose up -d
curl -fsS http://127.0.0.1:8090/api/health
```

**Rehearse a restore before you need one.** Restore into a throwaway
volume, start the server against it, and confirm you can sign in and see a
group. An unrehearsed backup is a guess.

## Monitoring

- **Liveness:** `GET /api/health` — already the container's health check.
- **Logs:** `docker compose logs -f server`. PocketBase logs every request;
  ship them to your aggregator via the Docker logging driver.
- **Disk:** receipts grow `pb_data` without bound. Alert at 80% full.
- **Backups:** alert when the newest archive is older than 48 hours. A
  backup job that silently stopped is the most common way data is lost.
```

- [ ] **Step 7: Verify the README's deployment link now resolves**

Run:
```bash
cd /home/abdul/Projects/slice_pay
grep -o '](\([^)#][^)]*\))' README.md | sed 's/](//;s/)$//' | while read -r f; do
  [ -e "$f" ] || echo "MISSING: $f"
done
```
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add server/Dockerfile docker-compose.yml .dockerignore docs/deployment.md
git commit -m "build: containerize the server with health check and backup docs

CGO_ENABLED=0 works because PocketBase uses modernc.org/sqlite (pure Go).
Compose binds loopback only — TLS termination is the reverse proxy's job,
documented in docs/deployment.md along with backup and restore."
```

---

## Milestone verification

After Task 9, verify the First Milestone end to end from a **clean clone**,
not the working tree:

```bash
cd /tmp && rm -rf splitcore-verify
git clone git@github.com:abdulroufsidhu/splitcore.git splitcore-verify
cd splitcore-verify
make check      # must pass with no manual steps
make server     # terminal 1
make app        # terminal 2
```

Then, in the running app: sign up two users, create a group, add an
expense split between them, settle up, and confirm both balances read
zero. If any step needed a command not in the README, the README is
wrong — fix it before calling this plan done.

---

## What this plan does NOT cover

Deliberately deferred to the follow-on plans:

- **SDK and server correctness** — parameterized PocketBase filters,
  pagination, atomic expense creation, expense editing, refresh
  deduplication, password reset, email verification, account deletion:
  see `2026-08-04-splitcore-sdk-correctness.md`.
- **App usability and production polish** — state management, error and
  retry states, offline reads, widget test coverage, accessibility,
  localization, search, export: see `2026-08-04-splitcore-app-usability.md`.
- **Load testing and large-scale recompute performance.** `bumpAndRecompute`
  rewrites every balance row for a group on every single write. That is
  correct and fine for groups of realistic size; it is O(expenses × splits)
  per write and will need attention only if a group ever holds tens of
  thousands of expenses. Measure before optimizing.
```
