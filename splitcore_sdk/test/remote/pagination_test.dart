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
      email: 'pager-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Paging', currency: 'USD');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == user.id);

    for (var i = 0; i < 7; i++) {
      await expensesApi.createExpense(
        groupId: group.id,
        payerMemberId: owner.id,
        description: 'Expense $i',
        date: DateTime.utc(2026, 7, i + 1),
        split: SplitSpec.equal(totalCents: 100 * (i + 1), memberIds: [owner.id]),
      );
    }
  });

  test('listExpenses returns one page, newest first, with total metadata', () async {
    final first = await expensesApi.listExpenses(group.id, perPage: 3);

    expect(first.items.length, 3);
    expect(first.items.map((e) => e.description), ['Expense 6', 'Expense 5', 'Expense 4']);
    expect(first.page, 1);
    expect(first.totalItems, 7);
    expect(first.totalPages, 3);
    expect(first.hasMore, isTrue);
  });

  test('the last page reports no more pages', () async {
    final last = await expensesApi.listExpenses(group.id, page: 3, perPage: 3);

    expect(last.items.length, 1);
    expect(last.items.single.description, 'Expense 0');
    expect(last.hasMore, isFalse);
  });

  test('listAllExpenses still returns every row for balance math', () async {
    final all = await expensesApi.listAllExpenses(group.id);
    expect(all.length, 7);
  });

  test('searchExpenses matches on description, case-insensitively', () async {
    final hits = await expensesApi.searchExpenses(group.id, 'expense 3');

    expect(hits.items.length, 1);
    expect(hits.items.single.description, 'Expense 3');
  });

  test('a search term with filter syntax matches nothing instead of everything', () async {
    // Unbound, this term would close the literal and OR in a match-all
    // clause. Bound, it is just a description nothing has.
    final hits = await expensesApi.searchExpenses(group.id, r"x' || id != '");

    expect(hits.items, isEmpty);
  });

  test('an empty search term degrades to a plain listing', () async {
    final hits = await expensesApi.searchExpenses(group.id, '   ');

    expect(hits.totalItems, 7);
  });
}
