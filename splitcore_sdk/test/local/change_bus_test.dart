import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

const _insertGroup =
    'INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) '
    "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, NULL, 0)";

void main() {
  test('a transaction emits the tables it touched, once, after it commits', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final seen = <Set<String>>[];
    final sub = db.changes.listen(seen.add);
    addTearDown(sub.cancel);

    db.transaction({'groups'}, () => db.raw.execute(_insertGroup));

    await Future<void>.delayed(Duration.zero);
    expect(seen, [
      {'groups'},
    ]);
  });

  test('a failed transaction rolls back and emits nothing', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final seen = <Set<String>>[];
    final sub = db.changes.listen(seen.add);
    addTearDown(sub.cancel);

    expect(
      () => db.transaction({'groups'}, () {
        db.raw.execute(_insertGroup);
        throw StateError('boom');
      }),
      throwsStateError,
    );

    await Future<void>.delayed(Duration.zero);
    final rows = db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int;
    expect(rows, 0, reason: 'the insert must have rolled back');
    expect(seen, isEmpty, reason: 'a rolled-back transaction changed nothing to announce');
  });

  test('nesting a transaction throws rather than silently flattening', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    expect(
      () => db.transaction({'groups'}, () => db.transaction({'members'}, () {})),
      throwsStateError,
    );
  });

  test('watch emits the current value immediately, then again on a matching change', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final emitted = <int>[];
    final sub = db
        .watch({
          'groups',
        }, () => db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int)
        .listen(emitted.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    expect(emitted, [0], reason: 'watch must not wait for a change to produce a first value');

    db.transaction({'groups'}, () => db.raw.execute(_insertGroup));

    await Future<void>.delayed(Duration.zero);
    expect(emitted, [0, 1]);
  });

  test('watch ignores changes to tables it does not care about', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final emitted = <int>[];
    final sub = db
        .watch({
          'groups',
        }, () => db.raw.select('SELECT COUNT(*) AS n FROM groups').first['n'] as int)
        .listen(emitted.add);
    addTearDown(sub.cancel);

    await Future<void>.delayed(Duration.zero);
    db.transaction({'settlements'}, () {});
    await Future<void>.delayed(Duration.zero);

    expect(emitted, [0]);
  });

  test('a throwing query surfaces as a stream error, not an uncaught exception', () async {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final stream = db.watch<int>({'groups'}, () => throw StateError('bad query'));

    await expectLater(stream, emitsError(isStateError));
  });
}
