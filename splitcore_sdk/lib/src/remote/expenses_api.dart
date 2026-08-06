// Wraps `expenses` + `split_entries`. Split math is computed locally via
// SplitcoreCalc (same engine the server uses for validation) before any
// records are written, so the server's per-entry validation is a
// consistency check, not the source of the split amounts.
import 'dart:typed_data';

import 'package:pocketbase/pocketbase.dart';

import '../calc_api.dart';
import '../local/ids.dart';
import '../models.dart';
import 'filters.dart';
import 'receipts.dart' as receipts;

class ExpensesApi {
  ExpensesApi(this._pb, this._calc);

  final PocketBase _pb;
  final SplitcoreCalc _calc;

  Future<Expense> createExpense({
    required String groupId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    final splits = await _calc.computeSplits(split);

    final expenseRecord = await _pb
        .collection('expenses')
        .create(
          body: {
            'group': groupId,
            'payer': payerMemberId,
            'description': description,
            'amount_cents': split.totalCents,
            'split_type': split.type,
            'date': date.toIso8601String(),
          },
        );

    // PocketBase gives the client no multi-record transaction, so an
    // expense and its split entries cannot be written in one shot. Without
    // compensation, a failure partway through the loop leaves an expense
    // whose splits do not sum to its total — the server then permanently
    // skips it during balance recompute (see server/hooks/recompute.go),
    // so it shows in the list, counts for nothing, and can only be removed
    // by hand. Deleting the parent unwinds the whole write: split_entries
    // cascade off expenses.
    try {
      for (final s in splits) {
        await _pb
            .collection('split_entries')
            .create(
              body: {
                // Client-minted, like the expense's own id: every local
                // reference to this entry — a queued receipt upload, most of
                // all — has to survive the round trip.
                'id': newLocalId(),
                'expense': expenseRecord.id,
                'member': s.memberId,
                'amount_cents': s.amountCents,
              },
            );
      }
    } catch (_) {
      // Best-effort: if the rollback itself fails (server unreachable),
      // rethrow the original failure — it is the one the caller can act on.
      try {
        await _pb.collection('expenses').delete(expenseRecord.id);
      } catch (_) {}
      rethrow;
    }

    return _expenseFromRecord(expenseRecord);
  }

  /// Replays a locally-created expense, keeping the id it was minted with.
  ///
  /// Splits are passed in rather than recomputed: they were computed by the
  /// same Go engine when the write happened offline, and recomputing here
  /// would silently substitute a different answer if the spec were
  /// reinterpreted. The rollback below is the same one createExpense uses.
  Future<Expense> createExpenseWithId({
    required String id,
    required String groupId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required int amountCents,
    required String splitType,
    required List<SplitEntry> splits,
  }) async {
    final expenseRecord = await _pb
        .collection('expenses')
        .create(
          body: {
            'id': id,
            'group': groupId,
            'payer': payerMemberId,
            'description': description,
            'amount_cents': amountCents,
            'split_type': splitType,
            'date': date.toIso8601String(),
          },
        );

    try {
      for (final s in splits) {
        await _pb
            .collection('split_entries')
            .create(
              body: {
                // Client-minted, like the expense's own id. Without it the
                // server assigns its own and every local reference to this
                // entry — a queued receipt upload, most of all — points at a
                // row that does not exist.
                'id': s.id,
                'expense': expenseRecord.id,
                'member': s.memberId,
                'amount_cents': s.amountCents,
              },
            );
      }
    } catch (_) {
      try {
        await _pb.collection('expenses').delete(expenseRecord.id);
      } catch (_) {}
      rethrow;
    }

    return _expenseFromRecord(expenseRecord);
  }

  /// Replays a locally-made edit with splits already computed. See
  /// [updateExpense] for why the entries are deleted before the new ones are
  /// written.
  Future<Expense> replaceExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required int amountCents,
    required String splitType,
    required List<SplitEntry> splits,
  }) async {
    final existing = await _pb
        .collection('split_entries')
        .getFullList(batch: 200, filter: byExpense(_pb, expenseId));

    final record = await _pb
        .collection('expenses')
        .update(
          expenseId,
          body: {
            'payer': payerMemberId,
            'description': description,
            'amount_cents': amountCents,
            'split_type': splitType,
            'date': date.toIso8601String(),
          },
        );

    for (final entry in existing) {
      await _pb.collection('split_entries').delete(entry.id);
    }
    for (final s in splits) {
      await _pb
          .collection('split_entries')
          .create(
            body: {
              'id': s.id,
              'expense': expenseId,
              'member': s.memberId,
              'amount_cents': s.amountCents,
            },
          );
    }

    return _expenseFromRecord(record);
  }

  /// The server's current `updated` stamp for [expenseId], as the raw string
  /// it sent — the value a queued edit's conflict base is compared against.
  Future<String?> updatedOf(String expenseId) async {
    final record = await _pb.collection('expenses').getOne(expenseId);
    final value = record.getStringValue('updated');
    return value.isEmpty ? null : value;
  }

  /// Rewrites an existing expense and replaces its split entries wholesale.
  ///
  /// The group is never changed — the server rejects re-parenting outright
  /// (`server/hooks/hooks.go`, rejectGroupReparent), because moving an
  /// expense between groups would leave the old group's cached balances
  /// stale.
  ///
  /// Old entries are deleted before new ones are written. Between the two,
  /// the expense's splits do not sum to its total, so the server's
  /// recompute skips it entirely (the incomplete-expense rule in
  /// server/README.md) — balances briefly omit this expense rather than
  /// ever counting it twice.
  Future<Expense> updateExpense({
    required String expenseId,
    required String payerMemberId,
    required String description,
    required DateTime date,
    required SplitSpec split,
  }) async {
    // Compute before touching anything: a rejected SplitSpec must fail
    // without having modified the stored expense at all.
    final splits = await _calc.computeSplits(split);

    final existing = await _pb
        .collection('split_entries')
        .getFullList(batch: 200, filter: byExpense(_pb, expenseId));

    final record = await _pb
        .collection('expenses')
        .update(
          expenseId,
          body: {
            'payer': payerMemberId,
            'description': description,
            'amount_cents': split.totalCents,
            'split_type': split.type,
            'date': date.toIso8601String(),
          },
        );

    for (final entry in existing) {
      await _pb.collection('split_entries').delete(entry.id);
    }
    for (final s in splits) {
      await _pb
          .collection('split_entries')
          .create(
            body: {
              'id': newLocalId(),
              'expense': expenseId,
              'member': s.memberId,
              'amount_cents': s.amountCents,
            },
          );
    }

    return _expenseFromRecord(record);
  }

  /// One page of a group's expenses, newest first — powers the group-detail
  /// list. Paged rather than exhaustive: an active group accumulates
  /// thousands of expenses and a screen shows a dozen.
  Future<Page<Expense>> listExpenses(String groupId, {int page = 1, int perPage = 50}) async {
    final result = await _pb
        .collection('expenses')
        .getList(page: page, perPage: perPage, filter: byGroup(_pb, groupId), sort: '-date');
    return _pageFrom(result);
  }

  /// Expenses in [groupId] whose description contains [query]
  /// (case-insensitive — PocketBase's `~` operator). An empty [query]
  /// degrades to a plain listing rather than matching everything twice.
  Future<Page<Expense>> searchExpenses(
    String groupId,
    String query, {
    int page = 1,
    int perPage = 50,
  }) async {
    if (query.trim().isEmpty) return listExpenses(groupId, page: page, perPage: perPage);
    final result = await _pb
        .collection('expenses')
        .getList(
          page: page,
          perPage: perPage,
          // query is user input — it MUST go through pb.filter, never into
          // the expression by interpolation.
          filter: _pb.filter('group = {:g} && description ~ {:q}', {'g': groupId, 'q': query}),
          sort: '-date',
        );
    return _pageFrom(result);
  }

  /// Every expense in the group. Only for callers that genuinely need the
  /// full set — balance recomputation and export — never for rendering.
  Future<List<Expense>> listAllExpenses(String groupId) async {
    final records = await _pb
        .collection('expenses')
        .getFullList(batch: 200, filter: byGroup(_pb, groupId), sort: '-date');
    return [for (final r in records) _expenseFromRecord(r)];
  }

  Page<Expense> _pageFrom(ResultList<RecordModel> result) => Page<Expense>(
    items: [for (final r in result.items) _expenseFromRecord(r)],
    page: result.page,
    perPage: result.perPage,
    totalItems: result.totalItems,
    totalPages: result.totalPages,
  );

  Future<List<SplitEntry>> listSplitEntries(String expenseId) async {
    final records = await _pb
        .collection('split_entries')
        .getFullList(filter: byExpense(_pb, expenseId));
    return [for (final r in records) _splitEntryFromRecord(r)];
  }

  Future<void> deleteExpense(String expenseId) => _pb.collection('expenses').delete(expenseId);

  /// Public URL for a split entry's attached receipt image (PocketBase's
  /// standard `/api/files/{collection}/{id}/{filename}` scheme), or null if
  /// no receipt is attached. Keeps the frontend from needing to know
  /// PocketBase's URL scheme or hold a PocketBase client itself.
  String? receiptUrl(SplitEntry entry) {
    final filename = entry.receiptFilename;
    if (filename == null) return null;
    return '${_pb.baseURL}/api/files/split_entries/${entry.id}/$filename';
  }

  /// Compresses [imageBytes] (downscale + JPEG re-encode) and attaches the
  /// result to the given split_entries row's receipt field.
  Future<SplitEntry> attachReceipt(String splitEntryId, Uint8List imageBytes) =>
      receipts.attachReceipt(
        _pb,
        splitEntryId: splitEntryId,
        jpegBytes: receipts.compressReceipt(imageBytes),
      );

  Expense _expenseFromRecord(RecordModel record) => Expense(
    id: record.id,
    groupId: record.getStringValue('group'),
    payerMemberId: record.getStringValue('payer'),
    description: record.getStringValue('description'),
    amountCents: record.getIntValue('amount_cents'),
    splitType: record.getStringValue('split_type'),
    date: DateTime.parse(record.getStringValue('date')),
    updated: DateTime.tryParse(record.getStringValue('updated')),
  );

  SplitEntry _splitEntryFromRecord(RecordModel record) => SplitEntry(
    id: record.id,
    expenseId: record.getStringValue('expense'),
    memberId: record.getStringValue('member'),
    amountCents: record.getIntValue('amount_cents'),
    receiptFilename: record.getStringValue('receipt').isEmpty
        ? null
        : record.getStringValue('receipt'),
  );
}
