// `expenses` + `split_entries` rows <-> Expense/SplitEntry.
import '../../models.dart';
import '../database.dart';

class ExpenseDao {
  ExpenseDao(this._db);

  final SplitcoreDb _db;

  /// Replaces [groupId]'s expenses with [expenses], and each expense's split
  /// entries with [splitsByExpenseId]'s. Wholesale rather than a diff: the
  /// server's set is authoritative, and a deleted expense that lingered
  /// locally would keep counting toward balances the user can see.
  ///
  /// The delete cascades to split_entries (see schema.dart), so entries for
  /// a dropped expense go with it.
  void replaceGroupExpenses(
    String groupId,
    List<Expense> expenses,
    Map<String, List<SplitEntry>> splitsByExpenseId,
  ) {
    _db.raw.execute('DELETE FROM expenses WHERE group_id = ?', [groupId]);

    final expenseStatement = _db.raw.prepare('''
      INSERT INTO expenses
        (id, group_id, payer_member_id, description, amount_cents, split_type, date, updated,
         pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    final entryStatement = _db.raw.prepare('''
      INSERT INTO split_entries (id, expense_id, member_id, amount_cents, receipt_filename)
      VALUES (?, ?, ?, ?, ?)
    ''');
    try {
      for (final e in expenses) {
        expenseStatement.execute([
          e.id,
          e.groupId,
          e.payerMemberId,
          e.description,
          e.amountCents,
          e.splitType,
          e.date.toUtc().toIso8601String(),
          null,
        ]);
        for (final s in splitsByExpenseId[e.id] ?? const <SplitEntry>[]) {
          entryStatement.execute([s.id, s.expenseId, s.memberId, s.amountCents, s.receiptFilename]);
        }
      }
    } finally {
      expenseStatement.dispose();
      entryStatement.dispose();
    }
  }

  /// Newest first, matching the group-detail list. [query] filters on
  /// description, case-insensitively; empty means no filter.
  List<Expense> listExpenses(String groupId, {String query = ''}) {
    final rows = query.isEmpty
        ? _db.raw.select('SELECT * FROM expenses WHERE group_id = ? ORDER BY date DESC, id DESC', [
            groupId,
          ])
        : _db.raw.select(
            r"SELECT * FROM expenses WHERE group_id = ? AND description LIKE ? ESCAPE '\' "
            'ORDER BY date DESC, id DESC',
            [groupId, '%${_escapeLike(query)}%'],
          );
    return rows
        .map(
          (r) => Expense(
            id: r['id'] as String,
            groupId: r['group_id'] as String,
            payerMemberId: r['payer_member_id'] as String,
            description: r['description'] as String,
            amountCents: r['amount_cents'] as int,
            splitType: r['split_type'] as String,
            date: DateTime.parse(r['date'] as String),
          ),
        )
        .toList();
  }

  // Without this a user searching for "50%" gets every expense back: % and _
  // are LIKE wildcards, not literals.
  String _escapeLike(String input) =>
      input.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  List<SplitEntry> listSplitEntries(String expenseId) => _db.raw
      .select('SELECT * FROM split_entries WHERE expense_id = ? ORDER BY id', [expenseId])
      .map(
        (r) => SplitEntry(
          id: r['id'] as String,
          expenseId: r['expense_id'] as String,
          memberId: r['member_id'] as String,
          amountCents: r['amount_cents'] as int,
          receiptFilename: r['receipt_filename'] as String?,
        ),
      )
      .toList();
}
