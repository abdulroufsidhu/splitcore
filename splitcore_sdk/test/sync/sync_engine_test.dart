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

  Future<SplitcoreSdk> signedInSdk(ConnectivityMonitor connectivity) async {
    final sdk = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      connectivity: connectivity,
    );
    await sdk.auth.signUp(
      email: 'sync-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    return sdk;
  }

  test('a group created on the server lands in the local database after a pull', () async {
    final sdk = await signedInSdk(FakeConnectivityMonitor());
    addTearDown(sdk.close);

    await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();

    expect((await sdk.groups.watchGroups().first).map((g) => g.name), ['Trip']);
  });

  test('watchGroups re-emits when a pull writes, without being re-subscribed', () async {
    final sdk = await signedInSdk(FakeConnectivityMonitor());
    addTearDown(sdk.close);

    final emissions = <List<Group>>[];
    final sub = sdk.groups.watchGroups().listen(emissions.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emissions.single, isEmpty, reason: 'the first emission is the empty local database');

    await sdk.groups.createGroup(name: 'Flat', currency: 'EUR');
    await Future<void>.delayed(Duration.zero);

    expect(
      emissions.last.map((g) => g.name),
      ['Flat'],
      reason: 'a write pulls, and the pull must push through the same subscription',
    );
  });

  test('coming back online triggers a pull with no manual call', () async {
    final connectivity = FakeConnectivityMonitor(online: false);
    final sdk = await signedInSdk(connectivity);
    addTearDown(sdk.close);

    // Created while "offline": the write still reaches the server in phase
    // one, but no pull runs, so the local database stays empty.
    await sdk.groups.createGroup(name: 'Ski', currency: 'CHF');
    expect(await sdk.groups.watchGroups().first, isEmpty);

    final completed = sdk.sync.events.firstWhere((e) => e is SyncCompleted);
    connectivity.goOnline();
    await completed;

    expect((await sdk.groups.watchGroups().first).map((g) => g.name), ['Ski']);
  });

  test('an unchanged group is not refetched on the next pull', () async {
    final sdk = await signedInSdk(FakeConnectivityMonitor());
    addTearDown(sdk.close);

    await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    await sdk.sync.now();

    final second = sdk.sync.events.firstWhere((e) => e is SyncCompleted);
    await sdk.sync.now();

    expect(
      (await second as SyncCompleted).groupsPulled,
      0,
      reason: 'the staleness check exists precisely so a quiet reconnect costs one request',
    );
  });

  test('a pull writes expenses, their split entries, and balances together', () async {
    final sdk = await signedInSdk(FakeConnectivityMonitor());
    addTearDown(sdk.close);

    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    final members = await sdk.groups.listMembers(group.id);
    await sdk.expenses.createExpense(
      groupId: group.id,
      payerMemberId: members.single.id,
      description: 'Dinner',
      date: DateTime.utc(2026, 8, 6),
      split: SplitSpec.equal(totalCents: 3000, memberIds: [members.single.id]),
    );
    await sdk.sync.now();

    final expenses = await sdk.expenses.watch(group.id).first;
    expect(expenses.map((e) => e.description), ['Dinner']);
    expect(expenses.single.amountCents, 3000);

    final entries = await sdk.expenses.watchSplitEntries(expenses.single.id).first;
    expect(entries.single.amountCents, 3000);

    final balances = await sdk.balances.watch(group.id).first;
    expect(balances.fold<int>(0, (sum, b) => sum + b.netCents), 0);
  });

  test('the search query filters the watched expense list locally', () async {
    final sdk = await signedInSdk(FakeConnectivityMonitor());
    addTearDown(sdk.close);

    final group = await sdk.groups.createGroup(name: 'Trip', currency: 'USD');
    final members = await sdk.groups.listMembers(group.id);
    for (final description in ['Dinner', 'Taxi']) {
      await sdk.expenses.createExpense(
        groupId: group.id,
        payerMemberId: members.single.id,
        description: description,
        date: DateTime.utc(2026, 8, 6),
        split: SplitSpec.equal(totalCents: 1000, memberIds: [members.single.id]),
      );
    }
    await sdk.sync.now();

    expect((await sdk.expenses.watch(group.id, query: 'tax').first).map((e) => e.description), [
      'Taxi',
    ]);
  });

  test('local rows survive a restart: a second SDK on the same file reads them offline', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/splitcore.db';

    final first = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      databasePath: path,
      connectivity: FakeConnectivityMonitor(),
    );
    await first.auth.signUp(
      email: 'restart-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    await first.groups.createGroup(name: 'Trip', currency: 'USD');
    await first.sync.now();
    await first.close();

    // A fresh process, and this one never reaches the network.
    final relaunched = SplitcoreSdk.initialize(
      pocketbaseUrl: 'http://127.0.0.1:1',
      libraryPath: resolveLinuxLibPath(),
      databasePath: path,
      connectivity: FakeConnectivityMonitor(online: false),
    );
    addTearDown(relaunched.close);

    expect((await relaunched.groups.watchGroups().first).map((g) => g.name), ['Trip']);
  });

  test('a pull against an unreachable server reports failure and keeps local rows', () async {
    final dir = await _tempDir();
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/splitcore.db';

    final first = SplitcoreSdk.initialize(
      pocketbaseUrl: server.baseUrl,
      libraryPath: resolveLinuxLibPath(),
      databasePath: path,
      connectivity: FakeConnectivityMonitor(),
    );
    await first.auth.signUp(
      email: 'offline-pull-${DateTime.now().microsecondsSinceEpoch}@example.com',
      password: 'password123',
    );
    await first.groups.createGroup(name: 'Trip', currency: 'USD');
    await first.sync.now();
    await first.close();

    final offline = SplitcoreSdk.initialize(
      pocketbaseUrl: 'http://127.0.0.1:1',
      libraryPath: resolveLinuxLibPath(),
      databasePath: path,
      connectivity: FakeConnectivityMonitor(),
    );
    addTearDown(offline.close);

    final failure = offline.sync.events.firstWhere((e) => e is SyncFailed);
    await offline.sync.now();
    await failure;

    expect(
      (await offline.groups.watchGroups().first).map((g) => g.name),
      ['Trip'],
      reason: 'a failed pull must never wipe what was already synced',
    );
  });
}

Future<Directory> _tempDir() => Directory.systemTemp.createTemp('splitcore_sync');
