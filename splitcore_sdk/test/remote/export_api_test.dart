import 'dart:convert';

import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/export_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/remote/local_store.dart';
import 'package:splitcore_sdk/src/remote/settlements_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late ExportApi exportApi;
  late ExpensesApi expensesApi;
  late SettlementsApi settlementsApi;
  late Group group;
  late GroupMember owner;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    final pb = PocketBase(server.baseUrl);
    final calc = SplitcoreCalc.open(resolveLinuxLibPath());
    final auth = AuthApi(pb);
    final groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, calc);
    settlementsApi = SettlementsApi(pb, calc, LocalStore());
    exportApi = ExportApi(groupsApi, expensesApi, settlementsApi);

    final ownerUser = await auth.signUp(
      email: 'export-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    await auth.updateProfile(name: 'Ada');
    group = await groupsApi.createGroup(name: 'Export', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'exportee-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');
    owner = (await groupsApi.listMembers(group.id)).firstWhere((m) => m.userId == ownerUser.id);
  });

  test('the CSV has a header and one row per member share', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    final csv = await exportApi.groupToCsv(group.id);
    final lines = const LineSplitter().convert(csv);

    expect(lines.first, 'date,type,description,payer,member,amount,currency');
    expect(lines.length, 3, reason: 'header + one row per split entry\n$csv');
    expect(lines.skip(1).every((l) => l.contains('expense')), isTrue);
    expect(lines.skip(1).every((l) => l.endsWith(',USD')), isTrue);
    expect(lines.skip(1).every((l) => l.startsWith('2026-07-01,')), isTrue);
  });

  test('amounts are exact decimal strings, never floats', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Odd',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.exact(
        totalCents: 1,
        entries: [ExactSplitEntry(memberId: owner.id, amountCents: 1)],
      ),
    );

    final csv = await exportApi.groupToCsv(group.id);
    expect(csv.contains(',0.01,'), isTrue, reason: 'one cent must render as 0.01\n$csv');
  });

  test('a description containing a comma or quote is escaped', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner, "the good place"',
      date: DateTime.utc(2026, 7, 3),
      split: SplitSpec.equal(totalCents: 200, memberIds: [owner.id]),
    );

    final csv = await exportApi.groupToCsv(group.id);
    expect(csv.contains('"Dinner, ""the good place"""'), isTrue, reason: csv);

    // Every data row must still have exactly 7 fields once unescaped —
    // the whole point of quoting is that the columns do not shift.
    for (final line in const LineSplitter().convert(csv).skip(1)) {
      expect(_countCsvFields(line), 7, reason: 'column count drifted on: $line');
    }
  });

  test('settlements appear alongside expenses, oldest first', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Taxi',
      date: DateTime.utc(2026, 7, 4),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );
    await settlementsApi.createSettlement(
      groupId: group.id,
      localVersion: 0,
      fromMemberId: other.id,
      toMemberId: owner.id,
      amountCents: 500,
      note: 'paid back',
    );

    final csv = await exportApi.groupToCsv(group.id);
    final lines = const LineSplitter().convert(csv).skip(1).toList();

    expect(lines.any((l) => l.contains('settlement')), isTrue, reason: csv);
    // Oldest first: the 07-04 expense rows precede the settlement written now.
    expect(lines.first.startsWith('2026-07-04,'), isTrue, reason: csv);
    expect(lines.last.contains('settlement'), isTrue, reason: csv);
  });

  test('member names are resolved, not raw ids', () async {
    await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Named',
      date: DateTime.utc(2026, 7, 5),
      split: SplitSpec.equal(totalCents: 500, memberIds: [owner.id]),
    );

    final csv = await exportApi.groupToCsv(group.id);
    expect(csv.contains('Ada'), isTrue, reason: 'payer name was not resolved\n$csv');
    expect(csv.contains(owner.id), isFalse, reason: 'a raw member id leaked into the export\n$csv');
  });
}

/// Counts RFC 4180 fields, respecting quoted sections.
int _countCsvFields(String line) {
  var fields = 1;
  var inQuotes = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == '"') {
      inQuotes = !inQuotes;
    } else if (c == ',' && !inQuotes) {
      fields++;
    }
  }
  return fields;
}
