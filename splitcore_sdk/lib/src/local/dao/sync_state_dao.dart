// The per-group pull cursor. `version` is the server's group version as of
// the last successful pull — the value handed to /api/splitcore/staleness
// to ask "did anything change?" in O(1).
import '../database.dart';

class SyncStateDao {
  SyncStateDao(this._db);

  final SplitcoreDb _db;

  /// -1 for a group never synced. Not 0: the server's staleness check is a
  /// plain `clientVersion == serverVersion`, and a freshly created group is
  /// version 0 there — so a 0 sentinel reports "current" and the very first
  /// pull skips the group, leaving it with no members or expenses locally.
  /// -1 is below every real version, so the first check always pulls.
  int versionOf(String groupId) {
    final rows = _db.raw.select('SELECT version FROM sync_state WHERE group_id = ?', [groupId]);
    return rows.isEmpty ? -1 : rows.first['version'] as int;
  }

  DateTime? syncedAt(String groupId) {
    final rows = _db.raw.select('SELECT synced_at FROM sync_state WHERE group_id = ?', [groupId]);
    if (rows.isEmpty) return null;
    final value = rows.first['synced_at'] as String?;
    return value == null ? null : DateTime.parse(value);
  }

  void markSynced(String groupId, int version) {
    _db.raw.execute(
      '''
      INSERT INTO sync_state (group_id, version, synced_at) VALUES (?, ?, ?)
      ON CONFLICT(group_id) DO UPDATE SET
        version = excluded.version,
        synced_at = excluded.synced_at
      ''',
      [groupId, version, DateTime.now().toUtc().toIso8601String()],
    );
  }
}
