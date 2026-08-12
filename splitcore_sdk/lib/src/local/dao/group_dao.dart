// `groups` and `members` rows <-> Group/GroupMember.
//
// Every write here assumes the caller already opened a transaction (see
// SplitcoreDb.transaction) — a pull writes several tables and has to land
// as one commit, so DAOs never open transactions of their own.
import '../../models.dart';
import '../database.dart';

class GroupDao {
  GroupDao(this._db);

  final SplitcoreDb _db;

  void upsertGroups(List<Group> groups) {
    final statement = _db.raw.prepare('''
      INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0)
      ON CONFLICT(id) DO UPDATE SET
        name = excluded.name,
        currency = excluded.currency,
        version = excluded.version,
        owner_id = excluded.owner_id,
        is_direct = excluded.is_direct,
        updated = excluded.updated
    ''');
    try {
      for (final g in groups) {
        statement.execute([
          g.id,
          g.name,
          g.currency,
          g.version,
          g.ownerId,
          g.isDirect ? 1 : 0,
          null,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// Drops any group not in [keepIds] — the server's list is authoritative,
  /// so a group the user was removed from has to disappear locally too.
  void deleteGroupsMissingFrom(Set<String> keepIds) {
    if (keepIds.isEmpty) {
      _db.raw.execute('DELETE FROM groups');
      return;
    }
    final placeholders = List.filled(keepIds.length, '?').join(',');
    _db.raw.execute('DELETE FROM groups WHERE id NOT IN ($placeholders)', keepIds.toList());
  }

  List<Group> listGroups() => _db.raw
      .select('SELECT * FROM groups ORDER BY name COLLATE NOCASE')
      .map(
        (r) => Group(
          id: r['id'] as String,
          name: r['name'] as String,
          currency: r['currency'] as String,
          version: r['version'] as int,
          ownerId: r['owner_id'] as String,
          isDirect: (r['is_direct'] as int) == 1,
        ),
      )
      .toList();

  /// Replaces [groupId]'s member list wholesale — a removed member must not
  /// linger, and the list is small enough that diffing would be more code
  /// than it saves.
  /// Mirrors the whole roster, removed members included — they own past
  /// expenses, so history still has to be able to name them. Filtering is
  /// [listMembers]' job, not storage's.
  void upsertMembers(String groupId, List<GroupMember> members) {
    _db.raw.execute('DELETE FROM members WHERE group_id = ?', [groupId]);
    final statement = _db.raw.prepare('''
      INSERT INTO members
        (id, group_id, user_id, role, name, avatar_url, removed_at, updated, pending)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
    ''');
    try {
      for (final m in members) {
        statement.execute([
          m.id,
          groupId,
          m.userId,
          m.role,
          m.name,
          m.avatarUrl,
          // The stamp itself is the server's; locally only its presence
          // matters, so an active member stores the empty string.
          m.isActive ? '' : 'removed',
          null,
        ]);
      }
    } finally {
      statement.dispose();
    }
  }

  /// The group's current members. Removed members are excluded, because
  /// every caller — split pickers, settle-up, member counts — means "who is
  /// in this group now". [listAllMembers] is the deliberate exception.
  List<GroupMember> listMembers(String groupId) =>
      listAllMembers(groupId).where((m) => m.isActive).toList();

  /// Everyone who has ever been in the group, removed members included.
  /// Only the screen that shows former members should ask for this.
  List<GroupMember> listAllMembers(String groupId) => _db.raw
      .select('SELECT * FROM members WHERE group_id = ? ORDER BY name COLLATE NOCASE', [groupId])
      .map(
        (r) => GroupMember(
          id: r['id'] as String,
          groupId: r['group_id'] as String,
          userId: r['user_id'] as String,
          role: r['role'] as String,
          name: r['name'] as String,
          avatarUrl: r['avatar_url'] as String,
          isActive: (r['removed_at'] as String? ?? '').isEmpty,
        ),
      )
      .toList();
}
