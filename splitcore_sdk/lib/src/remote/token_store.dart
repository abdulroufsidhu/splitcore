// How the SDK persists a session across app restarts, without the caller
// needing a PocketBase type. The app supplies the storage (shared_
// preferences on mobile/desktop, anything else elsewhere); the SDK adapts
// it to PocketBase's AuthStore internally so `package:pocketbase` stops at
// this package's boundary.
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

/// Adapts a [TokenStore] to PocketBase's AuthStore. Internal.
AuthStore asAuthStore(TokenStore store) => AsyncAuthStore(save: store.write, initial: store.read());
