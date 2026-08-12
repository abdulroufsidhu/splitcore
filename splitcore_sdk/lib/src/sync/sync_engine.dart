// The dbListener: it wakes on events, never on a schedule.
//
// Wake sources are a connectivity transition to online and an explicit
// now(). Both funnel into the same _run(), so there is one pull path to
// reason about regardless of what woke it.
//
// The single timer in this file is post-failure backoff. It is armed only
// after a failed run and cancelled the moment anything else wakes the
// engine, so the steady state is genuinely event-driven.
import 'dart:async';
import 'dart:io';

import 'package:pocketbase/pocketbase.dart';

import '../local/dao/balance_dao.dart';
import '../local/dao/expense_dao.dart';
import '../local/dao/group_dao.dart';
import '../local/dao/outbox_dao.dart';
import '../local/dao/settlement_dao.dart';
import '../local/dao/sync_state_dao.dart';
import '../local/database.dart';
import '../models.dart';
import '../remote/balances_api.dart';
import '../remote/expenses_api.dart';
import '../remote/groups_api.dart';
import '../remote/settlements_api.dart';
import 'connectivity.dart';
import 'events.dart';
import 'outbox_op.dart';
import 'realtime.dart';

/// Resolves a group's staleness against the server. Injected rather than
/// imported so the engine holds no PocketBase client of its own.
typedef StalenessCheck = Future<StalenessResult> Function(String groupId, int localVersion);

class SyncEngine {
  SyncEngine({
    required SplitcoreDb db,
    required ConnectivityMonitor connectivity,
    required GroupsApi groups,
    required ExpensesApi expenses,
    required SettlementsApi settlements,
    required BalancesApi balances,
    required StalenessCheck staleness,
    Future<void> Function(String groupId)? recomputeBalances,
    RealtimeSubscriber? realtime,
  }) : _ledger = recomputeBalances,
       _realtime = realtime,
       _db = db,
       _connectivity = connectivity,
       _groups = groups,
       _expenses = expenses,
       _settlements = settlements,
       _balances = balances,
       _staleness = staleness;

  final SplitcoreDb _db;
  final ConnectivityMonitor _connectivity;
  final GroupsApi _groups;
  final ExpensesApi _expenses;
  final SettlementsApi _settlements;
  final BalancesApi _balances;
  final StalenessCheck _staleness;

  /// Recomputes one group's balances from local rows. Injected because the
  /// engine has no business owning the compute layer, and null-safe because
  /// a pull-only engine never needs it.
  final Future<void> Function(String groupId)? _ledger;

  /// Pushes "something changed" from the server. Optional: without it the
  /// app still syncs on reconnect, on every write, and on demand — it just
  /// does not learn about a co-member's change until one of those happens.
  final RealtimeSubscriber? _realtime;

  final _events = StreamController<SyncEvent>.broadcast();
  StreamSubscription<bool>? _connectivitySub;
  Timer? _backoff;
  Future<void>? _inFlight;
  int _consecutiveFailures = 0;

  static const _maxBackoff = Duration(minutes: 5);

  Stream<SyncEvent> get events => _events.stream;

  /// Begins listening for wake-ups. Not called from the constructor so a
  /// test can build the engine and drive it by hand.
  void start() {
    _connectivitySub = _connectivity.onStatusChange.listen((online) {
      if (!online) {
        // The socket is already dead; dropping it now stops the client
        // retrying a connection that cannot succeed.
        unawaited(_realtime?.stop());
        return;
      }
      _cancelBackoff();
      unawaited(now());
    });
  }

  /// Everything still waiting to be sent.
  Future<List<OutboxOp>> queued() async => OutboxDao(_db).pending();

  /// Writes that could not be applied because the record moved on the
  /// server. Settle one with [resolve].
  Future<List<OutboxOp>> conflicts() async => OutboxDao(_db).conflicts();

  /// Ops the server rejected outright.
  Future<List<OutboxOp>> failures() async => OutboxDao(_db).failed();

  /// Settles a parked conflict.
  ///
  /// [keepLocal] re-queues the op against the server's current state, so
  /// the user's edit is applied on top of whatever changed. Otherwise the op
  /// and everything queued behind it for that record are dropped and the
  /// server's version is pulled back over the local row.
  Future<void> resolve(int seq, {required bool keepLocal}) async {
    final dao = OutboxDao(_db);
    final op = dao.bySeq(seq);
    if (op == null) return;

    if (keepLocal) {
      // Re-based on what the server holds now, so the retry is not measured
      // against a stamp we already know is stale.
      final current = await _currentUpdated(op);
      _db.transaction({'outbox'}, () => dao.requeue(seq, current));
    } else {
      // Dropping the local edit is only half the job: the row still holds
      // it. Reset the group's cursor so the next pull refetches and
      // overwrites — the staleness check would otherwise report the group
      // current and skip it, leaving the abandoned edit on screen forever.
      _db.transaction({'outbox', 'sync_state'}, () {
        dao.deleteFor(op.recordId);
        final groupId = ExpenseDao(_db).byId(op.recordId)?.groupId;
        if (groupId != null) SyncStateDao(_db).markSynced(groupId, -1);
      });
    }
    await now();
  }

