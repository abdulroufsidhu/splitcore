// Settlements are reimbursement log entries. Every create is preceded by
// a staleness check (server/hooks/staleness.go); if the caller's local
// version is stale, local balances are recomputed from the group's full
// record set before the settlement is written — never create a
// settlement against known-stale local state.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';
import 'filters.dart';
import 'staleness_api.dart';

/// Brings [groupId]'s local state up to date. Injected as a callback rather
/// than a dependency on the sync engine, which would be a cycle: the engine
/// already owns this API.
typedef ResyncGroup = Future<void> Function(String groupId);

class SettlementsApi {
  SettlementsApi(this._pb, this._resync);

  final PocketBase _pb;

  // Was a bespoke recompute-from-log into an in-memory snapshot. That is
  // what a pull already does, against the same server-side numbers, so the
  // second implementation is gone rather than kept in step by hand.
  final ResyncGroup _resync;

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

  /// Replays a locally-recorded settlement, keeping its minted id so a
  /// retry that already landed is recognised rather than double-counted.
  /// The staleness guard lives in the push path, which pulls a group whose
  /// server version moved before replaying anything for it.
  Future<Settlement> createSettlementWithId({
    required String id,
    required String groupId,
    required String fromMemberId,
    required String toMemberId,
    required int amountCents,
    required DateTime date,
    String note = '',
  }) async {
    final record = await _pb
        .collection('settlements')
        .create(
          body: {
            'id': id,
            'group': groupId,
            'from_member': fromMemberId,
            'to_member': toMemberId,
            'amount_cents': amountCents,
            'date': date.toUtc().toIso8601String(),
            'note': note,
          },
        );
    return _settlementFromRecord(record);
  }

  /// One page of a group's settlements, newest first — powers per-group and
  /// global activity history alongside [ExpensesApi.listExpenses].
  Future<Page<Settlement>> listSettlements(String groupId, {int page = 1, int perPage = 50}) async {
    final result = await _pb
        .collection('settlements')
        .getList(page: page, perPage: perPage, filter: byGroup(_pb, groupId), sort: '-date');
    return Page<Settlement>(
      items: [for (final r in result.items) _settlementFromRecord(r)],
      page: result.page,
      perPage: result.perPage,
      totalItems: result.totalItems,
      totalPages: result.totalPages,
    );
  }

  /// Every settlement in the group — for balance recomputation and export.
  Future<List<Settlement>> listAllSettlements(String groupId) async {
    final records = await _pb
        .collection('settlements')
        .getFullList(batch: 200, filter: byGroup(_pb, groupId), sort: '-date');
    return [for (final r in records) _settlementFromRecord(r)];
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
