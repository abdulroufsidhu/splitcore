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
  late ExpensesApi expensesApi;
  late BalancesApi balancesApi;
  late Group group;
  late GroupMember owner;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));
    balancesApi = BalancesApi(pb);

    final ownerUser = await auth.signUp(
      email: 'editor-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Editing', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'editee-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == ownerUser.id);
  });

  test('updateExpense rewrites fields, replaces splits, and leaves no stale entries', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    final updated = await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: other.id,
      description: 'Dinner (corrected)',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [owner.id, other.id]),
    );

    expect(updated.id, created.id);
    expect(updated.description, 'Dinner (corrected)');
    expect(updated.amountCents, 3000);
    expect(updated.payerMemberId, other.id);

    final entries = await expensesApi.listSplitEntries(created.id);
    expect(entries.length, 2, reason: 'old split entries were not replaced');
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 3000);
  });

  test('balances reflect the edit, not the original amount', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Taxi',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: owner.id,
      description: 'Taxi',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 4000, memberIds: [owner.id, other.id]),
    );

    final balances = await balancesApi.getBalances(group.id);
    final ownerNet = balances.firstWhere((b) => b.memberId == owner.id).netCents;
    // Owner paid 4000, owes 2000 of it: net +2000. If the old 1000 expense
    // still counted, this would be 2500.
    expect(ownerNet, 2000);
  });

  test('changing the split shape from equal to exact is honored', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 7, 4),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    await expensesApi.updateExpense(
      expenseId: created.id,
      payerMemberId: owner.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 7, 4),
      split: SplitSpec.exact(
        totalCents: 1000,
        entries: [
          ExactSplitEntry(memberId: owner.id, amountCents: 250),
          ExactSplitEntry(memberId: other.id, amountCents: 750),
        ],
      ),
    );

    final entries = await expensesApi.listSplitEntries(created.id);
    final byMember = {for (final e in entries) e.memberId: e.amountCents};
    expect(byMember[owner.id], 250);
    expect(byMember[other.id], 750);
  });

  test('a rejected split leaves the stored expense untouched', () async {
    final created = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Hotel',
      date: DateTime.utc(2026, 7, 5),
      split: SplitSpec.equal(totalCents: 2000, memberIds: [owner.id, other.id]),
    );

    // Exact amounts that do not sum to the total — the engine rejects this
    // before any record is written.
    await expectLater(
      expensesApi.updateExpense(
        expenseId: created.id,
        payerMemberId: owner.id,
        description: 'Hotel (bad)',
        date: DateTime.utc(2026, 7, 5),
        split: SplitSpec.exact(
          totalCents: 2000,
          entries: [ExactSplitEntry(memberId: owner.id, amountCents: 1)],
        ),
      ),
      throwsA(anything),
    );

    final entries = await expensesApi.listSplitEntries(created.id);
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 2000);
    final stored = (await expensesApi.listAllExpenses(
      group.id,
    )).firstWhere((e) => e.id == created.id);
    expect(stored.description, 'Hotel', reason: 'a rejected edit modified the stored expense');
  });
}
