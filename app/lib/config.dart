// Where the app looks for the PocketBase server. Builds hit the deployed
// server by default; local work passes
// --dart-define=POCKETBASE_URL=http://... to point somewhere else.

/// The compile-time override. Empty when no --dart-define was passed.
const _override = String.fromEnvironment('POCKETBASE_URL');

/// The deployed server every build talks to unless overridden.
const _deployedUrl = 'https://splitcore.orgolink.ch';

/// Picks the server URL: [override] wins outright when non-empty, otherwise
/// the deployed server.
///
/// Local development points at a `make server` instance explicitly —
/// `http://127.0.0.1:8090` on desktop and the iOS simulator,
/// `http://10.0.2.2:8090` from the Android emulator (a plain `127.0.0.1`
/// inside the emulator is the emulator itself), a LAN address from a
/// physical device.
String resolveBackendUrl({required String override}) =>
    override.isNotEmpty ? override : _deployedUrl;

/// [resolveBackendUrl] applied to the real dart-defines.
String defaultBackendUrl() => resolveBackendUrl(override: _override);
