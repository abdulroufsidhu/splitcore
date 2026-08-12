// Recomputes a group's balances from the rows currently in the local
// database, through the same Go engine the server runs
// (server/hooks/recompute.go). Nothing here adds a number in Dart.
//
// These balances are provisional: they let a screen show the right figures
// the instant an offline write lands, and the next successful pull replaces
// them with the server's. Both are produced by the same code, so they agree
// by construction rather than by review.
import '../calc_api.dart';
import '../local/dao/balance_dao.dart';
import '../local/dao/expense_dao.dart';
import '../local/dao/settlement_dao.dart';
import '../local/database.dart';
import '../models.dart';

class LocalLedger {
  LocalLedger(this._db, this._calc);

  final SplitcoreDb _db;
  final SplitcoreCalc _calc;

  /// Recomputes [groupId] and commits the result.
  ///
  /// Deliberately a separate commit from the write that triggered it: the
  /// compute is async (it crosses into an isolate) and SQLite holds a single
  /// writer, so keeping it inside the write's transaction would mean holding
  /// that writer open across an await. If the process dies in between, the
  /// queued op survives and the next pull restores the balances — the rows
  /// and their outbox entry, which must never disagree, are what share a
  /// commit.
  Future<void> recompute(String groupId) async {
    final expenseDao = ExpenseDao(_db);
    final expenses = <ExpenseInput>[];
    for (final e in expenseDao.listExpenses(groupId)) {
      expenses.add(
        ExpenseInput(
          payerId: e.payerMemberId,
          amountCents: e.amountCents,
          splits: [
            for (final s in expenseDao.listSplitEntries(e.id))
              Split(memberId: s.memberId, amountCents: s.amountCents),
          ],
        ),
      );
    }

    final settlements = [
      for (final s in SettlementDao(_db).listSettlements(groupId))
        SettlementInput(
          fromMemberId: s.fromMemberId,
          toMemberId: s.toMemberId,
          amountCents: s.amountCents,
        ),
    ];

    final balances = await _calc.computeBalances(expenses: expenses, settlements: settlements);
    _db.transaction({'balances'}, () {
      BalanceDao(_db).replaceGroupBalances(groupId, balances);
    });
  }
}
