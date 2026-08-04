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

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test('a user who never joined anything is erased', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    await auth.signUp(
      email: 'goodbye-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );

    expect(await auth.deleteAccount(), 'deleted');
    expect(auth.currentUser, isNull);
  });

  test('owning a group is enough to force anonymization', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groups = GroupsApi(pb);
    await auth.signUp(
      email: 'owner-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    // No expense exists, but groups.owner is a required non-cascading
    // reference to users, so the row cannot be erased while the group
    // stands — and the group is not this user's alone to destroy.
    await groups.createGroup(name: 'Solo', currency: 'USD');

    expect(await auth.deleteAccount(), 'anonymized');
    expect(auth.currentUser, isNull);
  });

  test('a user who appears in an expense is anonymized, and says so', () async {
    final pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    final groups = GroupsApi(pb);
    final expenses = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final user = await auth.signUp(
      email: 'historic-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final group = await groups.createGroup(name: 'History', currency: 'USD');
    final me = (await groups.listMembers(group.id)).firstWhere((m) => m.userId == user.id);

    // Paid entirely by, and owed entirely to, the same person: a real
    // expense that still leaves a zero balance, so only the history rule
    // decides the outcome.
    await expenses.createExpense(
      groupId: group.id,
      payerMemberId: me.id,
      description: 'Solo dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [me.id]),
    );

    expect(await auth.deleteAccount(), 'anonymized');
    expect(auth.currentUser, isNull);
  });

  test('an outstanding balance blocks deletion', () async {
    final ownerPb = PocketBase(server.baseUrl);
    final ownerAuth = AuthApi(ownerPb);
    final groups = GroupsApi(ownerPb);
    final expenses = ExpensesApi(ownerPb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final owner = await ownerAuth.signUp(
      email: 'creditor-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final group = await groups.createGroup(name: 'Owing', currency: 'USD');

    final debtorPb = PocketBase(server.baseUrl);
    final debtorAuth = AuthApi(debtorPb);
    final debtorUser = await debtorAuth.signUp(
      email: 'debtor-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    final debtor = await groups.addMember(groupId: group.id, userId: debtorUser.id, role: 'member');
    final ownerMember = (await groups.listMembers(
      group.id,
    )).firstWhere((m) => m.userId == owner.id);

    await expenses.createExpense(
      groupId: group.id,
      payerMemberId: ownerMember.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [ownerMember.id, debtor.id]),
    );

    expect(
      (await BalancesApi(
        ownerPb,
      ).getBalances(group.id)).firstWhere((b) => b.memberId == debtor.id).netCents,
      -500,
    );

    await expectLater(debtorAuth.deleteAccount(), throwsA(anything));
    expect(debtorAuth.currentUser, isNotNull, reason: 'a refused delete signed the user out');
  });

  test('deleteAccount with no session is a no-op', () async {
    final auth = AuthApi(PocketBase(server.baseUrl));
    expect(await auth.deleteAccount(), 'deleted');
    expect(auth.currentUser, isNull);
  });
}
