import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/balances_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late GroupsApi groupsApi;
  late ExpensesApi expensesApi;
  late SplitcoreCalc calc;
  late BalancesApi balancesApi;
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
    balancesApi = BalancesApi(pb);

    final ownerUser = await auth.signUp(
      email: 'bal-owner-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Balances test', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'bal-friend-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');

    final members = await groupsApi.listMembers(group.id);
    payer = members.firstWhere((m) => m.userId == ownerUser.id);
  });

  test(
    'reads the server-cached balances after an expense mutates them, matching an independent local recompute',
    () async {
      await expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: payer.id,
        description: 'Taxi',
        date: DateTime.utc(2026, 7, 1),
        split: SplitSpec.equal(totalCents: 1000, memberIds: [payer.id, other.id]),
      );

      final serverBalances = await balancesApi.getBalances(group.id);

      final localBalances = await calc.computeBalances(
        expenses: [
          ExpenseInput(
            payerId: payer.id,
            amountCents: 1000,
            splits: [
              Split(memberId: payer.id, amountCents: 500),
              Split(memberId: other.id, amountCents: 500),
            ],
          ),
        ],
        settlements: const [],
      );

      Map<String, int> byMember(List<Balance> balances) => {
        for (final b in balances) b.memberId: b.netCents,
      };
      expect(byMember(serverBalances), byMember(localBalances));
    },
  );

  test('returns an empty list for a group with no expenses yet', () async {
    final balances = await balancesApi.getBalances(group.id);

    expect(balances, isEmpty);
  });
}
