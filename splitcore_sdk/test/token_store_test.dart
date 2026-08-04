import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import 'support/lib_path.dart';
import 'support/pb_server.dart';

/// What a Flutter app supplies, backed by shared_preferences.
class _FakeStore implements TokenStore {
  _FakeStore([this._value]);

  String? _value;
  int writes = 0;

  @override
  String? read() => _value;

  @override
  Future<void> write(String data) async {
    _value = data;
    writes++;
  }
}

void main() {
  test('TokenStore is reachable from the public API without importing pocketbase', () {
    final store = _FakeStore('seed');
    expect(store, isA<TokenStore>());
    expect(store.read(), 'seed');
  });

  test('the SDK accepts a TokenStore and starts with no session', () {
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: 'http://127.0.0.1:1',
      libraryPath: resolveLinuxLibPath(),
      tokenStore: _FakeStore(),
    );

    expect(sdk.auth.currentUser, isNull);
  });

  test('a session written by one SDK is restored by the next, as on relaunch', () async {
    // Round-tripped through the real client rather than a hand-forged blob:
    // the serialized shape is PocketBase's business, and the property worth
    // pinning is that signing in once survives a restart.
    final server = await PbTestServer.start();
    addTearDown(server.stop);

    final store = _FakeStore();
    final email = 'persist-${DateTime.now().microsecondsSinceEpoch}@example.com';

    final first = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      tokenStore: store,
    );
    await first.auth.signUp(email: email, password: 'password123');

    expect(store.writes, greaterThan(0), reason: 'signing in never reached the store');

    // A fresh process: same stored blob, brand new SDK.
    final relaunched = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      tokenStore: _FakeStore(store.read()),
    );

    expect(relaunched.auth.currentUser?.email, email);
  });
}