  /// Nudges the engine after a local write. Fire-and-forget: the write has
  /// already committed locally, so its caller must not wait on the network
  /// to hear that it succeeded.
  void wake() => unawaited(now().catchError((_) {}));

  /// Runs a push and a pull, queued behind whatever is already running.
  ///
  /// Chained rather than joined. A caller that joins a run which started
  /// *before* their write was enqueued is told "synced" about a queue
  /// snapshot their op was never in, and the op then sits unsent until
  /// something else happens to wake the engine — which, for a user who
  /// saved and then pulled to refresh, looks like the write silently
  /// vanishing. Chaining costs an extra pass when two calls arrive
  /// together, and still never overlaps two runs, which is what SQLite's
  /// single writer requires.
  Future<void> now() {
    final run = (_inFlight ?? Future<void>.value()).then((_) => _run());
    // The stored tail swallows errors so one failed run cannot poison every
    // later caller chained behind it. The returned future keeps them.
    _inFlight = run.catchError((_) {});
    return run;
  }

  /// Pulls one group, if it is stale. Used by write paths that must not act
  /// on known-stale local state.
  Future<void> pullGroupIfStale(String groupId) async {
    final state = await _staleness(groupId, SyncStateDao(_db).versionOf(groupId));
    if (state.current) return;
    await _pullGroup(await _groups.getGroup(groupId), state.serverVersion);
  }

  Future<void> _run() async {
    if (!await _connectivity.isOnline()) return;

    _events.add(const SyncStarted());
    try {
      // Push first: a pull that ran before the queue drained would overwrite
      // the local rows those queued ops describe with the server's older
      // version, and the user would watch their offline work vanish.
      await _push();
      final pulled = await _pull();
      // The server's balances do not account for writes still sitting in the
      // queue, so the figures on screen would drop back until the queue
      // drains. Recompute over the local rows, which include them.
      if (pulled > 0 && OutboxDao(_db).pendingRecordIds().isNotEmpty) {
        await _recomputePendingGroups();
      }
      _consecutiveFailures = 0;
      _cancelBackoff();
      _events.add(SyncCompleted(pulled));
      // After a successful sync, not at construction: realtime is scoped to
      // what the session may read, and at construction there may be no
      // session yet. Idempotent, so calling it every run is free.
      unawaited(_realtime?.start());
    } catch (e) {
      _events.add(SyncFailed(e));
      _armBackoff();
    }
  }

  /// Drains the outbox in strict seq order. Ordering is load-bearing: an
  /// update must never overtake the create it depends on.
  ///
  /// Stops at the first transient failure and keeps the queue intact, so a
  /// flaky connection costs a retry rather than a reordering.
  Future<void> _push() async {
    final dao = OutboxDao(_db);
    for (final op in dao.pending()) {
      try {
        await _apply(op);
        _db.transaction({'outbox'}, () => dao.delete(op.seq));
      } on _ConflictDetected catch (e) {
        _db.transaction({'outbox'}, () => dao.markConflict(op.seq, e.message));
        _events.add(SyncConflict(seq: op.seq, op: op.op, recordId: op.recordId));
      } on ClientException catch (e) {
        if (_isAlreadyApplied(op, e)) {
          _db.transaction({'outbox'}, () => dao.delete(op.seq));
          continue;
        }
        if (_isTransient(e)) {
          _db.transaction({'outbox'}, () => dao.recordAttempt(op.seq, e.toString()));
          // Preserve order: everything behind this op waits for it.
          rethrow;
        }
        // A 4xx that replaying will not fix.
        _db.transaction({'outbox'}, () => dao.markFailed(op.seq, e.toString()));
        _events.add(SyncOpFailed(seq: op.seq, op: op.op, error: e.toString()));
      }
    }
    _refreshPendingFlags();
  }

  /// A replayed create that already landed comes back as a uniqueness
  /// failure on the client-minted id, and a delete of an already-deleted
  /// record 404s. Both mean the server is in the state the op wanted.
  bool _isAlreadyApplied(OutboxOp op, ClientException e) {
    if (e.statusCode == 404) {
      return op.op == OutboxOps.expenseDelete || op.op == OutboxOps.memberRemove;
    }
    if (e.statusCode != 400) return false;
    final isCreate =
        op.op == OutboxOps.expenseCreate ||
        op.op == OutboxOps.settlementCreate ||
        op.op == OutboxOps.groupCreate;
    return isCreate && e.response.toString().contains('validation_not_unique');
  }

