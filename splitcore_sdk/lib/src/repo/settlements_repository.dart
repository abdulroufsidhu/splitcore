// The public read path for settlements: local rows, re-emitted when sync
// writes.
import '../calc_api.dart';
import '../local/dao/outbox_dao.dart';
import '../local/dao/settlement_dao.dart';
import '../local/database.dart';
import '../local/ids.dart';
import '../models.dart';
import '../sync/outbox_op.dart';
import '../sync/sync_engine.dart';
import 'local_ledger.dart';

class SettlementsRepository {
  SettlementsRepository(this._db, this._sync, SplitcoreCalc calc)
    : _ledger = LocalLedger(_db, calc);

  final SplitcoreDb _db;
  final SyncEngine _sync;
  final LocalLedger _ledger;

  Stream<List<Settlement>> watch(String groupId) =>
      _db.watch({'settlements'}, () => SettlementDao(_db).listSettlements(groupId));

  /// The current settlement list, for callers that want a value rather than
  /// a subscription.
  Future<List<Settlement>> listSettlements(String groupId) async =>
      SettlementDao(_db).listSettlements(groupId);

  /// Records a reimbursement locally and queues it.
  ///
  /// The staleness guard that used to run here has moved into the push
  /// path: the engine pulls a group whose server version has moved before
  /// replaying a settlement for it, so a reimbursement is still never
  /// applied on top of state known to be behind — and, unlike before, the
  /// user can record one with no connection at all.
  Future<Settlement> createSettlement({
    required String groupId,
    required String fromMemberId,
    required String toMemberId,
    required int amountCents,
    String note = '',
  }) async {
    final settlement = Settlement(
      id: newLocalId(),
      groupId: groupId,
      fromMemberId: fromMemberId,
      toMemberId: toMemberId,
      amountCents: amountCents,
      date: DateTime.now().toUtc(),
      note: note,
    );

    _db.transaction({'settlements', 'outbox'}, () {
      SettlementDao(_db).upsertSettlement(settlement, pending: true);
      OutboxDao(_db).enqueue(
        op: OutboxOps.settlementCreate,
        recordId: settlement.id,
        payload: {
          'groupId': groupId,
          'fromMemberId': fromMemberId,
          'toMemberId': toMemberId,
          'amountCents': amountCents,
          'note': note,
          'date': settlement.date.toIso8601String(),
        },
      );
    });

    await _ledger.recompute(groupId);
    _sync.wake();
    return settlement;
  }
}
