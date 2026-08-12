import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:splitcore_sdk/src/local/dao/balance_dao.dart';
import 'package:splitcore_sdk/src/local/dao/expense_dao.dart';
import 'package:splitcore_sdk/src/local/dao/group_dao.dart';
import 'package:splitcore_sdk/src/local/dao/settlement_dao.dart';
import 'package:splitcore_sdk/src/local/dao/sync_state_dao.dart';
import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

const _group = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 3, ownerId: 'u1');

Expense _expense({
  String id = 'e1',
  String description = 'Dinner',
  int amountCents = 3000,
  DateTime? date,
}) => Expense(
  id: id,
  groupId: 'g1',
  payerMemberId: 'm1',
  description: description,
  amountCents: amountCents,
  splitType: 'equal',
  date: date ?? DateTime.utc(2026, 8, 6),
);

void main() {
  late SplitcoreDb db;

  setUp(() {
    db = SplitcoreDb.inMemory();
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([_group]));
  });

  tearDown(() => db.close());

  test('a group round-trips', () {
    expect(GroupDao(db).listGroups(), [_group]);
  });

  test('upserting the same group twice updates rather than duplicating', () {
    const renamed = Group(
      id: 'g1',
      name: 'Trip to Rome',
      currency: 'USD',
      version: 4,
      ownerId: 'u1',
    );
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([renamed]));

    expect(GroupDao(db).listGroups(), [renamed]);
  });

  test('deleteGroupsMissingFrom removes groups the server no longer lists', () {
    const other = Group(id: 'g2', name: 'Flat', currency: 'EUR', version: 1, ownerId: 'u1');
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([other]));

    db.transaction({'groups'}, () => GroupDao(db).deleteGroupsMissingFrom({'g1'}));

    expect(GroupDao(db).listGroups().map((g) => g.id), ['g1']);
  });

  test('deleteGroupsMissingFrom with an empty keep-set clears every group', () {
    db.transaction({'groups'}, () => GroupDao(db).deleteGroupsMissingFrom({}));

    expect(GroupDao(db).listGroups(), isEmpty);
  });

  test('members round-trip and are scoped to their group', () {
    const member = GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Ada');
    db.transaction({'members'}, () => GroupDao(db).upsertMembers('g1', [member]));

    expect(GroupDao(db).listMembers('g1'), [member]);
    expect(GroupDao(db).listMembers('g2'), isEmpty);
  });

  test('upsertMembers replaces the list so a removed member does not linger', () {
    const ada = GroupMember(id: 'm1', groupId: 'g1', userId: 'u1', role: 'owner', name: 'Ada');
    const bob = GroupMember(id: 'm2', groupId: 'g1', userId: 'u2', role: 'member', name: 'Bob');
    db.transaction({'members'}, () => GroupDao(db).upsertMembers('g1', [ada, bob]));

    db.transaction({'members'}, () => GroupDao(db).upsertMembers('g1', [ada]));

    expect(GroupDao(db).listMembers('g1'), [ada]);
  });

  test('replaceGroupExpenses writes expenses with their split entries', () {
    final expense = _expense();
    const entry = SplitEntry(id: 's1', expenseId: 'e1', memberId: 'm1', amountCents: 3000);

    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses(
        'g1',
        [expense],
        {
          'e1': [entry],
        },
      );
    });

    expect(ExpenseDao(db).listExpenses('g1'), [expense]);
    expect(ExpenseDao(db).listSplitEntries('e1'), [entry]);
  });

  test('replaceGroupExpenses drops expenses the server no longer has', () {
    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [_expense()], const {});
    });

    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', const [], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1'), isEmpty);
  });

  test('listExpenses returns newest first and filters by description', () {
    final older = _expense(date: DateTime.utc(2026, 8, 1));
    final newer = _expense(
      id: 'e2',
      description: 'Taxi',
      amountCents: 1200,
      date: DateTime.utc(2026, 8, 5),
    );
    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [older, newer], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1').map((e) => e.id), ['e2', 'e1']);
    expect(ExpenseDao(db).listExpenses('g1', query: 'tax').map((e) => e.id), ['e2']);
  });

  test('a LIKE wildcard in the search box is matched literally, not as a wildcard', () {
    final literal = _expense(id: 'e1', description: '50% deposit');
    final other = _expense(id: 'e2', description: 'Taxi');
    db.transaction({'expenses', 'split_entries'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [literal, other], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1', query: '%').map((e) => e.id), ['e1']);
    expect(ExpenseDao(db).listExpenses('g1', query: '_').map((e) => e.id), isEmpty);
  });

  test('settlements round-trip, newest first', () {
    final s = Settlement(
      id: 't1',
      groupId: 'g1',
      fromMemberId: 'm1',
      toMemberId: 'm2',
      amountCents: 500,
      date: DateTime.utc(2026, 8, 4),
      note: 'cash',
    );
    db.transaction({'settlements'}, () => SettlementDao(db).replaceGroupSettlements('g1', [s]));

    expect(SettlementDao(db).listSettlements('g1'), [s]);
  });

  test('balances are replaced wholesale, never merged', () {
    db.transaction({'balances'}, () {
      BalanceDao(db).replaceGroupBalances('g1', const [
        Balance(memberId: 'm1', netCents: 1500),
        Balance(memberId: 'm2', netCents: -1500),
      ]);
    });
    db.transaction({'balances'}, () {
      BalanceDao(db).replaceGroupBalances('g1', const [Balance(memberId: 'm1', netCents: 0)]);
    });

    expect(BalanceDao(db).listBalances('g1'), const [Balance(memberId: 'm1', netCents: 0)]);
  });

  test('an unsynced group reports -1 so the first staleness check always pulls', () {
    // Not 0: the server reports current when clientVersion == serverVersion,
    // and a freshly created group is version 0 there. A 0 sentinel would
    // match and skip the first pull entirely.
    expect(SyncStateDao(db).versionOf('g1'), -1);
    expect(SyncStateDao(db).syncedAt('g1'), isNull);
  });

  test('markSynced records the cursor and the time', () {
    db.transaction({'sync_state'}, () => SyncStateDao(db).markSynced('g1', 7));

    expect(SyncStateDao(db).versionOf('g1'), 7);
    expect(SyncStateDao(db).syncedAt('g1'), isNotNull);
  });

  test('markSynced twice advances the cursor rather than failing on the primary key', () {
    db.transaction({'sync_state'}, () => SyncStateDao(db).markSynced('g1', 7));
    db.transaction({'sync_state'}, () => SyncStateDao(db).markSynced('g1', 9));

    expect(SyncStateDao(db).versionOf('g1'), 9);
  });
}