  // 0 is what the PocketBase client reports for a socket-level failure, and
  // 5xx is the server having a bad day. Neither says the write was wrong.
  bool _isTransient(ClientException e) =>
      e.statusCode == 0 || e.statusCode >= 500 || e.originalError is SocketException;

  Future<void> _apply(OutboxOp op) async {
    final p = op.payload;
    switch (op.op) {
      case OutboxOps.expenseCreate:
        await _expenses.createExpenseWithId(
          id: op.recordId,
          groupId: p['groupId']! as String,
          payerMemberId: p['payerMemberId']! as String,
          description: p['description']! as String,
          date: DateTime.parse(p['date']! as String),
          amountCents: (p['amountCents']! as num).toInt(),
          splitType: p['splitType']! as String,
          splits: _splitsOf(op.recordId, p),
        );

      case OutboxOps.expenseUpdate:
        await _guardConflict(op, () async {
          await _expenses.replaceExpense(
            expenseId: op.recordId,
            payerMemberId: p['payerMemberId']! as String,
            description: p['description']! as String,
            date: DateTime.parse(p['date']! as String),
            amountCents: (p['amountCents']! as num).toInt(),
            splitType: p['splitType']! as String,
            splits: _splitsOf(op.recordId, p),
          );
        });

      case OutboxOps.expenseDelete:
        await _guardConflict(op, () => _expenses.deleteExpense(op.recordId));

      case OutboxOps.settlementCreate:
        await _settlements.createSettlementWithId(
          id: op.recordId,
          groupId: p['groupId']! as String,
          fromMemberId: p['fromMemberId']! as String,
          toMemberId: p['toMemberId']! as String,
          amountCents: (p['amountCents']! as num).toInt(),
          note: p['note'] as String? ?? '',
          date: DateTime.parse(p['date']! as String),
        );

      case OutboxOps.receiptAttach:
        await _attachReceipt(op);

      default:
        throw StateError('unknown outbox op: ${op.op}');
    }
  }

  /// Fails the op rather than applying it when the server's copy has moved
  /// since [op] was built. PocketBase has no conditional write, so this is a
  /// read-then-write: the window is small, and losing a co-member's edit
  /// silently is worse than a rare missed detection.
  Future<void> _guardConflict(OutboxOp op, Future<void> Function() write) async {
    final current = await _currentUpdated(op);
    if (_movedSince(op.baseUpdated, current)) {
      throw _ConflictDetected('the record changed on the server since this edit was made');
    }
    await write();
  }

  /// Compared as instants, not as strings. PocketBase serialises `updated`
  /// as `2026-08-06 16:24:50.448Z` while a value that has round-tripped
  /// through the local database comes back in ISO form with a `T`. String
  /// equality therefore reports a conflict on every single edit, which
  /// looks exactly like a working conflict detector until you notice no
  /// edit ever syncs.
  bool _movedSince(String? base, String? current) {
    if (base == null || current == null) return false;
    final a = DateTime.tryParse(base);
    final b = DateTime.tryParse(current);
    // Unparseable on either side: refuse to guess. Overwriting a
    // co-member's edit is worse than parking one that did not need it.
    if (a == null || b == null) return base != current;
    return !a.isAtSameMomentAs(b);
  }

  Future<String?> _currentUpdated(OutboxOp op) async {
    try {
      return await _expenses.updatedOf(op.recordId);
    } on ClientException catch (e) {
      // Gone entirely: there is nothing left to conflict with, and the op's
      // own outcome (404 on a delete, 404 on an update) decides the rest.
      if (e.statusCode == 404) return null;
      rethrow;
    }
  }

  Future<void> _attachReceipt(OutboxOp op) async {
    final path = op.receiptPath;
    if (path == null) return;
    try {
      final bytes = await File(path).readAsBytes();
      await _expenses.attachReceipt(op.recordId, bytes);
    } on FileSystemException catch (e) {
      // The row this receipt belonged to is already synced. Report the loss
      // and move on rather than blocking the queue on a file that will never
      // come back.
      _events.add(ReceiptMissing(recordId: op.recordId, path: path, error: e));
    }
  }

  /// Rebuilds the entries with the ids they were minted with locally, so
  /// the server's rows carry the same ids the local database already
  /// references.
  List<SplitEntry> _splitsOf(String expenseId, Map<String, Object?> payload) => [
    for (final s in (payload['splits']! as List).cast<Map<String, Object?>>())
      SplitEntry(
        id: s['id']! as String,
        expenseId: expenseId,
        memberId: s['memberId']! as String,
        amountCents: (s['amountCents']! as num).toInt(),
      ),
  ];

