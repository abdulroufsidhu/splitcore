// Deleting a group and handing one over, end to end against the real
// server.
//
// Deletion is destructive for everybody in the group, so the interesting
// parts are what stops it (an outstanding balance, unsent writes) and what
// it takes with it locally — the group row alone is not enough, its
// expenses and members have to go too or the next screen reads stale rows.
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

  SplitcoreSdk newSdk({ConnectivityMonitor? connectivity}) => SplitcoreSdk.initialize(
    pocketbaseUrl: server.baseUrl,
    libraryPath: resolveLinuxLibPath(),
    connectivity: connectivity,
  );

  /// An owner with a group, plus a second account already added to it.
  Future<(SplitcoreSdk, Group, GroupMember, GroupMember, String)> setUpGroup(
    String tag, {
    ConnectivityMonitor? connectivity,
  }) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;

    final friendSdk = newSdk();
    final friendEmail = '$tag-friend-$stamp@example.com';
    await friendSdk.auth.signUp(email: friendEmail, password: 'password123', name: 'Friend');
    await friendSdk.close();

    final sdk = newSdk(connectivity: connectivity);
    addTearDown(sdk.close);
    final me = await sdk.auth.signUp(
      email: '$tag-owner-$stamp@example.com',
      password: 'password123',
      name: 'Owner',
    );
    final group = await sdk.groups.createGroup(name: 'Delete $tag', currency: 'USD');
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);
    await sdk.sync.now();

    final members = await sdk.groups.listMembers(group.id);
    final owner = members.firstWhere((m) => m.userId == me.id);
    final friend = members.firstWhere((m) => m.userId != me.id);
    return (sdk, group, owner, friend, friendEmail);
  }

  test('deleting takes the group and everything under it out of the mirror', () async {
    final (sdk, group, owner, friend, _) = await setUpGroup('clean');

    // Settled history: the group has real content, and nobody owes anything.
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
    expect(await sdk.expenses.listExpenses(group.id), hasLength(1));

    await sdk.groups.deleteGroup(group.id);

    expect(await sdk.groups.listMyGroups(), isEmpty);
    expect(await sdk.groups.getGroup(group.id), isNull);
    // The children go with it, through the local schema's ON DELETE CASCADE.
    // Left behind, they would surface the moment a new group reused nothing
    // but the same screen.
    expect(await sdk.expenses.listExpenses(group.id), isEmpty);
    expect(await sdk.groups.listAllMembers(group.id), isEmpty);
    expect(await sdk.settlements.listSettlements(group.id), isEmpty);
  });

  test('a group where somebody still owes money cannot be deleted', () async {
    final (sdk, group, owner, friend, _) = await setUpGroup('owing');

    // No settlement: the friend is down 5.00.
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Lunch',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, friend.id]),
    );
    await sdk.sync.now();

    await expectLater(sdk.groups.deleteGroup(group.id), throwsA(isA<ClientException>()));
    expect(await sdk.groups.getGroup(group.id), isNotNull);
    expect(await sdk.expenses.listExpenses(group.id), hasLength(1));
  });

  test('unsent writes block the delete instead of being destroyed by it', () async {
    final connectivity = FakeConnectivityMonitor();
    final (sdk, group, owner, _, _) = await setUpGroup('unsent', connectivity: connectivity);

    connectivity.goOffline();
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Queued',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.equal(totalCents: 800, memberIds: [owner.id]),
    );

    await expectLater(
      sdk.groups.deleteGroup(group.id),
      throwsA(isA<UnsyncedWritesException>()),
      reason: 'deleting now would take the queued expense down with the group',
    );
    expect(await sdk.groups.getGroup(group.id), isNotNull);
    expect((await sdk.sync.queued()), hasLength(1));

    // Once it lands, the group is square again and the delete goes through.
    connectivity.goOnline();
    await sdk.sync.now();
    await sdk.groups.deleteGroup(group.id);
    expect(await sdk.groups.listMyGroups(), isEmpty);
  });

  test('handing the group over moves ownership and frees the old owner to leave', () async {
    final (sdk, group, owner, friend, _) = await setUpGroup('handover');

    expect(
      await sdk.groups.transferOwnership(groupId: group.id, memberId: friend.id),
      'transferred',
    );

    final after = await sdk.groups.getGroup(group.id);
    expect(after!.ownerId, friend.userId);

    final members = await sdk.groups.listMembers(group.id);
    expect(members.firstWhere((m) => m.id == friend.id).role, 'owner');
    expect(members.firstWhere((m) => m.id == owner.id).role, 'member');

    // The point of transferring: remove-member refuses the owner outright,
    // so before this the old owner had no way out of their own group.
    expect(await sdk.groups.removeMember(owner.id), 'removed');
  });

  test('a plain member cannot take the group', () async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final friendEmail = 'grab-friend-$stamp@example.com';

    final friendSdk = newSdk();
    addTearDown(friendSdk.close);
    await friendSdk.auth.signUp(email: friendEmail, password: 'password123', name: 'Friend');

    final sdk = newSdk();
    addTearDown(sdk.close);
    await sdk.auth.signUp(
      email: 'grab-owner-$stamp@example.com',
      password: 'password123',
      name: 'Owner',
    );
    final group = await sdk.groups.createGroup(name: 'Grab', currency: 'USD');
    await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);
    await sdk.sync.now();

    await friendSdk.sync.now();
    final asFriend = (await friendSdk.groups.listMembers(
      group.id,
    )).firstWhere((m) => m.role == 'member');

    await expectLater(
      friendSdk.groups.transferOwnership(groupId: group.id, memberId: asFriend.id),
      throwsA(isA<ClientException>()),
    );
    expect((await sdk.groups.getGroup(group.id))!.ownerId, isNot(asFriend.userId));
  });
}
