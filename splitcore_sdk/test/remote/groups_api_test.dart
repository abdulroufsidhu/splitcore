import 'package:pocketbase/pocketbase.dart';
import 'package:splitcore_sdk/src/remote/auth_api.dart';
import 'package:splitcore_sdk/src/remote/groups_api.dart';
import 'package:splitcore_sdk/src/models.dart';
import 'package:test/test.dart';

import '../support/pb_server.dart';

void main() {
  late PbTestServer server;
  late PocketBase pb;
  late AuthApi auth;
  late GroupsApi groups;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  setUp(() async {
    pb = PocketBase(server.baseUrl);
    auth = AuthApi(pb);
    groups = GroupsApi(pb);
    await auth.signUp(email: 'owner-${DateTime.now().microsecondsSinceEpoch}@example.com', password: 'password123');
  });

  test('createGroup sets owner from the authenticated user and starts at version 0', () async {
    final owner = auth.currentUser!;

    final group = await groups.createGroup(name: 'Trip to Goa', currency: 'INR');

    expect(group.name, 'Trip to Goa');
    expect(group.currency, 'INR');
    expect(group.version, 0);
    expect(group.ownerId, owner.id);
  });

  test('createGroup auto-creates an owner group_members row', () async {
    final owner = auth.currentUser!;
    final group = await groups.createGroup(name: 'Roommates', currency: 'USD');

    final members = await groups.listMembers(group.id);

    expect(members, [
      isA<GroupMember>()
          .having((m) => m.userId, 'userId', owner.id)
          .having((m) => m.role, 'role', 'owner'),
    ]);
  });

  test('listMyGroups returns only groups the current user is a member of', () async {
    final group = await groups.createGroup(name: 'Solo group', currency: 'EUR');

    final myGroups = await groups.listMyGroups();

    expect(myGroups.map((g) => g.id), contains(group.id));
  });

  test('addMember adds another user as a member of the group', () async {
    final group = await groups.createGroup(name: 'Shared flat', currency: 'GBP');
    final other = await AuthApi(PocketBase(server.baseUrl))
        .signUp(email: 'member-${DateTime.now().microsecondsSinceEpoch}@example.com', password: 'password123');

    final member = await groups.addMember(groupId: group.id, userId: other.id, role: 'member');

    expect(member.userId, other.id);
    expect(member.role, 'member');
    final members = await groups.listMembers(group.id);
    expect(members.map((m) => m.userId), contains(other.id));
  });
}
