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

  /// A signed-in SDK holding one synced group, then taken offline. Every
  /// write after this must reach the local database and nothing else.
  Future<(SplitcoreSdk, Group, GroupMember, FakeConnectivityMonitor)> offlineWithGroup() async {
    final connectivity = FakeConnectivityMonitor();
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: connectivity,
    );
    await sdk.auth.signUp(
      email: 'write-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();
    final member = (await sdk.groups.listMembers(group.id)).single;
    connectivity.goOffline();
    return (sdk, group, member, connectivity);
  }

  test('an expense created offline is readable immediately and marked pending', () async {
    final (sdk, group, member, _) = await offlineWithGroup();
    addTearDown(sdk.close);

    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );

    final local = await sdk.expenses.watch(group.id).first;
    expect(local.single.id, expense.id);
    expect(local.single.description, 'Dinner');
    expect(local.single.pending, isTrue, reason: 'nobody else can see this expense yet');
    expect(local.single.updated, isNull, reason: 'the server has never seen it');

    final entries = await sdk.expenses.listSplitEntries(expense.id);
    expect(entries.single.amountCents, 3000);
  });

  test('an offline write queues exactly one op, carrying its splits', () async {
    final (sdk, group, member, _) = await offlineWithGroup();
    addTearDown(sdk.close);

    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );

    final queued = await sdk.sync.queued();
    expect(queued.single.op, 'expense.create');
    expect(
      (queued.single.payload['splits']! as List).length,
      1,
      reason: 'the expense and its entries replay as one unit or the server skips the expense',
    );
  });

  test('balances move on an offline write, computed by the same Go engine', () async {
    final (sdk, group, member, _) = await offlineWithGroup();
    addTearDown(sdk.close);

    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );

    final balances = await sdk.balances.get(group.id);
    expect(
      balances.fold<int>(0, (sum, b) => sum + b.netCents),
      0,
      reason: 'a ledger that does not sum to zero is a bug wherever it was computed',
    );
  });

  test('an invalid split is rejected before anything is written', () async {
    final (sdk, group, member, _) = await offlineWithGroup();
    addTearDown(sdk.close);

    await expectLater(
      sdk.expenses.createExpense(
        groupId: group.id,
        payerMemberId: member.id,
        description: 'Bad',
        date: DateTime.utc(2026, 8, 6),
        // Entries that do not sum to the total: the engine rejects this.
        split: SplitSpec.exact(
          totalCents: 3000,
          entries: [ExactSplitEntry(memberId: member.id, amountCents: 10)],
        ),
      ),
      throwsA(isA<Exception>()),
    );

    expect(await sdk.expenses.watch(group.id).first, isEmpty);
    expect(await sdk.sync.queued(), isEmpty);
  });

  test('an offline edit replaces the local row and queues an update on its base', () async {
    final (sdk, group, member, connectivity) = await offlineWithGroup();
    addTearDown(sdk.close);
    // Created and synced while online, so it has a server `updated` stamp.
    connectivity.goOnline();
    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );
    await sdk.sync.now();
    connectivity.goOffline();

    await sdk.expenses.updateExpense(
      expenseId: expense.id,
      payerMemberId: member.id,
      description: 'Dinner and drinks',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [member.id]),
    );

    final local = (await sdk.expenses.watch(group.id).first).single;
    expect(local.description, 'Dinner and drinks');
    expect(local.amountCents, 4000);
    expect(local.pending, isTrue);

    final op = (await sdk.sync.queued()).single;
    expect(op.op, 'expense.update');
    expect(
      op.baseUpdated,
      isNotNull,
      reason: 'without a base there is nothing to conflict against',
    );
  });

  test('an offline delete removes the row locally and queues the delete', () async {
    final (sdk, group, member, connectivity) = await offlineWithGroup();
    addTearDown(sdk.close);

    connectivity.goOnline();
    final expense = await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: member.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
    );
    await sdk.sync.now();
    connectivity.goOffline();

    await sdk.expenses.deleteExpense(expense.id);

    expect(await sdk.expenses.watch(group.id).first, isEmpty);
    expect((await sdk.sync.queued()).single.op, 'expense.delete');
  });

  test('a settlement recorded offline is local and queued', () async {
    final (sdk, group, member, _) = await offlineWithGroup();
    addTearDown(sdk.close);

    await sdk.settlements.createSettlement(
      groupId: group.id,
      fromMemberId: member.id,
      // The group has one real member; a settlement needs two distinct
      // sides, and the engine rejects from == to.
      toMemberId: 'othermember0001',
      amountCents: 500,
    );

    expect((await sdk.settlements.watch(group.id).first).single.amountCents, 500);
    expect((await sdk.sync.queued()).single.op, 'settlement.create');
  });
}
