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

class SyncFailed extends SyncEvent {
  const SyncFailed(this.error);

  final Object error;

  @override
  String toString() => 'SyncFailed($error)';
}
