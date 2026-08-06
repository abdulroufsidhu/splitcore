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

import '../local/dao/balance_dao.dart';
import '../local/dao/expense_dao.dart';
import '../local/dao/group_dao.dart';
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
  }) : _db = db,
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
      if (!online) return;
      _cancelBackoff();
      unawaited(now());
    });
  }

  /// Runs a pull, or joins the one already running. Concurrent callers must
  /// not each start their own: two pulls interleaving their writes would
  /// contend for SQLite's single writer and could commit a half-updated
  /// group.
  Future<void> now() => _inFlight ??= _run().whenComplete(() => _inFlight = null);

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
      final pulled = await _pull();
      _consecutiveFailures = 0;
      _cancelBackoff();
      _events.add(SyncCompleted(pulled));
    } catch (e) {
      _events.add(SyncFailed(e));
      _armBackoff();
    }
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
      // An O(1) metadata check. Skipping a current group is the whole
      // reason a reconnect stays cheap with a long history behind it.
      final state = await _staleness(group.id, SyncStateDao(_db).versionOf(group.id));
      if (state.current) continue;

      await _pullGroup(group, state.serverVersion);
      pulled++;
    }
    return pulled;
  }

  Future<void> _pullGroup(Group group, int serverVersion) async {
    final members = await _groups.listMembers(group.id);
    final expenses = await _expenses.listAllExpenses(group.id);
    final splits = <String, List<SplitEntry>>{};
    for (final e in expenses) {
      splits[e.id] = await _expenses.listSplitEntries(e.id);
    }
    final settlements = await _settlements.listAllSettlements(group.id);
    final balances = await _balances.getBalances(group.id);

    // One commit: a screen must never observe new expenses against old
    // balances, which is exactly the "my numbers don't add up" bug report.
    // Everything above is fetched first so a mid-fetch failure leaves the
    // previous state intact rather than a half-written group.
    _db.transaction(
      {'groups', 'members', 'expenses', 'split_entries', 'settlements', 'balances', 'sync_state'},
      () {
        GroupDao(_db).upsertGroups([group]);
        GroupDao(_db).upsertMembers(group.id, members);
        ExpenseDao(_db).replaceGroupExpenses(group.id, expenses, splits);
        SettlementDao(_db).replaceGroupSettlements(group.id, settlements);
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
    await _connectivitySub?.cancel();
    await _events.close();
  }
}
