// The public read path for settlements: local rows, re-emitted when sync
// writes.
import '../local/dao/settlement_dao.dart';
import '../local/dao/sync_state_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/settlements_api.dart';
import '../sync/sync_engine.dart';

class SettlementsRepository {
  SettlementsRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final SettlementsApi _api;
  final SyncEngine _sync;

  Stream<List<Settlement>> watch(String groupId) =>
      _db.watch({'settlements'}, () => SettlementDao(_db).listSettlements(groupId));

  /// Records a reimbursement. The local sync cursor is what the server's
  /// staleness check is measured against, so a settlement is never written
  /// on top of local state known to be behind: [SettlementsApi] pulls the
  /// group first when it is.
  Future<Settlement> createSettlement({
    required String groupId,
    required String fromMemberId,
    required String toMemberId,
    required int amountCents,
    String note = '',
  }) async {
    final settlement = await _api.createSettlement(
      groupId: groupId,
      localVersion: SyncStateDao(_db).versionOf(groupId),
      fromMemberId: fromMemberId,
      toMemberId: toMemberId,
      amountCents: amountCents,
      note: note,
    );
    await _sync.now();
    return settlement;
  }
}
