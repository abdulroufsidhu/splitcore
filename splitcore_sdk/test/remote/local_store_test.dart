import 'package:splitcore_sdk/src/models.dart';
import 'package:splitcore_sdk/src/remote/local_store.dart';
import 'package:test/test.dart';

void main() {
  test('snapshotFor returns null for a group that was never put', () {
    final store = LocalStore();

    expect(store.snapshotFor('unknown-group'), isNull);
  });

  test('put then snapshotFor round-trips version and balances, per group', () {
    final store = LocalStore();
    const snapshotA = GroupSnapshot(version: 3, balances: [Balance(memberId: 'a', netCents: 100)]);
    const snapshotB = GroupSnapshot(version: 1, balances: []);

    store.put('group-a', snapshotA);
    store.put('group-b', snapshotB);

    expect(store.snapshotFor('group-a'), snapshotA);
    expect(store.snapshotFor('group-b'), snapshotB);
  });
}
