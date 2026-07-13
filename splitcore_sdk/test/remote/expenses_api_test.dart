import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/calc_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/expenses_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

Uint8List _syntheticPng(int width, int height) {
  final image = img.Image(width: width, height: height);
  final rnd = Random(7);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      int channel(int base) => (base + rnd.nextInt(31) - 15).clamp(0, 255);
      image.setPixelRgb(x, y, channel(255 * x ~/ width), channel(255 * y ~/ height), channel(128));
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late GroupsApi groupsApi;
  late ExpensesApi expensesApi;
  late Group group;
  late GroupMember owner;
  late GroupMember other;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    pb = PocketBase(server.baseUrl);
    final auth = AuthApi(pb);
    groupsApi = GroupsApi(pb);
    expensesApi = ExpensesApi(pb, SplitcoreCalc.open(resolveLinuxLibPath()));

    final ownerUser = await auth.signUp(
      email: 'owner-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    group = await groupsApi.createGroup(name: 'Trip', currency: 'USD');

    final otherAuth = AuthApi(PocketBase(server.baseUrl));
    final otherUser = await otherAuth.signUp(
      email: 'friend-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    other = await groupsApi.addMember(groupId: group.id, userId: otherUser.id, role: 'member');

    final members = await groupsApi.listMembers(group.id);
    owner = members.firstWhere((m) => m.userId == ownerUser.id);
  });

  test('createExpense splits equally and writes one split_entries row per member', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );

    expect(expense.amountCents, 1000);
    expect(expense.splitType, 'equal');

    final entries = await expensesApi.listSplitEntries(expense.id);
    expect(entries.length, 2);
    expect(entries.fold<int>(0, (sum, e) => sum + e.amountCents), 1000);
    expect(entries.map((e) => e.memberId).toSet(), {owner.id, other.id});
  });

  test('listExpenses returns a group\'s expenses newest first', () async {
    final first = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Groceries',
      date: DateTime.utc(2026, 6, 28),
      split: SplitSpec.equal(totalCents: 1000, memberIds: [owner.id, other.id]),
    );
    final second = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Internet bill',
      date: DateTime.utc(2026, 7, 1),
      split: SplitSpec.equal(totalCents: 2000, memberIds: [owner.id, other.id]),
    );

    final expenses = await expensesApi.listExpenses(group.id);

    expect(expenses.map((e) => e.id), [second.id, first.id]);
  });

  test('receiptUrl builds the PocketBase file URL, and is null with no receipt', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Hotel',
      date: DateTime.utc(2026, 7, 3),
      split: SplitSpec.equal(totalCents: 2000, memberIds: [owner.id]),
    );
    final entry = (await expensesApi.listSplitEntries(expense.id)).single;
    expect(expensesApi.receiptUrl(entry), isNull);

    final withReceipt = await expensesApi.attachReceipt(entry.id, _syntheticPng(40, 40));
    expect(
      expensesApi.receiptUrl(withReceipt),
      '${server.baseUrl}/api/files/split_entries/${withReceipt.id}/${withReceipt.receiptFilename}',
    );
  });

  test('deleteExpense removes the expense', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Snacks',
      date: DateTime.utc(2026, 7, 2),
      split: SplitSpec.equal(totalCents: 500, memberIds: [owner.id]),
    );

    await expensesApi.deleteExpense(expense.id);

    expect(() => pb.collection('expenses').getOne(expense.id), throwsA(anything));
  });

  test('attachReceipt compresses raw image bytes and attaches them to a split entry', () async {
    final expense = await expensesApi.createExpense(
      groupId: group.id,
      payerMemberId: owner.id,
      description: 'Hotel',
      date: DateTime.utc(2026, 7, 3),
      split: SplitSpec.equal(totalCents: 2000, memberIds: [owner.id]),
    );
    final entry = (await expensesApi.listSplitEntries(expense.id)).single;

    final updated = await expensesApi.attachReceipt(entry.id, _syntheticPng(2000, 2000));

    expect(updated.receiptFilename, isNotNull);
    expect(updated.receiptFilename, isNotEmpty);
  });
}
