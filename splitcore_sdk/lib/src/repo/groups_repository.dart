// The public read path for groups: local rows, re-emitted when sync writes.
//
// Writes still go straight to the server and then ask the engine to pull,
// so the local database catches up. The outbox makes them local-first.
import '../local/dao/group_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/groups_api.dart';
import '../sync/sync_engine.dart';

class GroupsRepository {
  GroupsRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final GroupsApi _api;
  final SyncEngine _sync;

  Stream<List<Group>> watchGroups() => _db.watch({'groups'}, () => GroupDao(_db).listGroups());

  Stream<List<GroupMember>> watchMembers(String groupId) =>
      _db.watch({'members'}, () => GroupDao(_db).listMembers(groupId));

  /// The current member list, for callers that want one value rather than a
  /// subscription — the export path, and tests.
  Future<List<GroupMember>> listMembers(String groupId) async => GroupDao(_db).listMembers(groupId);

  Future<Group> createGroup({
    required String name,
    required String currency,
    bool isDirect = false,
  }) async {
    final group = await _api.createGroup(name: name, currency: currency, isDirect: isDirect);
    await _sync.now();
    return group;
  }

  Future<GroupMember> addMember({
    required String groupId,
    required String userId,
    required String role,
  }) async {
    final member = await _api.addMember(groupId: groupId, userId: userId, role: role);
    await _sync.now();
    return member;
  }

  Future<void> removeMember(String memberId) async {
    await _api.removeMember(memberId);
    await _sync.now();
  }

  Future<bool> inviteOrAddMember({
    required String groupId,
    required String email,
    String role = 'member',
  }) async {
    final added = await _api.inviteOrAddMember(groupId: groupId, email: email, role: role);
    await _sync.now();
    return added;
  }
}
