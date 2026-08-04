import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late AuthApi auth;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() {
    auth = AuthApi(PocketBase(server.baseUrl));
  });

  test('requesting a reset for a real address succeeds', () async {
    final email = 'reset-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await auth.signUp(email: email, password: 'password123');
    auth.signOut();

    // The test server has no SMTP configured, so nothing is delivered —
    // what matters is that the request is accepted and does not throw.
    await auth.requestPasswordReset(email);
  });

  test('requesting a reset for an unknown address does not reveal that it is unknown', () async {
    // Must not throw: a distinguishable error turns this into an account
    // enumeration oracle.
    await auth.requestPasswordReset('nobody-${DateTime.now().microsecondsSinceEpoch}@example.com');
  });

  test('confirming a reset with a bogus token fails loudly', () async {
    await expectLater(
      auth.confirmPasswordReset(token: 'not-a-real-token', password: 'newpassword123'),
      throwsA(anything),
    );
  });

  test('requesting verification for an unknown address is also silent', () async {
    await auth.requestEmailVerification(
      'ghost-${DateTime.now().microsecondsSinceEpoch}@example.com',
    );
  });

  test('confirming verification with a bogus token fails loudly', () async {
    await expectLater(auth.confirmEmailVerification('not-a-real-token'), throwsA(anything));
  });

  test('isEmailVerified is false for a fresh unverified signup', () async {
    await auth.signUp(
      email: 'unverified-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    expect(auth.isEmailVerified, isFalse);
  });

  test('isEmailVerified is false when nobody is signed in', () {
    expect(auth.isEmailVerified, isFalse);
  });
}
