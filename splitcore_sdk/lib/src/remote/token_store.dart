// How the SDK persists a session across app restarts, without the caller
// needing a PocketBase type. The app supplies the storage (shared_
// preferences on mobile/desktop, anything else elsewhere); the SDK adapts
// it to PocketBase's AuthStore internally so `package:pocketbase` stops at
// this package's boundary.
import 'dart:io';

import 'package:pocketbase/pocketbase.dart';

abstract class TokenStore {
  /// The previously written blob, or null on a first launch. Synchronous:
  /// the SDK needs it during construction, so read it before initializing
  /// (e.g. `await SharedPreferences.getInstance()` first).
  String? read();

  /// Persists [data]. Called by the SDK whenever the session changes —
  /// sign-in, refresh, sign-out.
  Future<void> write(String data);
}

/// A [TokenStore] backed by a plain file, so a session survives a restart
/// with no app wiring at all. The Flutter app supplies its own
/// shared_preferences-backed store; this exists so the SDK is not useless
/// out of the box on desktop and in scripts.
///
/// The file holds a bearer token. It is written with owner-only permissions
/// where the platform supports it; on platforms that do not, the containing
/// directory is the security boundary — put it somewhere private.
class FileTokenStore implements TokenStore {
  FileTokenStore.at(String path) : _file = File(path);

  final File _file;

  @override
  String? read() {
    try {
      return _file.existsSync() ? _file.readAsStringSync() : null;
    } catch (_) {
      // A corrupt or unreadable token file means "not signed in", never a
      // crash on launch — the user can sign in again, but they cannot get
      // past a startup exception.
      return null;
    }
  }

  @override
  Future<void> write(String data) async {
    await _file.parent.create(recursive: true);
    await _file.writeAsString(data, flush: true);
    if (!Platform.isWindows) {
      // Best effort: the token is a credential, and a world-readable file in
      // a shared temp or home directory hands the session to any local
      // process. A failure here is not worth losing the write over.
      try {
        await Process.run('chmod', ['600', _file.path]);
      } catch (_) {}
    }
  }
}

/// Adapts a [TokenStore] to PocketBase's AuthStore. Internal.
AuthStore asAuthStore(TokenStore store) => AsyncAuthStore(save: store.write, initial: store.read());
