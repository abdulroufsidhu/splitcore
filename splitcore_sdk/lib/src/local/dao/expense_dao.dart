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
          e.updated?.toUtc().toIso8601String(),
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
            updated: switch (r['updated']) {
              final String u => DateTime.parse(u),
              _ => null,
            },
            pending: (r['pending'] as int) == 1,
          ),
        )
        .toList();
  }

  // Without this a user searching for "50%" gets every expense back: % and _
  // are LIKE wildcards, not literals.
  String _escapeLike(String input) =>
      input.replaceAll(r'\', r'\\').replaceAll('%', r'\%').replaceAll('_', r'\_');

  /// The server's `updated` stamp for [expenseId] as stored, or null when
  /// the row is local-only. Returned as the raw string so a queued op
  /// compares exactly what the server sent, with no parse/format round trip
  /// in between to disagree about precision.
  String? updatedOf(String expenseId) {
    final rows = _db.raw.select('SELECT updated FROM expenses WHERE id = ?', [expenseId]);
    return rows.isEmpty ? null : rows.first['updated'] as String?;
  }

  /// Writes one expense and its entries, replacing any entries it already
  /// had. Used by a local write, where only this expense changed — unlike
  /// [replaceGroupExpenses], which mirrors the server's whole set.
  void upsertExpense(Expense expense, List<SplitEntry> entries, {required bool pending}) {
    _db.raw.execute(
      '''
      INSERT INTO expenses
        (id, group_id, payer_member_id, description, amount_cents, split_type, date, updated,
         pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        payer_member_id = excluded.payer_member_id,
        description = excluded.description,
        amount_cents = excluded.amount_cents,
        split_type = excluded.split_type,
        date = excluded.date,
        pending = excluded.pending
      ''',
      [
        expense.id,
        expense.groupId,
        expense.payerMemberId,
        expense.description,
        expense.amountCents,
        expense.splitType,
        expense.date.toUtc().toIso8601String(),
        expense.updated?.toUtc().toIso8601String(),
        pending ? 1 : 0,
      ],
    );

    _db.raw.execute('DELETE FROM split_entries WHERE expense_id = ?', [expense.id]);
    final statement = _db.raw.prepare('''
      INSERT INTO split_entries (id, expense_id, member_id, amount_cents, receipt_filename)
      VALUES (?, ?, ?, ?, ?)
    ''');
    try {
      for (final s in entries) {
        statement.execute([s.id, expense.id, s.memberId, s.amountCents, s.receiptFilename]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// Cascades to split_entries (see schema.dart).
  void deleteExpense(String expenseId) =>
      _db.raw.execute('DELETE FROM expenses WHERE id = ?', [expenseId]);

  /// Marks which rows have an unsent op behind them, so the UI can grey
  /// them. Applied to the whole table at once because the outbox is the
  /// authority on the answer and it changes on every drain.
  void setPending(Set<String> pendingIds) {
    _db.raw.execute('UPDATE expenses SET pending = 0 WHERE pending = 1');
    if (pendingIds.isEmpty) return;
    final placeholders = List.filled(pendingIds.length, '?').join(',');
    _db.raw.execute(
      'UPDATE expenses SET pending = 1 WHERE id IN ($placeholders)',
      pendingIds.toList(),
    );
  }

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
