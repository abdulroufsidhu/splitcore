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