  /// Recomputes which rows the UI should grey. Done once after a drain
  /// rather than per op: the outbox is the authority, and asking it once is
  /// cheaper than keeping a flag in step through every branch above.
  /// Re-derives balances for every group that still has unsent work, so the
  /// provisional figures survive a pull.
  Future<void> _recomputePendingGroups() async {
    final ledger = _ledger;
    if (ledger == null) return;
    for (final groupId in GroupDao(_db).listGroups().map((g) => g.id)) {
      await ledger(groupId);
    }
  }

  void _refreshPendingFlags() {
    final ids = OutboxDao(_db).pendingRecordIds();
    _db.transaction({'expenses', 'settlements'}, () {
      ExpenseDao(_db).setPending(ids);
    });
  }

  Future<int> _pull() async {
    final remoteGroups = await _groups.listMyGroups();

    _db.transaction({'groups'}, () {
      final dao = GroupDao(_db);
      dao.upsertGroups(remoteGroups);
      dao.deleteGroupsMissingFrom({for (final g in remoteGroups) g.id});
    });

    var pulled = 0;
    for (final group in remoteGroups) {
      // Skipping a current group is the whole reason a reconnect stays
      // cheap with a long history behind it — but the check itself is free
      // here: listMyGroups already returned the server's version on every
      // group, so asking /staleness for it again was one extra round trip
      // per group for an answer we were already holding.
      if (SyncStateDao(_db).versionOf(group.id) == group.version) continue;

      await _pullGroup(group, group.version);
      pulled++;
    }
    return pulled;
  }

  Future<void> _pullGroup(Group group, int serverVersion) async {
    // Snapshotted before the fetch: anything queued now — or enqueued while
    // the requests below are in flight — must survive this pull. Blindly
    // mirroring the server would delete the user's unsent work.
    final protected = OutboxDao(_db).unsettledRecordIds();

    // Issued together, not one after another. None of the five depends on
    // another's result, and on a link where a round trip costs a quarter of
    // a second, serialising them was the difference between a sync that
    // feels instant and one the user watches happen.
    final fetched = await Future.wait([
      _groups.listMembers(group.id),
      _expenses.listAllExpenses(group.id),
      _expenses.listGroupSplitEntries(group.id),
      _settlements.listAllSettlements(group.id),
      _balances.getBalances(group.id),
    ]);
    final members = fetched[0] as List<GroupMember>;
    final expenses = fetched[1] as List<Expense>;
    final splits = fetched[2] as Map<String, List<SplitEntry>>;
    final settlements = fetched[3] as List<Settlement>;
    final balances = fetched[4] as List<Balance>;

    // One commit: a screen must never observe new expenses against old
    // balances, which is exactly the "my numbers don't add up" bug report.
    // Everything above is fetched first so a mid-fetch failure leaves the
    // previous state intact rather than a half-written group.
    _db.transaction(
      {'groups', 'members', 'expenses', 'split_entries', 'settlements', 'balances', 'sync_state'},
      () {
        // Re-read inside the commit: a write may have been enqueued while
        // the requests above were in flight, and that row must survive too.
        final keep = protected.union(OutboxDao(_db).unsettledRecordIds());
        GroupDao(_db).upsertGroups([group]);
        GroupDao(_db).upsertMembers(group.id, members);
        ExpenseDao(_db).replaceGroupExpenses(group.id, expenses, splits, protectedIds: keep);
        SettlementDao(_db).replaceGroupSettlements(group.id, settlements, protectedIds: keep);
        BalanceDao(_db).replaceGroupBalances(group.id, balances);
        SyncStateDao(_db).markSynced(group.id, serverVersion);
      },
    );
  }

  void _armBackoff() {
    _consecutiveFailures++;
    // 1s, 2s, 4s, ... capped. Doubling rather than a fixed interval so a
    // server that is down for an hour is not hammered 3600 times.
    final seconds = 1 << (_consecutiveFailures.clamp(1, 9) - 1);
    final delay = seconds < _maxBackoff.inSeconds ? Duration(seconds: seconds) : _maxBackoff;
    _backoff?.cancel();
    _backoff = Timer(delay, () => unawaited(now()));
  }

  void _cancelBackoff() {
    _backoff?.cancel();
    _backoff = null;
  }

  Future<void> dispose() async {
    _cancelBackoff();
    await _realtime?.stop();
    await _connectivitySub?.cancel();
    await _events.close();
  }
}

/// Raised inside a push when the server's copy moved after the op was
/// built. Private: callers see it as a parked op and a SyncConflict event.
class _ConflictDetected implements Exception {
  _ConflictDetected(this.message);

  final String message;
}
