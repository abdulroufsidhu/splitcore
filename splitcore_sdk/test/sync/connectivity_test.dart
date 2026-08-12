import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:test/test.dart';

void main() {
  test('AlwaysOnline reports online and never transitions', () async {
    final monitor = AlwaysOnline();

    expect(await monitor.isOnline(), isTrue);
    expect(await monitor.onStatusChange.isEmpty, isTrue);
  });

  test('the fake monitor reports and emits transitions', () async {
    final monitor = FakeConnectivityMonitor(online: false);
    addTearDown(monitor.dispose);

    final seen = <bool>[];
    final sub = monitor.onStatusChange.listen(seen.add);
    addTearDown(sub.cancel);

    expect(await monitor.isOnline(), isFalse);

    monitor.goOnline();
    await Future<void>.delayed(Duration.zero);
    expect(await monitor.isOnline(), isTrue);

    monitor.goOffline();
    await Future<void>.delayed(Duration.zero);

    expect(seen, [true, false]);
  });

  test('a repeated status does not emit — only transitions matter', () async {
    // The sync engine reads every event as "the network just came back", so
    // a platform that re-announces the same state must not trigger a resync
    // storm.
    final monitor = FakeConnectivityMonitor();
    addTearDown(monitor.dispose);

    final seen = <bool>[];
    final sub = monitor.onStatusChange.listen(seen.add);
    addTearDown(sub.cancel);

    monitor.goOnline();
    monitor.goOnline();
    await Future<void>.delayed(Duration.zero);

    expect(seen, isEmpty);
  });
}
