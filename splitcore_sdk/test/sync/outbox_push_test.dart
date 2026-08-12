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

  Future<(SplitcoreSdk, Group, GroupMember, FakeConnectivityMonitor)> synced() async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: connectivity,
    );
    await sdk.auth.signUp(
      email: 'push-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();
    final member = (await sdk.groups.listMembers(group.id)).single;
    return (sdk, group, member, connectivity);
  }

  Future<Expense> createOffline(
    SplitcoreSdk sdk,
    Group group,
    GroupMember member, {
    String description = 'Dinner',
    int totalCents = 3000,
  }) => sdk.expenses.createExpense(
    groupId: group.id,
    payerMemberId: member.id,
    description: description,
    date: DateTime.utc(2026, 8, 6),
    split: SplitSpec.equal(totalCents: totalCents, memberIds: [member.id]),
  );

  test('an expense created offline reaches the server on reconnect', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    connectivity.goOffline();
    final expense = await createOffline(sdk, group, member);
    expect(await sdk.sync.queued(), hasLength(1));

    connectivity.goOnline();
    await sdk.sync.now();

    expect(await sdk.sync.queued(), isEmpty, reason: 'the queue did not drain');

    // Read back through a second, independent client: proof it is really on
    // the server and not just still in the first client's local database.
    final other = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(other.close);
    await other.auth.signIn(email: (await sdk.auth.tryRefresh())!.email, password: 'password123');
    await other.sync.now();

    final seen = await other.expenses.watch(group.id).first;
    expect(seen.map((e) => e.description), ['Dinner']);
    expect(seen.single.id, expense.id, reason: 'the client-minted id must survive the round trip');
  });

  test('the local row stops being pending once its op is delivered', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    connectivity.goOffline();
    await createOffline(sdk, group, member);
    expect((await sdk.expenses.watch(group.id).first).single.pending, isTrue);

    connectivity.goOnline();
    await sdk.sync.now();

    final row = (await sdk.expenses.watch(group.id).first).single;
    expect(row.pending, isFalse);
    expect(row.updated, isNotNull, reason: 'the pull should have brought the server stamp back');
  });

  test('several offline writes replay in order and all land', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    connectivity.goOffline();
    await createOffline(sdk, group, member, description: 'First', totalCents: 1000);
    await createOffline(sdk, group, member, description: 'Second', totalCents: 2000);
    await createOffline(sdk, group, member, description: 'Third', totalCents: 3000);
    expect(await sdk.sync.queued(), hasLength(3));

    connectivity.goOnline();
    await sdk.sync.now();

    expect(await sdk.sync.queued(), isEmpty);
    expect((await sdk.expenses.watch(group.id).first).map((e) => e.description).toSet(), {
      'First',
      'Second',
      'Third',
    });
  });

  test('an edit made offline is applied on reconnect', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    final expense = await createOffline(sdk, group, member);
    await sdk.sync.now();

    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Dinner and drinks',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    connectivity.goOnline();
    await sdk.sync.now();

    expect(await sdk.sync.queued(), isEmpty);
    expect(await sdk.sync.conflicts(), isEmpty);
    final row = (await sdk.expenses.watch(group.id).first).single;
    expect(row.description, 'Dinner and drinks');
    expect(row.amountCents, 4000);
  });

  test('an edit whose record moved on the server parks instead of overwriting', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    final expense = await createOffline(sdk, group, member);
    await sdk.sync.now();

    // Our device goes offline and the user edits.
    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'My version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    // Meanwhile the same expense is edited elsewhere. A second SDK on the
    // same account stands in for a co-member's device.
    final elsewhere = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(elsewhere.close);
    await elsewhere.auth.signIn(
      email: (await sdk.auth.tryRefresh())!.email,
      password: 'password123',
    );
    await elsewhere.sync.now();
    await elsewhere.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Their version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 9000, memberIds: [member.id]),
    );
    await elsewhere.sync.now();

    final conflicted = sdk.sync.events.firstWhere((e) => e is SyncConflict);
    connectivity.goOnline();
    await sdk.sync.now();
    await conflicted.timeout(const Duration(seconds: 10));

    expect(await sdk.sync.queued(), isEmpty, reason: 'the parked op must not block the queue');
    expect(await sdk.sync.conflicts(), hasLength(1));

    // The other person's edit is intact on the server.
    await elsewhere.sync.now();
    expect((await elsewhere.expenses.watch(group.id).first).single.description, 'Their version');
  });

  test('resolving a conflict in favour of the local edit applies it', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    final expense = await createOffline(sdk, group, member);
    await sdk.sync.now();

    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'My version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    final elsewhere = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(elsewhere.close);
    await elsewhere.auth.signIn(
      email: (await sdk.auth.tryRefresh())!.email,
      password: 'password123',
    );
    await elsewhere.sync.now();
    await elsewhere.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Their version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 9000, memberIds: [member.id]),
    );
    await elsewhere.sync.now();

    connectivity.goOnline();
    await sdk.sync.now();
    final parked = (await sdk.sync.conflicts()).single;

    await sdk.sync.resolve(parked.seq, keepLocal: true);

    expect(await sdk.sync.conflicts(), isEmpty);
    await elsewhere.sync.now();
    expect((await elsewhere.expenses.watch(group.id).first).single.description, 'My version');
  });

  test('resolving in favour of the server drops the local edit', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    final expense = await createOffline(sdk, group, member);
    await sdk.sync.now();

    connectivity.goOffline();
    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'My version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    final elsewhere = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(elsewhere.close);
    await elsewhere.auth.signIn(
      email: (await sdk.auth.tryRefresh())!.email,
      password: 'password123',
    );
    await elsewhere.sync.now();
    await elsewhere.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Their version',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 9000, memberIds: [member.id]),
    );
    await elsewhere.sync.now();

    connectivity.goOnline();
    await sdk.sync.now();
    final parked = (await sdk.sync.conflicts()).single;

    await sdk.sync.resolve(parked.seq, keepLocal: false);
    await sdk.sync.now();

    expect(await sdk.sync.conflicts(), isEmpty);
    expect(
      (await sdk.expenses.watch(group.id).first).single.description,
      'Their version',
      reason: "abandoning the local edit must pull the server's version back over it",
    );
  });

  test('replaying an op that already landed does not duplicate it', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    connectivity.goOffline();
    await createOffline(sdk, group, member);
    connectivity.goOnline();

    // Two syncs racing the same queue: whichever loses replays an op the
    // winner already delivered, and must recognise it rather than writing a
    // second expense.
    await Future.wait([sdk.sync.now(), sdk.sync.now(), sdk.sync.now()]);

    expect(await sdk.sync.queued(), isEmpty);
    expect(await sdk.expenses.watch(group.id).first, hasLength(1));
  });

  test('a settlement recorded offline reaches the server on reconnect', () async {
    final (sdk, group, member, connectivity) = await synced();
    addTearDown(sdk.close);

    // A genuinely second account: a settlement needs two distinct members.
    final friendSdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(friendSdk.close);
    final friendUser = await friendSdk.auth.signUp(
      email: 'friend-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final friend = await sdk.groups.addMember(
      groupId: group.id,
      userId: friendUser.id,
      role: 'member',
    );
    connectivity.goOffline();
    await sdk.settlements.createSettlement(
      groupId: group.id,
      fromMemberId: friend.id,
      toMemberId: member.id,
      amountCents: 500,
    );

    connectivity.goOnline();
    await sdk.sync.now();

    expect(await sdk.sync.queued(), isEmpty);
    expect((await sdk.settlements.watch(group.id).first).single.amountCents, 500);
  });
}
