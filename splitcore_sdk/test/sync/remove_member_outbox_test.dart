// Removing a member while writes are still queued.
//
// The server judges a removal on what it can see. An expense sitting in the
// outbox is invisible to it, so a member who is about to be part of that
// expense looks like a member with no history and no balance.
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test('an expense queued offline survives removing the member it splits with', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final connectivity = FakeConnectivityMonitor();

    final friendSdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
    );
    final friendEmail = 'outbox-friend-$stamp@example.com';
    await friendSdk.auth.signUp(email: friendEmail, password: 'password123', name: 'Friend');
    await friendSdk.close();

    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: connectivity,
    );
    addTearDown(sdk.close);
    final me = await sdk.auth.signUp(
      email: 'outbox-owner-$stamp@example.com',
      password: 'password123',
      name: 'Owner',
    );
    final group = await sdk.groups.createGroup(name: 'Outbox', currency: 'USD');
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);
    await sdk.sync.now();

    final members = await sdk.groups.listMembers(group.id);
    final owner = members.firstWhere((m) => m.userId == me.id);
    final friend = members.firstWhere((m) => m.userId != me.id);

    // Offline: the expense lands in the outbox and the server never sees it.
    connectivity.goOffline();
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Queued lunch',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, friend.id]),
    );
    expect(await sdk.sync.queued(), isNotEmpty, reason: 'the expense should be waiting to send');

    // Refused rather than attempted: the server cannot judge this removal
    // while it has never seen the queued expense.
    await expectLater(sdk.groups.removeMember(friend.id), throwsA(isA<UnsyncedWritesException>()));

    connectivity.goOnline();
    await sdk.sync.now();

    // Now that the server can see the expense, the member turns out to owe
    // money — so the removal is refused on the balance instead. Before the
    // fix this same call deleted them outright, because the expense the
    // debt comes from was still sitting in the outbox.
    await expectLater(sdk.groups.removeMember(friend.id), throwsA(isA<ClientException>()));

    // Which is the whole point: the expense is still here.
    final expenses = await sdk.expenses.listExpenses(group.id);
    expect(
      expenses.map((e) => e.description),
      contains('Queued lunch'),
      reason: 'the queued expense must not be destroyed by the removal',
    );
    expect(
      await sdk.sync.failures(),
      isEmpty,
      reason: 'the queued expense must not be rejected as unsendable',
    );
  });
}
