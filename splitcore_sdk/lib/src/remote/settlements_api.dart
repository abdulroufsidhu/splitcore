// Settlements are reimbursement log entries. Every create is preceded by
// a staleness check (server/hooks/staleness.go); if the caller's local
// version is stale, local balances are recomputed from the group's full
// record set before the settlement is written — never create a
// settlement against known-stale local state.
import 'package:pocketbase/pocketbase.dart';

import '../calc_api.dart';
import '../models.dart';
import 'local_store.dart';
import 'staleness_api.dart';

class SettlementsApi {
  SettlementsApi(this._pb, this._calc, this._store);

  final PocketBase _pb;
  final SplitcoreCalc _calc;
  final LocalStore _store;

  Future<Settlement> createSettlement({
    required String groupId,
    required int localVersion,
    required String fromMemberId,
    required String toMemberId,
    required int amountCents,
    String note = '',
  }) async {
    final staleness = await checkStaleness(_pb, groupId: groupId, localVersion: localVersion);
    if (!staleness.current) {
      await _resync(groupId);
    }

    final record = await _pb
        .collection('settlements')
        .create(
          body: {
            'group': groupId,
            'from_member': fromMemberId,
            'to_member': toMemberId,
            'amount_cents': amountCents,
            'date': DateTime.now().toUtc().toIso8601String(),
            'note': note,
          },
        );
    return _settlementFromRecord(record);
  }

  /// A group's settlements, newest first — powers per-group and global
  /// activity history alongside [ExpensesApi.listExpenses].
  Future<List<Settlement>> listSettlements(String groupId) async {
    final records = await _pb
        .collection('settlements')
        .getFullList(filter: "group = '$groupId'", sort: '-date');
    return [for (final r in records) _settlementFromRecord(r)];
  }

  Future<void> _resync(String groupId) async {
    final expenseRecords = await _pb
        .collection('expenses')
        .getFullList(filter: "group = '$groupId'");

    final expenses = <ExpenseInput>[];
    for (final expense in expenseRecords) {
      final splitRecords = await _pb
          .collection('split_entries')
          .getFullList(filter: "expense = '${expense.id}'");
      expenses.add(
        ExpenseInput(
          payerId: expense.getStringValue('payer'),
          amountCents: expense.getIntValue('amount_cents'),
          splits: [
            for (final s in splitRecords)
              Split(
                memberId: s.getStringValue('member'),
                amountCents: s.getIntValue('amount_cents'),
              ),
          ],
        ),
      );
    }

    final settlementRecords = await _pb
        .collection('settlements')
        .getFullList(filter: "group = '$groupId'");
    final settlements = [
      for (final s in settlementRecords)
        SettlementInput(
          fromMemberId: s.getStringValue('from_member'),
          toMemberId: s.getStringValue('to_member'),
          amountCents: s.getIntValue('amount_cents'),
        ),
    ];

    final balances = await _calc.computeBalances(expenses: expenses, settlements: settlements);
    final group = await _pb.collection('groups').getOne(groupId);
    _store.put(groupId, GroupSnapshot(version: group.getIntValue('version'), balances: balances));
  }

  Settlement _settlementFromRecord(RecordModel record) => Settlement(
    id: record.id,
    groupId: record.getStringValue('group'),
    fromMemberId: record.getStringValue('from_member'),
    toMemberId: record.getStringValue('to_member'),
    amountCents: record.getIntValue('amount_cents'),
    // tryParse: settlements written before this field existed have no
    // date — don't crash listing history over old data.
    date:
        DateTime.tryParse(record.getStringValue('date')) ?? DateTime.fromMillisecondsSinceEpoch(0),
    note: record.getStringValue('note'),
  );
}
