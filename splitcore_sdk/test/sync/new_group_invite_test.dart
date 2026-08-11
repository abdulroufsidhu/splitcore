// Reproduces the "members invited while creating a group do not show up
// until an unrelated expense is added" report, at the level the app hits it:
// the local mirror the group screens actually read from.
import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import '../support/lib_path.dart';
import '../support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  /// Signs up a throwaway account on its own SDK, so the email exists and
  /// /api/splitcore/invite takes the "add immediately" branch rather than
  /// parking a pending invite.
  Future<String> makeUser(String tag) async {
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
    );
    final email = '$tag-${DateTime.now().microsecondsSinceEpoch}@example.com';
    await sdk.auth.signUp(email: email, password: 'password123');
    await sdk.close();
    return email;
  }

  test('a member invited right after createGroup lands in the local mirror', () async {
    final friendEmail = await makeUser('invitee');

    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
    );
    addTearDown(sdk.close);
    await sdk.auth.signUp(
      email: 'owner-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );

    // Exactly what NewGroupScreen._create does.
    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    final added = await sdk.groups.inviteOrAddMember(groupId: group.id, email: friendEmail);
    expect(added, isTrue, reason: 'the invitee already has an account');

    final local = await sdk.groups.listMembers(group.id);
    expect(
      local.map((m) => m.userId).toSet(),
      hasLength(2),
      reason: 'owner + invitee should both be in the local mirror, with no expense added',
    );
  });
}
