import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/remote/staleness_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late GroupsApi groupsApi;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember payer;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    await auth.signUp(
      email: 'staleness-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Staleness test', currency: 'USD');
    payer = (await groupsApi.listMembers(group.id)).single;
  });

  test('current: true when the local version matches the server version', () async {
    final result = await checkStaleness(pb, groupId: group.id, localVersion: group.version);

    expect(result, StalenessResult(current: true, serverVersion: group.version));
  });

  test('current: false with the new server version after a mutation bumps it', () async {
    final staleVersion = group.version;

    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: payer.id,
      description: 'Coffee',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 400, memberIds: [payer.id]),
    );

    final result = await checkStaleness(pb, groupId: group.id, localVersion: staleVersion);

    expect(result.current, isFalse);
    expect(result.serverVersion, greaterThan(staleVersion));
  });
}
