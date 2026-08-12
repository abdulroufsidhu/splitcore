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

Without an override the app talks to the deployed server,
`https://splitcore.orgolink.ch` — see `lib/config.dart`. `make app` passes
`--dart-define=POCKETBASE_URL=http://127.0.0.1:8090` so the dev loop stays
local; override it for an emulator or device:

```bash
make app POCKETBASE_URL=http://10.0.2.2:8090   # Android emulator's host alias
flutter run --dart-define=POCKETBASE_URL=http://<LAN IP>:8090  # physical device
```

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
