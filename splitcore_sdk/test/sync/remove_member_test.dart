// Removing a member, end to end against the real server: the two outcomes
// (deleted vs kept-and-marked), the balance gate, and the guarantee that a
// removed member stops showing up as part of the group.
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

  SplitcoreSdk newSdk() =>
      SplitcoreSdk.initialize(pocketbaseUrl: server.baseUrl, libraryPath: resolveLinuxLibPath());

  /// An owner with a group, plus a second account already added to it.
  Future<(SplitcoreSdk, Group, GroupMember, GroupMember, String)> setUpGroup(String tag) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;

    final friendSdk = newSdk();
    final friendEmail = '$tag-friend-$stamp@example.com';
    await friendSdk.auth.signUp(email: friendEmail, password: 'password123', name: 'Friend');
    await friendSdk.close();

    final sdk = newSdk();
    addTearDown(sdk.close);
    final me = await sdk.auth.signUp(
      email: '$tag-owner-$stamp@example.com',
      password: 'password123',
      name: 'Owner',
    );
    final group = await sdk.groups.createGroup(name: 'Removal $tag', currency: 'USD');
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);

    final members = await sdk.groups.listMembers(group.id);
    final owner = members.firstWhere((m) => m.userId == me.id);
    final friend = members.firstWhere((m) => m.userId != me.id);
    return (sdk, group, owner, friend, friendEmail);
  }

  test('a member with no ledger history is deleted outright', () async {
    final (sdk, group, _, friend, _) = await setUpGroup('clean');

    expect(await sdk.groups.removeMember(friend.id), 'removed');

    expect((await sdk.groups.listMembers(group.id)).map((m) => m.id), isNot(contains(friend.id)));
    // Nothing referenced them, so nothing was kept behind either.
    expect(
      (await sdk.groups.listAllMembers(group.id)).map((m) => m.id),
      isNot(contains(friend.id)),
    );
  });

  test('a member with settled history is kept but drops out of the group', () async {
    final (sdk, group, owner, friend, _) = await setUpGroup('history');

    // Owner pays 10.00 split evenly, then the friend settles their 5.00, so
    // the history exists but nobody owes anything.
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Lunch',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, friend.id]),
    );
    await sdk.settlements.createSettlement(
      groupId: group.id,
      fromMemberId: friend.id,
      toMemberId: owner.id,
      amountCents: 500,
    );
    await sdk.sync.now();

    expect(await sdk.groups.removeMember(friend.id), 'deactivated');

    // Gone from the group...
    final active = await sdk.groups.listMembers(group.id);
    expect(active.map((m) => m.id), isNot(contains(friend.id)));
    // ...but still nameable, because their expense is still in the ledger.
    final all = await sdk.groups.listAllMembers(group.id);
    expect(all.firstWhere((m) => m.id == friend.id).isActive, isFalse);
  });

  test('a member who still owes money cannot be removed', () async {
    final (sdk, group, owner, friend, _) = await setUpGroup('owing');

    // No settlement: the friend is still down 5.00.
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Lunch',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, friend.id]),
    );
    // Local-first: the expense sits in the outbox until a run pushes it, and
    // the server is the one deciding whether this removal is allowed.
    await sdk.sync.now();

    await expectLater(sdk.groups.removeMember(friend.id), throwsA(isA<ClientException>()));
    expect((await sdk.groups.listMembers(group.id)).map((m) => m.id), contains(friend.id));
  });

  test('re-inviting a removed member puts them back', () async {
    final (sdk, group, owner, friend, friendEmail) = await setUpGroup('readd');

    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Lunch',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, friend.id]),
    );
    await sdk.settlements.createSettlement(
      groupId: group.id,
      fromMemberId: friend.id,
      toMemberId: owner.id,
      amountCents: 500,
    );
    await sdk.sync.now();
    expect(await sdk.groups.removeMember(friend.id), 'deactivated');

    final all = await sdk.groups.listAllMembers(group.id);
    expect(all.any((m) => m.id == friend.id && !m.isActive), isTrue, reason: 'removed first');

    // Re-adding by email — what the Add member sheet does — reactivates the
    // existing row rather than creating a second one, which the unique
    // (group, user) index would reject anyway and which would orphan their
    // expenses.
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);

    expect((await sdk.groups.listMembers(group.id)).map((m) => m.id), contains(friend.id));
  });

  test('the group owner cannot be removed', () async {
    final (sdk, group, owner, _, _) = await setUpGroup('owner');

    await expectLater(sdk.groups.removeMember(owner.id), throwsA(isA<ClientException>()));
    expect((await sdk.groups.listMembers(group.id)).map((m) => m.id), contains(owner.id));
  });
}
