// Wraps `expenses` + `split_entries`. Split math is computed locally via
// SplitcoreCalc (same engine the server uses for validation) before any
// records are written, so the server's per-entry validation is a
// consistency check, not the source of the split amounts.
import 'dart:typed_data';

import 'package:pocketbase/pocketbase.dart';

import '../calc_api.dart';
import '../models.dart';
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

    for (final s in splits) {
      await _pb
          .collection('split_entries')
          .create(
            body: {
              'expense': expenseRecord.id,
              'member': s.memberId,
              'amount_cents': s.amountCents,
            },
          );
    }

    return _expenseFromRecord(expenseRecord);
  }

  /// A group's expenses, newest first — powers the group-detail expense list.
  Future<List<Expense>> listExpenses(String groupId) async {
    final records = await _pb
        .collection('expenses')
        .getFullList(filter: "group = '$groupId'", sort: '-date');
    return [for (final r in records) _expenseFromRecord(r)];
  }

  Future<List<SplitEntry>> listSplitEntries(String expenseId) async {
    final records = await _pb
        .collection('split_entries')
        .getFullList(filter: "expense = '$expenseId'");
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
