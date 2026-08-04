import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:splitcore_app/offline_cache.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('returns null before anything is cached', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    expect(cache.groups(), isNull);
    expect(cache.lastUpdated, isNull);
  });

  test('round-trips a group summary list', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    await cache.putGroups(const [
      GroupSummary(id: 'g1', name: 'Trip', currency: 'USD', myNetCents: 2500, memberCount: 3),
    ]);

    final restored = cache.groups();

    expect(restored, isNotNull);
    expect(restored!.single.name, 'Trip');
    expect(restored.single.myNetCents, 2500);
    expect(restored.single.currency, 'USD');
    expect(restored.single.memberCount, 3);
  });

  test('a second instance sees what the first wrote (survives restart)', () async {
    final prefs = await SharedPreferences.getInstance();
    await OfflineCache(prefs).putGroups(const [
      GroupSummary(id: 'g1', name: 'Trip', currency: 'USD', myNetCents: 1, memberCount: 2),
    ]);

    expect(OfflineCache(prefs).groups()!.single.id, 'g1');
  });

  test('corrupt cached JSON is discarded, not thrown', () async {
    // A cache written by an older app version is not worth a crash;
    // dropping it costs one network fetch.
    SharedPreferences.setMockInitialValues({'offline_groups_v1': 'not json at all'});
    final cache = OfflineCache(await SharedPreferences.getInstance());

    expect(cache.groups(), isNull);
  });

  test('JSON missing an expected field is discarded, not half-read', () async {
    SharedPreferences.setMockInitialValues({'offline_groups_v1': '[{"id":"g1"}]'});
    final cache = OfflineCache(await SharedPreferences.getInstance());

    expect(cache.groups(), isNull);
  });

  test('amounts survive as exact integers, including negatives', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    await cache.putGroups(const [
      GroupSummary(id: 'g1', name: 'X', currency: 'USD', myNetCents: -9007199254, memberCount: 1),
    ]);

    expect(cache.groups()!.single.myNetCents, -9007199254);
  });

  test('markUpdated records when the data was last good', () async {
    final cache = OfflineCache(await SharedPreferences.getInstance());
    final before = DateTime.now().subtract(const Duration(seconds: 1));

    await cache.markUpdated();

    expect(cache.lastUpdated!.isAfter(before), isTrue);
  });
}
