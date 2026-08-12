// Wraps the `groups` and `group_members` collections. `owner` and
// `version` on groups are hook-managed server-side (see
// server/hooks/hooks.go OnRecordCreateRequest("groups")); this layer never
// sets them on create.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

class GroupsApi {
  GroupsApi(this._pb);

  final PocketBase _pb;

  Future<Group> createGroup({
    required String name,
    required String currency,
    bool isDirect = false,
  }) async {
    final record = await _pb
        .collection('groups')
        .create(body: {'name': name, 'currency': currency, 'is_direct': isDirect});
    return _groupFromRecord(record);
  }

  Future<List<Group>> listMyGroups() async {
    final records = await _pb.collection('groups').getFullList();
    return [for (final r in records) _groupFromRecord(r)];
  }

  Future<Group> getGroup(String groupId) async {
    final record = await _pb.collection('groups').getOne(groupId);
    return _groupFromRecord(record);
  }

  /// Lists members with their name/avatar resolved server-side — PocketBase's
  /// default `users` rules block reading anyone else's record directly, so
  /// this goes through /api/splitcore/members instead of the `group_members`
  /// collection (see server/hooks/members.go).
  Future<List<GroupMember>> listMembers(String groupId) async {
    final res = await _pb.send<List<dynamic>>(
      '/api/splitcore/members',
      query: {'group_id': groupId},
    );
    return [
      for (final m in res.cast<Map<String, dynamic>>())
        GroupMember(
          id: m['id'] as String? ?? '',
          groupId: groupId,
          userId: m['user'] as String? ?? '',
          role: m['role'] as String? ?? 'member',
          name: m['name'] as String? ?? '',
          avatarUrl: _avatarUrl(m['user'] as String? ?? '', m['avatar'] as String? ?? ''),
          isActive: (m['removed_at'] as String? ?? '').isEmpty,
        ),
    ];
  }

  String _avatarUrl(String userId, String filename) =>
      filename.isEmpty ? '' : _pb.buildURL('/api/files/users/$userId/$filename').toString();

  Future<GroupMember> addMember({
    required String groupId,
    required String userId,
    required String role,
  }) async {
    final record = await _pb
        .collection('group_members')
        .create(body: {'group': groupId, 'user': userId, 'role': role});
    return _memberFromRecord(record);
  }

  /// Takes [memberId] out of their group, and reports what the server
  /// actually did.
  ///
  /// Doubles as "leave this group": naming your own membership is allowed
  /// without owning the group. Same row, same rules, same two outcomes —
  /// only who may ask differs.
  ///
  ///  * `'removed'` — they appear nowhere in the ledger, so the membership
  ///    row was deleted outright and no trace is left.
  ///  * `'deactivated'` — they appear in expenses or settlements, so the row
  ///    had to stay for everyone else's balances to remain correct. They are
  ///    marked removed instead, and drop out of every member list.
  ///
  /// Throws when the server refuses — notably while the member's balance is
  /// non-zero (settle up first), when they are the group's owner (owners
  /// hand a group over or delete it, they do not walk out of it), or when
  /// the caller neither owns the group nor is the member in question. Goes through
  /// /api/splitcore/remove-member rather than a plain delete because that
  /// choice cannot be made client-side (see server/hooks/remove_member.go).
  Future<String> removeMember(String memberId) async {
    final response = await _pb.send<Map<String, dynamic>>(
      '/api/splitcore/remove-member',
      method: 'POST',
      body: {'member_id': memberId},
    );
    return response['status'] as String? ?? 'removed';
  }

  /// Adds [email] to [groupId] if they already have an account, or records
  /// a pending invite that auto-joins them the moment they sign up with
  /// that email — no accept/decline step. Returns true if they were added
  /// immediately, false if an invite was created instead. Caller must own
  /// the group (enforced server-side by /api/splitcore/invite).
  Future<bool> inviteOrAddMember({
    required String groupId,
    required String email,
    String role = 'member',
  }) async {
    final res = await _pb.send<Map<String, dynamic>>(
      '/api/splitcore/invite',
      method: 'POST',
      body: {'group_id': groupId, 'email': email, 'role': role},
    );
    return res['status'] == 'added';
  }

  Group _groupFromRecord(RecordModel record) => Group(
    id: record.id,
    name: record.getStringValue('name'),
    currency: record.getStringValue('currency'),
    version: record.getIntValue('version'),
    ownerId: record.getStringValue('owner'),
    isDirect: record.getBoolValue('is_direct'),
  );

  GroupMember _memberFromRecord(RecordModel record) => GroupMember(
    id: record.id,
    groupId: record.getStringValue('group'),
    userId: record.getStringValue('user'),
    role: record.getStringValue('role'),
  );
}
