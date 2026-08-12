// `balances` rows <-> Balance.
//
// Balances are derived, never client-authored: the server rewrites them on
// every mutation (server/hooks/recompute.go), so a pull replaces the whole
// group's set rather than merging. Merging would let a member who dropped
// to zero keep a stale non-zero row forever.
import '../../models.dart';
import '../database.dart';

class BalanceDao {
  BalanceDao(this._db);

  final SplitcoreDb _db;

  void replaceGroupBalances(String groupId, List<Balance> balances) {
    _db.raw.execute('DELETE FROM balances WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare(
      'INSERT INTO balances (group_id, member_id, net_cents) VALUES (?, ?, ?)',
    );
    try {
      for (final b in balances) {
        statement.execute([groupId, b.memberId, b.netCents]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<Balance> listBalances(String groupId) => _db.raw
      .select('SELECT * FROM balances WHERE group_id = ? ORDER BY member_id', [groupId])
      .map((r) => Balance(memberId: r['member_id'] as String, netCents: r['net_cents'] as int))
      .toList();
}
