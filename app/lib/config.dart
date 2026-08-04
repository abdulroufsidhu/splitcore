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
