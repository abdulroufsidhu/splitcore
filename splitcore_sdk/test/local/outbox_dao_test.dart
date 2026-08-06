import 'package:splitcore_sdk/splitcore_sdk.dart';
import 'package:splitcore_sdk/src/local/dao/expense_dao.dart';
import 'package:splitcore_sdk/src/local/dao/group_dao.dart';
import 'package:splitcore_sdk/src/local/dao/outbox_dao.dart';
import 'package:splitcore_sdk/src/local/database.dart';
import 'package:test/test.dart';

const _group = Group(id: 'g1', name: 'Trip', currency: 'USD', version: 3, ownerId: 'u1');

void main() {
  late SplitcoreDb db;
  late OutboxDao outbox;

  setUp(() {
    db = SplitcoreDb.inMemory();
    outbox = OutboxDao(db);
    db.transaction({'groups'}, () => GroupDao(db).upsertGroups([_group]));
  });

  tearDown(() => db.close());

  int enqueue(String op, String recordId, {String? baseUpdated}) => db.transaction(
    {'outbox'},
    () => outbox.enqueue(
      op: op,
      recordId: recordId,
      payload: const {'k': 'v'},
      baseUpdated: baseUpdated,
    ),
  );

  test('ops drain in the order they were enqueued', () {
    enqueue('expense.create', 'e1');
    enqueue('expense.update', 'e1');
    enqueue('expense.delete', 'e2');

    expect(outbox.pending().map((o) => o.op), [
      'expense.create',
      'expense.update',
      'expense.delete',
    ]);
  });

  test('an op round-trips its payload and conflict base', () {
    final seq = enqueue('expense.update', 'e1', baseUpdated: '2026-08-06 10:12:00.000Z');

    final op = outbox.pending().single;
    expect(op.seq, seq);
    expect(op.recordId, 'e1');
    expect(op.payload, {'k': 'v'});
    expect(op.baseUpdated, '2026-08-06 10:12:00.000Z');
    expect(op.state, 'pending');
    expect(op.attempts, 0);
  });

  test('a delivered op is removed from the queue', () {
    final seq = enqueue('expense.create', 'e1');
    db.transaction({'outbox'}, () => outbox.delete(seq));

    expect(outbox.pending(), isEmpty);
  });

  test('a conflicted op leaves the queue but stays retrievable for resolution', () {
    final seq = enqueue('expense.update', 'e1');
    db.transaction({'outbox'}, () => outbox.markConflict(seq, 'server moved'));

    expect(outbox.pending(), isEmpty, reason: 'a parked op must not block the ops behind it');
    expect(outbox.conflicts().single.seq, seq);
    expect(outbox.conflicts().single.lastError, 'server moved');
  });

  test('conflicting an op also conflicts every later op for the same record', () {
    // The later ops were built on top of the one that failed, so replaying
    // them would apply an edit to a base the user never saw.
    final first = enqueue('expense.update', 'e1');
    final second = enqueue('expense.update', 'e1');
    final other = enqueue('expense.update', 'e2');

    db.transaction({'outbox'}, () => outbox.markConflict(first, 'server moved'));

    expect(outbox.conflicts().map((o) => o.seq), [first, second]);
    expect(outbox.pending().map((o) => o.seq), [other]);
  });

  test('a permanently failed op leaves the queue and is not retried', () {
    final seq = enqueue('expense.create', 'e1');
    db.transaction({'outbox'}, () => outbox.markFailed(seq, 'amount_cents is required'));

    expect(outbox.pending(), isEmpty);
    expect(outbox.failed().single.lastError, 'amount_cents is required');
  });

  test('recording an attempt increments the counter without dequeuing', () {
    final seq = enqueue('expense.create', 'e1');
    db.transaction({'outbox'}, () => outbox.recordAttempt(seq, 'connection refused'));

    final op = outbox.pending().single;
    expect(op.attempts, 1);
    expect(op.lastError, 'connection refused');
  });

  test('pendingRecordIds reports what the UI should render as unsent', () {
    enqueue('expense.create', 'e1');
    final delivered = enqueue('expense.create', 'e2');
    db.transaction({'outbox'}, () => outbox.delete(delivered));

    expect(outbox.pendingRecordIds(), {'e1'});
  });

  test('deleteFor drops every queued op for a record, whatever its state', () {
    final conflicted = enqueue('expense.update', 'e1');
    enqueue('expense.update', 'e1');
    db.transaction({'outbox'}, () => outbox.markConflict(conflicted, 'server moved'));

    db.transaction({'outbox'}, () => outbox.deleteFor('e1'));

    expect(outbox.pending(), isEmpty);
    expect(outbox.conflicts(), isEmpty);
  });

  test('an expense round-trips the server updated stamp that conflicts are measured against', () {
    final expense = Expense(
      id: 'e1',
      groupId: 'g1',
      payerMemberId: 'm1',
      description: 'Dinner',
      amountCents: 3000,
      splitType: 'equal',
      date: DateTime.utc(2026, 8, 6),
      updated: DateTime.utc(2026, 8, 6, 10, 12),
    );
    db.transaction({'expenses'}, () {
      ExpenseDao(db).replaceGroupExpenses('g1', [expense], const {});
    });

    expect(ExpenseDao(db).listExpenses('g1').single.updated, DateTime.utc(2026, 8, 6, 10, 12));
    expect(ExpenseDao(db).updatedOf('e1'), '2026-08-06T10:12:00.000Z');
  });
}
