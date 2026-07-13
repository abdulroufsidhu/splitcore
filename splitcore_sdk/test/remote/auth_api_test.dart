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

  test('currentUser is null before signing in', () {
    expect(auth.currentUser, isNull);
  });

  test('signUp creates a user and signIn authenticates it', () async {
    await auth.signUp(email: 'alice@example.com', password: 'password123');

    final user = await auth.signIn(email: 'alice@example.com', password: 'password123');

    expect(user.email, 'alice@example.com');
    expect(auth.currentUser?.email, 'alice@example.com');
  });

  test('signIn with wrong password throws', () async {
    await auth.signUp(email: 'bob@example.com', password: 'password123');

    expect(
      () => auth.signIn(email: 'bob@example.com', password: 'wrongpassword'),
      throwsA(anything),
    );
  });

  test('signOut clears the current user', () async {
    await auth.signUp(email: 'carol@example.com', password: 'password123');
    await auth.signIn(email: 'carol@example.com', password: 'password123');
    expect(auth.currentUser, isNotNull);

    auth.signOut();

    expect(auth.currentUser, isNull);
  });
}
