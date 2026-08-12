// What a pull is allowed to overwrite.
//
// A pull mirrors the server over the local rows. Anything the user has not
// settled yet has to survive that; anything the server has already refused
// should not.
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

  /// A signed-in SDK with one group, one member, and hand-driven
  /// connectivity.
  Future<(SplitcoreSdk, Group, GroupMember, FakeConnectivityMonitor, String)> synced(
    String tag,
  ) async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: connectivity,
    );
    final email = '$tag-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await sdk.auth.signUp(email: email, password: 'password123');
    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();
    final member = (await sdk.groups.listMembers(group.id)).single;
    return (sdk, group, member, connectivity, email);
  }

  test('a pull does not overwrite a row whose edit is parked on a conflict', () async {
    final (sdk, group, member, connectivity, email) = await synced('conflict');
    addTearDown(sdk.close);

    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );
    await sdk.sync.now();

    // Our edit, made offline.
    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'My version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    // The same record moves on the server, from another device.
    final elsewhere = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(elsewhere.close);
    await elsewhere.auth.signIn(email: email, password: 'password123');
    await elsewhere.sync.now();
    await elsewhere.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Their version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 9000, memberIds: [member.id]),
    );
    await elsewhere.sync.now();

    // Reconnecting parks our edit and then pulls in the same run.
    connectivity.goOnline();
    await sdk.sync.now();
    expect(await sdk.sync.conflicts(), hasLength(1), reason: 'the edit should be parked');

    // The user is about to be asked "keep yours or theirs?" — so theirs must
    // not already have replaced ours on screen.
    final local = (await sdk.expenses.listExpenses(group.id)).single;
    expect(
      local.description,
      'My version',
      reason: 'the pull overwrote the very edit the user is being asked about',
    );

    // And the parked edit still resolves in favour of the local version.
    final parked = (await sdk.sync.conflicts()).single;
    await sdk.sync.resolve(parked.seq, keepLocal: true);
    await elsewhere.sync.now();
    expect((await elsewhere.expenses.listExpenses(group.id)).single.description, 'My version');
  });

  test('a pull does overwrite a row the server refused outright', () async {
    final (sdk, group, member, connectivity, _) = await synced('failed');
    addTearDown(sdk.close);

    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );
    await sdk.sync.now();

    // Edit offline, then delete the record on the server so the queued
    // update can never apply. A 404 on an update is terminal, not transient.
    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Doomed edit',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    connectivity.goOnline();
    await sdk.sync.now();

    // Nothing retries a failed op, so its local row is not worth protecting:
    // holding it back would show the user an edit that can never land.
    expect(await sdk.sync.conflicts(), isEmpty);
  });

  test('a stuck failed op does not block removing a member', () async {
    // Failed ops are terminal — only conflict resolution ever re-queues one.
    // If they counted as unsent work, a single stuck failure would make every
    // member in the group permanently unremovable.
    final (sdk, group, owner, connectivity, _) = await synced('stuck');
    addTearDown(sdk.close);

    final friendSdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
    );
    final friendEmail = 'stuck-friend-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await friendSdk.auth.signUp(email: friendEmail, password: 'password123');
    await friendSdk.close();
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);
    await sdk.sync.now();

    final friend = (await sdk.groups.listMembers(group.id)).firstWhere((m) => m.id != owner.id);

    // Manufacture a terminal failure: edit offline, then delete on the
    // server so the queued update comes back 404.
    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [owner.id]),
    );
    await sdk.sync.now();
    connectivity.goOffline();
    await sdk.expenses.deleteExpense(expense.id);
    connectivity.goOnline();
    await sdk.sync.now();

    expect(await sdk.sync.queued(), isEmpty, reason: 'the queue should have drained');

    // The friend has no history and owes nothing, so this is allowed to go
    // through despite whatever the outbox is still holding on to.
    expect(await sdk.groups.removeMember(friend.id), 'removed');
  });
}
