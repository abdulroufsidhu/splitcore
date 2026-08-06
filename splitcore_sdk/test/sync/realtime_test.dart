import 'dart:io';

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

  test(
    'a change made elsewhere arrives without anyone asking for it',
    () async {
      final connectivity = FakeConnectivityMonitor();
      final sdk = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
        connectivity: connectivity,
      );
      addTearDown(sdk.close);
      final email = 'rt-${DateTime.now().microsecondsSinceEpoch}@example.com';
      await sdk.auth.signUp(email: email, password: 'password123');
      final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
      await sdk.sync.now();
      final member = (await sdk.groups.listMembers(group.id)).single;

      // A second device on the same account. Nothing on the first device asks
      // for an update after this point.
      final other = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
        connectivity: FakeConnectivityMonitor(),
      );
      addTearDown(other.close);
      await other.auth.signIn(email: email, password: 'password123');
      await other.sync.now();

      // Wait for the first device's expense list to show the other device's
      // write. No sync.now(), no pull-to-refresh: only the realtime channel
      // can deliver this.
      final arrived = sdk.expenses
          .watch(group.id)
          .firstWhere((expenses) => expenses.any((e) => e.description == 'From the other device'));

      await other.expenses.createExpense(
        groupId: group.id,
        payerMemberId: member.id,
        description: 'From the other device',
        date: DateTime.utc(2026, 8, 6),
        split: SplitSpec.equal(totalCents: 2500, memberIds: [member.id]),
      );
      await other.sync.now();

      await expectLater(arrived.timeout(const Duration(seconds: 20)), completes);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'going offline tears the subscription down rather than retrying it',
    () async {
      final connectivity = FakeConnectivityMonitor();
      final sdk = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
        connectivity: connectivity,
      );
      addTearDown(sdk.close);
      await sdk.auth.signUp(
        email: 'rt-off-${DateTime.now().microsecondsSinceEpoch}@example.com',
        password: 'password123',
      );
      await sdk.sync.now();

      connectivity.goOffline();
      await Future<void>.delayed(const Duration(milliseconds: 200));

      // The point is that this does not throw or hang: a dead socket must not
      // keep the SDK from shutting down cleanly.
      await expectLater(sdk.sync.now(), completes);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  group('receipts', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('splitcore_receipts'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<(SplitcoreSdk, Group, GroupMember, FakeConnectivityMonitor)> withExpense() async {
      final connectivity = FakeConnectivityMonitor();
      final sdk = SplitcoreSdk.initialize(
        pocketbaseUrl: server.baseUrl,
        libraryPath: resolveLinuxLibPath(),
        connectivity: connectivity,
      );
      await sdk.auth.signUp(
        email: 'rcpt-${DateTime.now().microsecondsSinceEpoch}@example.com',
        password: 'password123',
      );
      final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
      await sdk.sync.now();
      final member = (await sdk.groups.listMembers(group.id)).single;
      return (sdk, group, member, connectivity);
    }

    test('a receipt queued offline is uploaded on reconnect', () async {
      final (sdk, group, member, connectivity) = await withExpense();
      addTearDown(sdk.close);

      connectivity.goOffline();
      final expense = await sdk.expenses.createExpense(
        groupId: group.id,
        payerMemberId: member.id,
        description: 'Dinner',
        date: DateTime.utc(2026, 8, 6),
        split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
      );
      final entry = (await sdk.expenses.listSplitEntries(expense.id)).single;

      // A 1x1 PNG is enough: the point is the queueing, not the pixels.
      final file = File('${dir.path}/receipt.png')..writeAsBytesSync(_onePixelPng);
      await sdk.expenses.attachReceiptFile(entry.id, file.path);
      expect((await sdk.sync.queued()).last.op, 'receipt.attach');

      connectivity.goOnline();
      await sdk.sync.now();

      expect(await sdk.sync.queued(), isEmpty);
      final synced = (await sdk.expenses.listSplitEntries(expense.id)).single;
      expect(synced.receiptFilename, isNotNull, reason: 'the image never reached the server');
    }, timeout: const Timeout(Duration(minutes: 2)));

    test(
      'a receipt whose file vanished still lets its row sync, and reports the loss',
      () async {
        final (sdk, group, member, connectivity) = await withExpense();
        addTearDown(sdk.close);

        connectivity.goOffline();
        final expense = await sdk.expenses.createExpense(
          groupId: group.id,
          payerMemberId: member.id,
          description: 'Dinner',
          date: DateTime.utc(2026, 8, 6),
          split: SplitSpec.equal(totalCents: 3000, memberIds: [member.id]),
        );
        final entry = (await sdk.expenses.listSplitEntries(expense.id)).single;
        await sdk.expenses.attachReceiptFile(entry.id, '${dir.path}/gone.png');

        final reported = sdk.sync.events.firstWhere((e) => e is ReceiptMissing);
        connectivity.goOnline();
        await sdk.sync.now();

        final event = await reported.timeout(const Duration(seconds: 20)) as ReceiptMissing;
        expect(event.recordId, entry.id);
        expect(event.path, '${dir.path}/gone.png');

        expect(await sdk.sync.queued(), isEmpty, reason: 'a lost photo must not block the queue');
        expect(
          (await sdk.expenses.watch(group.id).first).single.description,
          'Dinner',
          reason: 'the expense itself must still have synced',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

/// The smallest valid PNG: one transparent pixel.
final _onePixelPng = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];
