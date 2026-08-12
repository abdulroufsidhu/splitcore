import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

void main() {
  test('a fresh database is created at the current schema version', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    expect(db.userVersion, SplitcoreDb.schemaVersion);
  });

  test('every mirrored table and the sdk-owned tables exist', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    final names = db.raw
        .select("SELECT name FROM sqlite_master WHERE type = 'table'")
        .map((row) => row['name'] as String)
        .toSet();

    expect(
      names,
      containsAll([
        'groups',
        'members',
        'expenses',
        'split_entries',
        'settlements',
        'balances',
        'outbox',
        'sync_state',
      ]),
    );
  });

  test('migrating an already-current database is a no-op, not an error', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    // Running the ladder a second time must not throw "table already exists".
    expect(db.migrate, returnsNormally);
    expect(db.userVersion, SplitcoreDb.schemaVersion);
  });

  test('foreign keys cascade so deleting an expense drops its split entries', () {
    final db = SplitcoreDb.inMemory();
    addTearDown(db.close);

    db.raw.execute(
      'INSERT INTO groups (id, name, currency, version, owner_id, is_direct, updated, pending) '
      "VALUES ('g1', 'Trip', 'USD', 1, 'u1', 0, '2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      'INSERT INTO members (id, group_id, user_id, role, name, avatar_url, updated, pending) '
      "VALUES ('m1', 'g1', 'u1', 'owner', 'Ada', '', '2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      'INSERT INTO expenses '
      '(id, group_id, payer_member_id, description, amount_cents, split_type, date, updated, pending) '
      "VALUES ('e1', 'g1', 'm1', 'Dinner', 3000, 'equal', '2026-08-06T00:00:00Z', "
      "'2026-08-06T00:00:00Z', 0)",
    );
    db.raw.execute(
      'INSERT INTO split_entries (id, expense_id, member_id, amount_cents, receipt_filename) '
      "VALUES ('s1', 'e1', 'm1', 3000, NULL)",
    );

    db.raw.execute("DELETE FROM expenses WHERE id = 'e1'");

    final remaining = db.raw.select('SELECT COUNT(*) AS n FROM split_entries').first['n'] as int;
    expect(remaining, 0);
  });
}
