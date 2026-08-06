import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

import 'support/lib_path.dart';
import 'support/pb_server.dart';

void main() {
  late PbTestServer server;

  setUpAll(() async {
    server = await PbTestServer.start();
    addTearDown(server.stop);
  });

  test(
    'end-to-end: sign up, create group, create expense, read balances, settle up, settle',
    () async {
      final sdk = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
      );

      final ownerEmail = 'sdk-owner-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final owner = await sdk.auth.signUp(email: ownerEmail, password: 'password123');
      final group = await sdk.groups.createGroup(name: 'End to end', currency: 'USD');

      final friendSdk = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
      );
      final friendEmail = 'sdk-friend-${DateTime.now().microsecondsSinceEpoch}@example.com';
      final friend = await friendSdk.auth.signUp(email: friendEmail, password: 'password123');

      final members = await sdk.groups.listMembers(group.id);
      final ownerMember = members.firstWhere((m) => m.userId == owner.id);
      final friendMember = await sdk.groups.addMember(
        groupId: group.id,
        userId: friend.id,
        role: 'member',
      );

      await sdk.expenses.createExpense(
        groupId: group.id,
        payerMemberId: ownerMember.id,
        description: 'Lunch',
        date: DateTime.utc(2026, 7, 1),
        split: SplitSpec.equal(totalCents: 2000, memberIds: [ownerMember.id, friendMember.id]),
      );

      // Local rows, not a fetch: the writes above each ran a pull, so the
      // balances the app renders come out of the local database.
      final balances = await sdk.balances.get(group.id);
      expect(balances.fold<int>(0, (sum, b) => sum + b.netCents), 0);

      final transfers = await sdk.settleUp(balances);
      expect(transfers, hasLength(1));
      expect(transfers.single.fromMemberId, friendMember.id);
      expect(transfers.single.toMemberId, ownerMember.id);
      expect(transfers.single.amountCents, 1000);

      final settlement = await sdk.settlements.createSettlement(
        groupId: group.id,
        fromMemberId: transfers.single.fromMemberId,
        toMemberId: transfers.single.toMemberId,
        amountCents: transfers.single.amountCents,
      );

      expect(settlement.amountCents, 1000);
    },
  );

  test('previewSplit computes an equal split without writing anything', () async {
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
    );
    await sdk.auth.signUp(
      email: 'preview-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );

    final splits = await sdk.previewSplit(
      SplitSpec.equal(totalCents: 1000, memberIds: ['m1', 'm2', 'm3']),
    );

    expect(splits.fold<int>(0, (sum, s) => sum + s.amountCents), 1000);
    expect(splits, hasLength(3));
  });
}
