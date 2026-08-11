// The public read path for groups: local rows, re-emitted when sync writes.
//
// Writes still go straight to the server and then ask the engine to pull,
// so the local database catches up. The outbox makes them local-first.
import '../local/dao/group_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/groups_api.dart';
import '../sync/sync_engine.dart';

/// Thrown when an action cannot be judged safely because local writes have
/// not reached the server yet.
///
/// The server decides what a removal means from what it can see, and it
/// cannot see the outbox — so unsent work has to land first.
class UnsyncedWritesException implements Exception {
  const UnsyncedWritesException(this.count);

  /// How many outbox entries are still unsettled.
  final int count;

  @override
  String toString() => 'UnsyncedWritesException: $count change(s) have not reached the server yet';
}

class GroupsRepository {
  GroupsRepository(this._db, this._api, this._sync);

  final SplitcoreDb _db;
  final GroupsApi _api;
  final SyncEngine _sync;

  Stream<List<Group>> watchGroups() => _db.watch({'groups'}, () => GroupDao(_db).listGroups());

  Stream<List<GroupMember>> watchMembers(String groupId) =>
      _db.watch({'members'}, () => GroupDao(_db).listMembers(groupId));

  /// Like [watchMembers], but includes members the owner has removed. Only
  /// the group screen's "former members" line needs these.
  Stream<List<GroupMember>> watchAllMembers(String groupId) =>
      _db.watch({'members'}, () => GroupDao(_db).listAllMembers(groupId));

  Stream<Group?> watchGroup(String groupId) => _db.watch({'groups'}, () => _groupOrNull(groupId));

  /// The current member list, for callers that want one value rather than a
  /// subscription — the export path, and tests. Removed members are left
  /// out: every caller means "who is in this group now".
  Future<List<GroupMember>> listMembers(String groupId) async => GroupDao(_db).listMembers(groupId);

  /// Everyone who has ever been in the group, removed members included.
  Future<List<GroupMember>> listAllMembers(String groupId) async =>
      GroupDao(_db).listAllMembers(groupId);

  /// The groups the signed-in user belongs to, from the local mirror.
  Future<List<Group>> listMyGroups() async => GroupDao(_db).listGroups();

  /// Null when the group is not in the local mirror — either it was never
  /// synced or the user was removed from it. Callers render "not found"
  /// rather than hanging on a request that cannot succeed offline.
  Future<Group?> getGroup(String groupId) async => _groupOrNull(groupId);

  Group? _groupOrNull(String groupId) {
    for (final g in GroupDao(_db).listGroups()) {
      if (g.id == groupId) return g;
    }
    return null;
  }

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

  /// Removes [memberId] from their group and returns what the server did —
  /// `'removed'` (row deleted) or `'deactivated'` (row kept, marked). See
  /// [GroupsApi.removeMember] for when each happens and what it throws.
  ///
  /// Drains the outbox first, and throws [UnsyncedWritesException] if it
  /// cannot be drained. This ordering is load-bearing, not tidiness: the
  /// server decides between deleting the row and merely marking it from the
  /// history it can see, and it cannot see the outbox. An expense queued
  /// offline that splits with this member makes them look like someone with
  /// no history and nothing owed, so their row is deleted outright — and
  /// then the queued write replays against a member id that no longer
  /// exists, is rejected, and the expense is lost from the server and the
  /// device both. Draining first means the server judges the real state:
  /// the member turns out to have history (so the row is kept) or an
  /// outstanding balance (so the removal is refused).
  ///
  /// Online-only, like [inviteOrAddMember].
  Future<String> removeMember(String memberId) async {
    await _sync.now();
    // Queued ops will be applied, and a parked conflict will be too if the
    // user keeps their version — either can reference the member being
    // removed. Ops the server already rejected are left out on purpose:
    // nothing ever replays them, so they cannot resurrect a deleted member,
    // and counting them would let one stuck failure block every removal in
    // the group forever.
    final unsent = (await _sync.queued()).length + (await _sync.conflicts()).length;
    if (unsent > 0) throw UnsyncedWritesException(unsent);

    final status = await _api.removeMember(memberId);
    await _sync.now();
    return status;
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
