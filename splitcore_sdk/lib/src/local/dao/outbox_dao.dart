// The queue of writes waiting for the server.
//
// Like every DAO here, the writes assume the caller already opened a
// transaction — an op is inserted in the same commit as the rows it
// describes, so the two can never disagree about whether a write happened.
import 'dart:convert';

import '../../sync/outbox_op.dart';
import '../database.dart';

class OutboxDao {
  OutboxDao(this._db);

  final SplitcoreDb _db;

  /// Queues an op and returns its seq.
  int enqueue({
    required String op,
    required String recordId,
    required Map<String, Object?> payload,
    String? baseUpdated,
    String? receiptPath,
  }) {
    _db.raw.execute(
      '''
      INSERT INTO outbox (op, record_id, payload, base_updated, receipt_path, created_at)
      VALUES (?, ?, ?, ?, ?, ?)
      ''',
      [
        op,
        recordId,
        jsonEncode(payload),
        baseUpdated,
        receiptPath,
        DateTime.now().toUtc().toIso8601String(),
      ],
    );
    return _db.raw.lastInsertRowId;
  }

  /// Everything still waiting to be sent, oldest first. Parked ops are
  /// excluded: they must not block the queue behind them, and replaying one
  /// is what the resolution API is for.
  List<OutboxOp> pending() => _select("state = 'pending'");

  List<OutboxOp> conflicts() => _select("state = 'conflict'");

  List<OutboxOp> failed() => _select("state = 'failed'");

  OutboxOp? bySeq(int seq) {
    final rows = _select('seq = ?', [seq]);
    return rows.isEmpty ? null : rows.first;
  }

  /// The records with an unsent op behind them — what the UI greys.
  Set<String> pendingRecordIds() => {
    for (final row in _db.raw.select("SELECT record_id FROM outbox WHERE state = 'pending'"))
      row['record_id'] as String,
  };

  void delete(int seq) => _db.raw.execute('DELETE FROM outbox WHERE seq = ?', [seq]);

  /// Drops every op for a record whatever its state — used when a conflict
  /// is resolved in the server's favour and the local edits are abandoned.
  void deleteFor(String recordId) =>
      _db.raw.execute('DELETE FROM outbox WHERE record_id = ?', [recordId]);

  /// A transient failure: the op stays queued and keeps its place.
  void recordAttempt(int seq, String error) => _db.raw.execute(
    'UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE seq = ?',
    [error, seq],
  );

  /// Parks [seq] and every op queued after it for the same record. The later
  /// ops were built on top of this one, so replaying them would apply an
  /// edit to a base the user never saw.
  void markConflict(int seq, String error) => _db.raw.execute(
    '''
    UPDATE outbox SET state = 'conflict', last_error = ?
    WHERE seq >= ? AND record_id = (SELECT record_id FROM outbox WHERE seq = ?)
    ''',
    [error, seq, seq],
  );

  /// The server rejected this op outright — a validation error replay will
  /// never fix. Parked rather than dropped: silently discarding a write the
  /// user made is how a ledger loses an expense.
  void markFailed(int seq, String error) => _db.raw.execute(
    "UPDATE outbox SET state = 'failed', last_error = ? WHERE seq = ?",
    [error, seq],
  );

  /// Re-queues a parked op against a new base — the "keep my version"
  /// resolution.
  void requeue(int seq, String? baseUpdated) => _db.raw.execute(
    "UPDATE outbox SET state = 'pending', base_updated = ?, last_error = NULL WHERE seq = ?",
    [baseUpdated, seq],
  );

  List<OutboxOp> _select(String where, [List<Object?> params = const []]) => _db.raw
      .select('SELECT * FROM outbox WHERE $where ORDER BY seq', params)
      .map(
        (r) => OutboxOp(
          seq: r['seq'] as int,
          op: r['op'] as String,
          recordId: r['record_id'] as String,
          payload: jsonDecode(r['payload'] as String) as Map<String, Object?>,
          baseUpdated: r['base_updated'] as String?,
          receiptPath: r['receipt_path'] as String?,
          state: r['state'] as String,
          attempts: r['attempts'] as int,
          lastError: r['last_error'] as String?,
        ),
      )
      .toList();
}
