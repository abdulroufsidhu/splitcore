// `settlements` rows <-> Settlement.
import '../../models.dart';
import '../database.dart';

class SettlementDao {
  SettlementDao(this._db);

  final SplitcoreDb _db;

  void replaceGroupSettlements(String groupId, List<Settlement> settlements) {
    _db.raw.execute('DELETE FROM settlements WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare('''
      INSERT INTO settlements
        (id, group_id, from_member_id, to_member_id, amount_cents, date, note, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    try {
      for (final s in settlements) {
        statement.execute([
          s.id,
          s.groupId,
          s.fromMemberId,
          s.toMemberId,
          s.amountCents,
          s.date.toUtc().toIso8601String(),
          s.note,
          null,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  List<Settlement> listSettlements(String groupId) => _db.raw
      .select('SELECT * FROM settlements WHERE group_id = ? ORDER BY date DESC, id DESC', [groupId])
      .map(
        (r) => Settlement(
          id: r['id'] as String,
          groupId: r['group_id'] as String,
          fromMemberId: r['from_member_id'] as String,
          toMemberId: r['to_member_id'] as String,
          amountCents: r['amount_cents'] as int,
          date: DateTime.parse(r['date'] as String),
          note: r['note'] as String,
        ),
      )
      .toList();
}
