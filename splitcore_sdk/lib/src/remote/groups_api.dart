// Wraps the `groups` and `group_members` collections. `owner` and
// `version` on groups are hook-managed server-side (see
// server/hooks/hooks.go OnRecordCreateRequest("groups")); this layer never
// sets them on create.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

class GroupsApi {
  GroupsApi(this._pb);

  final PocketBase _pb;

  Future<Group> createGroup({required String name, required String currency}) async {
    final record = await _pb.collection('groups').create(
      body: {'name': name, 'currency': currency},
    );
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

  Future<List<GroupMember>> listMembers(String groupId) async {
    final records = await _pb
        .collection('group_members')
        .getFullList(filter: "group = '$groupId'");
    return [for (final r in records) _memberFromRecord(r)];
  }

  Future<GroupMember> addMember({
    required String groupId,
    required String userId,
    required String role,
  }) async {
    final record = await _pb.collection('group_members').create(
      body: {'group': groupId, 'user': userId, 'role': role},
    );
    return _memberFromRecord(record);
  }

  Future<void> removeMember(String memberId) => _pb.collection('group_members').delete(memberId);

  Group _groupFromRecord(RecordModel record) => Group(
        id: record.id,
        name: record.getStringValue('name'),
        currency: record.getStringValue('currency'),
        version: record.getIntValue('version'),
        ownerId: record.getStringValue('owner'),
      );

  GroupMember _memberFromRecord(RecordModel record) => GroupMember(
        id: record.id,
        groupId: record.getStringValue('group'),
        userId: record.getStringValue('user'),
        role: record.getStringValue('role'),
      );
}
