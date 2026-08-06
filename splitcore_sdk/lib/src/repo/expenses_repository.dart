// The public read path for expenses: local rows, re-emitted when sync
// writes. Writes reach the server and then pull.
import 'dart:typed_data';

import '../local/dao/expense_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/expenses_api.dart';
import '../sync/sync_engine.dart';

class ExpensesRepository {
  ExpensesRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final ExpensesApi _api;
  final SyncEngine _sync;

  /// Newest first. [query] filters on description — the group search box.
  /// The filter runs in SQLite, so searching works with no connection and
  /// without the debounce-a-request dance the remote search needed.
  Stream<List<Expense>> watch(String groupId, {String query = ''}) =>
      _db.watch({'expenses'}, () => ExpenseDao(_db).listExpenses(groupId, query: query));

  Stream<List<SplitEntry>> watchSplitEntries(String expenseId) =>
      _db.watch({'split_entries'}, () => ExpenseDao(_db).listSplitEntries(expenseId));

  /// The current expense list, for callers that want a value rather than a
  /// subscription — the activity feed and the export path. Unpaged: these
  /// are local rows, so there is no request to economise on.
  Future<List<Expense>> listExpenses(String groupId, {String query = ''}) async =>
      ExpenseDao(_db).listExpenses(groupId, query: query);

  /// One expense's split entries, for callers that want a value rather than
  /// a subscription.
  Future<List<SplitEntry>> listSplitEntries(String expenseId) async =>
      ExpenseDao(_db).listSplitEntries(expenseId);

  Future<Expense> createExpense({
    required String groupId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final expense = await _api.createExpense(
      groupId: groupId,
      payerMemberId: payerMemberId,
      description: description,
      date: date,
      split: split,
    );
    await _sync.now();
    return expense;
  }

  Future<Expense> updateExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final expense = await _api.updateExpense(
      expenseId: expenseId,
      payerMemberId: payerMemberId,
      description: description,
      date: date,
      split: split,
    );
    await _sync.now();
    return expense;
  }

  Future<void> deleteExpense(String expenseId) async {
    await _api.deleteExpense(expenseId);
    await _sync.now();
  }

  /// Public URL for a split entry's attached receipt image, or null when no
  /// receipt is attached. Remote by nature — an image is not mirrored into
  /// the local database.
  String? receiptUrl(SplitEntry entry) => _api.receiptUrl(entry);

  Future<SplitEntry> attachReceipt(String splitEntryId, Uint8List imageBytes) async {
    final entry = await _api.attachReceipt(splitEntryId, imageBytes);
    await _sync.now();
    return entry;
  }
}
