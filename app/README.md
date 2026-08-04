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
