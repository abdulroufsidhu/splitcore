// `settlements` rows <-> Settlement.
import '../../models.dart';
import '../database.dart';

class SettlementDao {
  SettlementDao(this._db);

  final SplitcoreDb _db;

  /// [protectedIds] survive the delete — see [ExpenseDao.replaceGroupExpenses]
  /// for why a pull must not erase a row with an unsent write behind it.
  void replaceGroupSettlements(
    String groupId,
    List<Settlement> settlements, {
    Set<String> protectedIds = const {},
  }) {
    if (protectedIds.isEmpty) {
      _db.raw.execute('DELETE FROM settlements WHERE group_id = ?', [groupId]);
    } else {
      final placeholders = List.filled(protectedIds.length, '?').join(',');
      _db.raw.execute('DELETE FROM settlements WHERE group_id = ? AND id NOT IN ($placeholders)', [
        groupId,
        ...protectedIds,
      ]);
    }
    final statement = _db.raw.prepare('''
      INSERT OR REPLACE INTO settlements
        (id, group_id, from_member_id, to_member_id, amount_cents, date, note, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    try {
      for (final s in settlements) {
        if (protectedIds.contains(s.id)) continue;
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

  /// Writes one settlement. Used by a local write, where only this row
  /// changed — unlike [replaceGroupSettlements], which mirrors the server's
  /// whole set.
  void upsertSettlement(Settlement s, {required bool pending}) => _db.raw.execute(
    '''
    INSERT INTO settlements
      (id, group_id, from_member_id, to_member_id, amount_cents, date, note, updated, pending)
    VALUES (?, ?, ?, ?, ?, ?, ?, NULL, ?)
    ON CONFLICT(id) DO UPDATE SET
      amount_cents = excluded.amount_cents,
      note = excluded.note,
      pending = excluded.pending
    ''',
    [
      s.id,
      s.groupId,
      s.fromMemberId,
      s.toMemberId,
      s.amountCents,
      s.date.toUtc().toIso8601String(),
      s.note,
      pending ? 1 : 0,
    ],
  );

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
