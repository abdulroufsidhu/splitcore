// Expenses, local-first. A write commits to the local database and queues
// an op; the sync engine replays it. Nothing here waits on the network, so
// every method below works with no connection.
import 'dart:typed_data';

import '../calc_api.dart';
import '../local/dao/expense_dao.dart';
import '../local/dao/outbox_dao.dart';
import '../local/database.dart';
import '../local/ids.dart';
import '../models.dart';
import '../remote/expenses_api.dart';
import '../sync/outbox_op.dart';
import '../sync/sync_engine.dart';
import 'local_ledger.dart';

class ExpensesRepository {
  ExpensesRepository(this._db, this._api, this._sync, this._calc)
    : _ledger = LocalLedger(_db, _calc);

  final SplitcoreDb _db;
  final ExpensesApi _api;
  final SyncEngine _sync;
  final SplitcoreCalc _calc;
  final LocalLedger _ledger;

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

  Future<List<SplitEntry>> listSplitEntries(String expenseId) async =>
      ExpenseDao(_db).listSplitEntries(expenseId);

  Future<Expense> createExpense({
    required String groupId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    // Before anything is written: a rejected spec must fail without having
    // left a half-formed expense in the local database.
    final splits = await _calc.computeSplits(split);

    // Client-minted, in PocketBase's own format, so the split entries below
    // can reference an expense the server has never seen — and so replaying
    // a create that already landed is recognised rather than duplicated.
    final id = newLocalId();
    final expense = Expense(
      id: id,
      groupId: groupId,
      payerMemberId: payerMemberId,
      description: description,
      amountCents: split.totalCents,
      splitType: split.type,
      date: date,
      pending: true,
    );
    final entries = [
      for (final s in splits)
        SplitEntry(
          id: newLocalId(),
          expenseId: id,
          memberId: s.memberId,
          amountCents: s.amountCents,
        ),
    ];

    _db.transaction({'expenses', 'split_entries', 'outbox'}, () {
      ExpenseDao(_db).upsertExpense(expense, entries, pending: true);
      OutboxDao(_db).enqueue(
        op: OutboxOps.expenseCreate,
        recordId: id,
        payload: _createPayload(expense, entries),
      );
    });

    await _ledger.recompute(groupId);
    _sync.wake();
    return expense;
  }

  Future<Expense> updateExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final splits = await _calc.computeSplits(split);
    final dao = ExpenseDao(_db);

    final current = dao.byId(expenseId);
    if (current == null) {
      throw StateError('expense $expenseId is not in the local database');
    }
    final groupId = current.groupId;

    final expense = Expense(
      id: expenseId,
      groupId: groupId,
      payerMemberId: payerMemberId,
      description: description,
      amountCents: split.totalCents,
      splitType: split.type,
      date: date,
      updated: current.updated,
      pending: true,
    );
    final entries = [
      for (final s in splits)
        SplitEntry(
          id: newLocalId(),
          expenseId: expenseId,
          memberId: s.memberId,
          amountCents: s.amountCents,
        ),
    ];

    // Captured before the write: the base a conflict is measured against is
    // what the server last told us, not what we are about to store.
    final base = dao.updatedOf(expenseId);

    _db.transaction({'expenses', 'split_entries', 'outbox'}, () {
      dao.upsertExpense(expense, entries, pending: true);
      OutboxDao(_db).enqueue(
        op: OutboxOps.expenseUpdate,
        recordId: expenseId,
        payload: _createPayload(expense, entries),
        baseUpdated: base,
      );
    });

    await _ledger.recompute(groupId);
    _sync.wake();
    return expense;
  }

  Future<void> deleteExpense(String expenseId) async {
    final dao = ExpenseDao(_db);
    final current = dao.byId(expenseId);
    // Already gone locally: nothing to delete and nothing to queue.
    if (current == null) return;
    final groupId = current.groupId;
    final base = dao.updatedOf(expenseId);

    _db.transaction({'expenses', 'split_entries', 'outbox'}, () {
      dao.deleteExpense(expenseId);
      OutboxDao(_db).enqueue(
        op: OutboxOps.expenseDelete,
        recordId: expenseId,
        payload: const {},
        baseUpdated: base,
      );
    });

    await _ledger.recompute(groupId);
    _sync.wake();
  }

  /// Public URL for a split entry's attached receipt image, or null when no
  /// receipt is attached. Remote by nature — an image is not mirrored into
  /// the local database.
  String? receiptUrl(SplitEntry entry) => _api.receiptUrl(entry);

  /// Queues a receipt by **path**, not by bytes: the outbox stays a table of
  /// small rows instead of becoming a blob store. If the file is gone by the
  /// time the op is replayed, the expense still syncs and the caller is told
  /// the image was lost — an expense is not held hostage to a photo the OS
  /// cleaned up.
  Future<void> attachReceiptFile(String splitEntryId, String imagePath) async {
    _db.transaction({'outbox'}, () {
      OutboxDao(_db).enqueue(
        op: OutboxOps.receiptAttach,
        recordId: splitEntryId,
        payload: const {},
        receiptPath: imagePath,
      );
    });
    _sync.wake();
  }

  /// Immediate upload, for callers that already hold the bytes and are
  /// online. Offline callers want [attachReceiptFile].
  Future<SplitEntry> attachReceipt(String splitEntryId, Uint8List imageBytes) async {
    final entry = await _api.attachReceipt(splitEntryId, imageBytes);
    await _sync.now();
    return entry;
  }

  /// The expense and its entries in one payload, so replay calls
  /// ExpensesApi and inherits the compensating delete that unwinds a
  /// half-written expense.
  Map<String, Object?> _createPayload(Expense expense, List<SplitEntry> entries) => {
    'groupId': expense.groupId,
    'payerMemberId': expense.payerMemberId,
    'description': expense.description,
    'amountCents': expense.amountCents,
    'splitType': expense.splitType,
    'date': expense.date.toUtc().toIso8601String(),
    'splits': [
      for (final e in entries) {'id': e.id, 'memberId': e.memberId, 'amountCents': e.amountCents},
    ],
  };
}
