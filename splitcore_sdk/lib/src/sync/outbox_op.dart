// One queued write, waiting for the server.
//
// Ops are named after SDK operations rather than raw collections. That is
// deliberate: `expense.create` carries the expense *and* its split entries
// as one payload, so replaying it calls ExpensesApi.createExpense and
// inherits the compensating delete that unwinds a half-written expense.
// A per-collection op would need that rollback reimplemented here, and an
// expense whose splits do not sum to its total is skipped by the server's
// recompute forever — visible in the list, counting for nothing.
class OutboxOp {
  const OutboxOp({
    required this.seq,
    required this.op,
    required this.recordId,
    required this.payload,
    required this.state,
    required this.attempts,
    this.baseUpdated,
    this.receiptPath,
    this.lastError,
  });

  /// Monotonic, and the drain order. An update must never overtake the
  /// create it depends on.
  final int seq;

  /// One of the constants in [OutboxOps].
  final String op;

  /// The record this op targets. Ops for the same record share a fate: if
  /// one conflicts, the ones queued behind it were built on a base the user
  /// never saw, so they conflict too.
  final String recordId;

  final Map<String, Object?> payload;

  /// The server's `updated` stamp this op was built on, or null for a
  /// create (nothing to conflict with). If the server's stamp has moved by
  /// replay time, somebody else edited the record.
  final String? baseUpdated;

  /// Path to a receipt image on this device. The bytes are not copied into
  /// the queue — if the file is gone by replay time the row still syncs and
  /// the caller is told the image was lost.
  final String? receiptPath;

  /// `pending` | `conflict` | `failed`.
  final String state;

  final int attempts;
  final String? lastError;
}

/// The op names. Constants rather than an enum because they are persisted:
/// a database written by an older build must still be readable, and an enum
/// index shifts the moment someone reorders the declaration.
abstract final class OutboxOps {
  static const expenseCreate = 'expense.create';
  static const expenseUpdate = 'expense.update';
  static const expenseDelete = 'expense.delete';
  static const settlementCreate = 'settlement.create';
  static const groupCreate = 'group.create';
  static const memberInvite = 'member.invite';
  static const memberRemove = 'member.remove';
  static const receiptAttach = 'receipt.attach';
}
