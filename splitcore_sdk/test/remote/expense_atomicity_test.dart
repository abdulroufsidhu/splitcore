import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember owner;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final user = await auth.signUp(
      email: 'atomic-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Atomic', currency: 'USD');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == user.id);
  });

  test('a split entry write failure leaves no orphan expense behind', () async {
    // A member id belonging to no group at all: the expense row is accepted
    // (its own payer is valid) but the server's split_entries validation
    // rejects "member must belong to the expense's group" partway through.
    final before = await expensesApi.listAllExpenses(group.id);

    await expectLater(
      expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: owner.id,
        description: 'Doomed',
        date: DateTime.utc(2026, 7, 9),
        split: SplitSpec.exact(
          totalCents: 1000,
          entries: [
            ExactSplitEntry(memberId: owner.id, amountCents: 500),
            const ExactSplitEntry(memberId: 'nonexistentmember', amountCents: 500),
          ],
        ),
      ),
      throwsA(anything),
    );

    final after = await expensesApi.listAllExpenses(group.id);
    expect(after.length, before.length, reason: 'orphan expense row survived a failed create');
    expect(after.any((e) => e.description == 'Doomed'), isFalse);
  });

  test('a successful create still writes the expense and all its splits', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Fine',
      date: DateTime.utc(2026, 7, 10),
      split: SplitSpec.equal(totalCents: 900, memberIds: [owner.id]),
    );

    final entries = await expensesApi.listSplitEntries(expense.id);
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 900);
  });
}
