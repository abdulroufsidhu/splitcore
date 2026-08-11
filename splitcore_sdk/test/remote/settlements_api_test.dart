import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/remote/settlements_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late GroupsApi groupsApi;
  late ExpensesApi expensesApi;
  late SplitcoreCalc calc;
  late List<String> resyncedGroups;
  late SettlementsApi settlementsApi;
  late Group group;
  late GroupMember payer;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    groupsApi = GroupsApi(pb);
    calc = SplitcoreCalc.open(resolveLinuxLibPath());
    expensesApi = ExpensesApi(pb, calc);
    resyncedGroups = [];
    settlementsApi = SettlementsApi(pb, (groupId) async => resyncedGroups.add(groupId));

    final ownerUser = await auth.signUp(
      email: 'settle-owner-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Settle test', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'settle-friend-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');
    // Re-read after the membership changes: adding a member bumps the
    // group's version, so the version carried by the createGroup response
    // is stale by the time this fixture is built.
    group = await groupsApi.getGroup(group.id);

    final members = await groupsApi.listMembers(group.id);
    payer = members.firstWhere((m) => m.userId == ownerUser.id);
  });

  test(
    'creates the settlement directly when the local version is current, without resyncing',
    () async {
      final settlement = await settlementsApi.createSettlement(
        groupId: group.id,
        localVersion: group.version,
        fromMemberId: other.id,
        toMemberId: payer.id,
        amountCents: 500,
      );

      expect(settlement.fromMemberId, other.id);
      expect(settlement.toMemberId, payer.id);
      expect(settlement.amountCents, 500);
      // Date is set server-side on create so history can be sorted by it.
      expect(settlement.date.difference(DateTime.now()).abs() < const Duration(minutes: 1), isTrue);
      // No staleness -> no resync -> local store was never populated.
      expect(resyncedGroups, isEmpty);
    },
  );

  test('listSettlements returns a group\'s settlements newest first', () async {
    final first = await settlementsApi.createSettlement(
      groupId: group.id,
      localVersion: group.version,
      fromMemberId: other.id,
      toMemberId: payer.id,
      amountCents: 200,
    );
    final second = await settlementsApi.createSettlement(
      groupId: group.id,
      localVersion: group.version,
      fromMemberId: other.id,
      toMemberId: payer.id,
      amountCents: 300,
    );

    final settlements = await settlementsApi.listSettlements(group.id);

    expect(settlements.items.map((s) => s.id), [second.id, first.id]);
    expect(settlements.totalItems, 2);
  });

  test('resyncs the group before creating a settlement when local state is stale', () async {
    final staleVersion = group.version;

    // Bumps the group's version server-side, leaving staleVersion behind.
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: payer.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [payer.id, other.id]),
    );

    final settlement = await settlementsApi.createSettlement(
      groupId: group.id,
      localVersion: staleVersion,
      fromMemberId: other.id,
      toMemberId: payer.id,
      amountCents: 500,
    );

    expect(settlement.amountCents, 500);
    expect(
      resyncedGroups,
      [group.id],
      reason:
          'a settlement written against known-stale local state can reimburse an amount the '
          'ledger no longer says is owed',
    );
  });
}
