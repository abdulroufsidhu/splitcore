import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

/// Counts the auth-refresh requests that actually reach the wire, so a test
/// can assert deduplication rather than guessing at a timing race.
class _CountingClient extends http.BaseClient {
  _CountingClient(this._inner);

  final http.Client _inner;
  int authRefreshRequests = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.path.endsWith('/auth-refresh')) authRefreshRequests++;
    return _inner.send(request);
  }
}

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test('concurrent refreshes share one request and keep the session', () async {
    final counter = _CountingClient(http.Client());
    final pb = PocketBase(server.baseUrl, httpClientFactory: () => counter);
    final auth = AuthApi(pb);
    final user = await auth.signUp(
      email: 'refresh-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    counter.authRefreshRequests = 0;

    // Startup refresh and a resume refresh landing at the same moment —
    // exactly what main.dart does on a cold launch.
    final results = await Future.wait([auth.tryRefresh(), auth.tryRefresh(), auth.tryRefresh()]);

    expect(
      counter.authRefreshRequests,
      1,
      reason:
          'three overlapping refreshes hit the server '
          '${counter.authRefreshRequests} times; each extra one is a chance for a '
          'failure to clear the session while another is still succeeding',
    );
    expect(
      results.every((u) => u?.id == user.id),
      isTrue,
      reason: 'a concurrent refresh returned null: $results',
    );
    expect(auth.currentUser, isNotNull, reason: 'the session was cleared by a racing refresh');
  });

  test('a refresh issued after an earlier one settles is a fresh request', () async {
    // Deduplication must not turn into caching: a later resume has to
    // actually renew the token, not replay the first result.
    final counter = _CountingClient(http.Client());
    final pb = PocketBase(server.baseUrl, httpClientFactory: () => counter);
    final auth = AuthApi(pb);
    await auth.signUp(
      email: 'sequential-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    counter.authRefreshRequests = 0;

    await auth.tryRefresh();
    await auth.tryRefresh();

    expect(counter.authRefreshRequests, 2);
  });

  test('a refresh after sign-out returns null without throwing', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    await auth.signUp(
      email: 'signedout-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    auth.signOut();

    expect(await auth.tryRefresh(), isNull);
  });

  test('a refresh against an unreachable server clears the session and returns null', () async {
    // Port 1 refuses instantly — the offline path without a real timeout wait.
    final pb = PocketBase('http://127.0.0.1:1');
    final auth = AuthApi(pb);

    // Seed a syntactically valid session so tryRefresh gets past its null check.
    final live = PocketBase(server.baseUrl);
    final liveAuth = AuthApi(live);
    await liveAuth.signUp(
      email: 'offline-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    pb.authStore.save(live.authStore.token, live.authStore.record);

    expect(await auth.tryRefresh(), isNull);
    expect(auth.currentUser, isNull);
  });
}
