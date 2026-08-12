// What the app can observe about syncing. Deliberately small for now:
// per-op conflicts and failures arrive with the outbox.
sealed class SyncEvent {
  const SyncEvent();
}

class SyncStarted extends SyncEvent {
  const SyncStarted();
}

class SyncCompleted extends SyncEvent {
  const SyncCompleted(this.groupsPulled);

  /// How many groups were actually stale and refetched. 0 means the
  /// staleness check found everything current — the common case, and the
  /// reason a reconnect is cheap even with a long history.
  final int groupsPulled;

  @override
  String toString() => 'SyncCompleted(groupsPulled: $groupsPulled)';
}

/// A queued write could not be applied because the record moved on the
/// server after the op was built. Nothing was overwritten; the op is parked
/// until the app resolves it.
class SyncConflict extends SyncEvent {
  const SyncConflict({required this.seq, required this.op, required this.recordId});

  /// Pass to `sync.resolve` to settle it.
  final int seq;
  final String op;
  final String recordId;

  @override
  String toString() => 'SyncConflict(seq: $seq, op: $op, recordId: $recordId)';
}

/// The server rejected a queued write outright — a validation error that
/// replaying will not fix. Parked rather than dropped: silently discarding
/// a write the user made is how a ledger loses an expense.
class SyncOpFailed extends SyncEvent {
  const SyncOpFailed({required this.seq, required this.op, required this.error});

  final int seq;
  final String op;
  final String error;

  @override
  String toString() => 'SyncOpFailed(seq: $seq, op: $op, error: $error)';
}

/// A queued receipt's file was gone by the time it was uploaded. The row it
/// belonged to synced anyway — an expense is not held hostage to a photo
/// the OS cleaned up — but the image is lost.
class ReceiptMissing extends SyncEvent {
  const ReceiptMissing({required this.recordId, required this.path, required this.error});

  final String recordId;
  final String path;
  final Object error;

  @override
  String toString() => 'ReceiptMissing(recordId: $recordId, path: $path)';
}

class SyncFailed extends SyncEvent {
  const SyncFailed(this.error);

  final Object error;

  @override
  String toString() => 'SyncFailed($error)';
}
