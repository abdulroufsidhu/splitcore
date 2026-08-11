// The sole facade a Flutter app should ever import. Wires the compute
// layer (SplitcoreCalc) and the PocketBase remote layer together; the
// frontend never talks to PocketBase or does split math directly.
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'calc_api.dart';
import 'local/database.dart';
import 'models.dart';
import 'remote/auth_api.dart';
import 'remote/balances_api.dart';
import 'remote/expenses_api.dart';
import 'remote/export_api.dart';
import 'remote/groups_api.dart';
import 'remote/settlements_api.dart';
import 'remote/staleness_api.dart';
import 'remote/token_store.dart';
import 'repo/balances_repository.dart';
import 'repo/expenses_repository.dart';
import 'repo/groups_repository.dart';
import 'repo/local_ledger.dart';
import 'repo/settlements_repository.dart';
import 'sync/connectivity.dart';
import 'sync/realtime.dart';
import 'sync/sync_engine.dart';

class SplitcoreSdk {
  SplitcoreSdk._(
    this.auth,
    this.groups,
    this.expenses,
    this.settlements,
    this.balances,
    this.export,
    this.sync,
    this._calc,
    this._db,
    this._http,
  );

  /// Opens the splitcore native library at [libraryPath] and connects to
  /// the PocketBase server at [pocketbaseUrl]. Every sub-API below shares
  /// the same PocketBase client (so signing in on [auth] authenticates
  /// [groups], [expenses], etc.) and the same compute engine.
  ///
  /// Pass [tokenStore] to persist the signed-in session across app
  /// restarts; defaults to PocketBase's in-memory store, which forgets
  /// sign-in on every launch. The interface is SDK-owned so the app never
  /// has to import `package:pocketbase` for it.
  ///
  /// [databasePath] is where the local mirror lives. Omit it and the
  /// database is in-memory: reads are still local-first for the life of the
  /// process, they just do not survive a restart.
  ///
  /// [connectivity] is how the SDK learns the network came back, which is
  /// what triggers a sync. It is injected because every real implementation
  /// is a Flutter plugin and this package is pure Dart; omit it and the SDK
  /// assumes a connection, exactly as it behaved before.
  factory SplitcoreSdk.initialize({
    required String pocketbaseUrl,
    required String libraryPath,
    String? databasePath,
    TokenStore? tokenStore,
    ConnectivityMonitor? connectivity,
  }) {
    // One client for the whole SDK instance, handed out unclosable — see
    // _SharedClient.
    final shared = _TimeoutClient(http.Client(), const Duration(seconds: 15));
    final pb = PocketBase(
      pocketbaseUrl,
      authStore: tokenStore == null ? null : asAuthStore(tokenStore),
      httpClientFactory: () => _SharedClient(shared),
    );
    final calc = SplitcoreCalc.open(libraryPath);
    final db = databasePath == null ? SplitcoreDb.inMemory() : SplitcoreDb.openAt(databasePath);
    final ledger = LocalLedger(db, calc);

    final groupsApi = GroupsApi(pb);
    final expensesApi = ExpensesApi(pb, calc);
    final balancesApi = BalancesApi(pb);
    // Late-bound: the API needs the engine to resync a stale group, and the
    // engine needs the API to list settlements. The cycle is broken by the
    // callback rather than by a second copy of either.
    late final SyncEngine sync;
    final settlementsApi = SettlementsApi(pb, (groupId) => sync.pullGroupIfStale(groupId));
    final realtime = RealtimeSubscriber(pb, () => sync.wake());

    sync = SyncEngine(
      db: db,
      connectivity: connectivity ?? AlwaysOnline(),
      groups: groupsApi,
      expenses: expensesApi,
      settlements: settlementsApi,
      balances: balancesApi,
      staleness: (groupId, localVersion) =>
          checkStaleness(pb, groupId: groupId, localVersion: localVersion),
      recomputeBalances: ledger.recompute,
      realtime: realtime,
    )..start();

    return SplitcoreSdk._(
      AuthApi(pb),
      GroupsRepository(db, groupsApi, sync),
      ExpensesRepository(db, expensesApi, sync, calc),
      SettlementsRepository(db, sync, calc),
      BalancesRepository(db),
      ExportApi(groupsApi, expensesApi, settlementsApi),
      sync,
      calc,
      db,
      shared,
    );
  }

  final AuthApi auth;
  final GroupsRepository groups;
  final ExpensesRepository expenses;
  final SettlementsRepository settlements;
  final BalancesRepository balances;

  /// Ledger export — see [ExportApi.groupToCsv].
  final ExportApi export;

  /// Sync state and control: `sync.events`, `sync.now()`.
  final SyncEngine sync;

  final SplitcoreCalc _calc;
  final SplitcoreDb _db;

  /// The one client every request shares. Nothing else may close it — see
  /// [_SharedClient].
  final http.Client _http;

  /// Stops the sync engine and releases the database handle and the shared
  /// connection pool. The SDK is unusable afterwards.
  Future<void> close() async {
    await sync.dispose();
    await _db.close();
    _http.close();
  }

  /// Suggests the minimal set of transfers to zero out [balances].
  Future<List<Transfer>> settleUp(List<Balance> balances) => _calc.settleUp(balances);

  /// Previews the per-member split for [spec] without writing anything —
  /// what createExpense computes internally, exposed so a UI can show the
  /// split live as the user edits it before saving.
  Future<List<Split>> previewSplit(SplitSpec spec) => _calc.computeSplits(spec);
}

/// Bounds every PocketBase request to [_timeout] — without this a dead/slow
/// server hangs requests (and their FutureBuilders) forever instead of
/// surfacing a retry-able error.
class _TimeoutClient extends http.BaseClient {
  _TimeoutClient(this._inner, this._timeout);
  final http.Client _inner;
  final Duration _timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(_timeout);
}

/// A disposable handle onto one long-lived client.
///
/// PocketBase builds a client per request and closes it when the request
/// finishes (pocketbase 0.22.0, client.dart:258 and :300), so every call
/// opened a fresh TCP connection and ran a fresh TLS handshake. Against a
/// server a quarter of a second away that is roughly 650ms of setup on top
/// of the round trip, and a first sync is dozens of calls: measured, the
/// same 36-request sync takes 31s connection-per-request and 9.7s over one
/// kept-alive connection.
///
/// [close] is therefore deliberately a no-op — the point is that
/// PocketBase's per-request teardown cannot tear down the pool the rest of
/// the SDK is relying on. The real client is released by
/// [SplitcoreSdk.close].
///
/// Safe for realtime too: the SSE client frees its socket by cancelling the
/// response stream subscription (pocketbase sse/sse_client.dart:107), not
/// by closing the http client.
class _SharedClient extends http.BaseClient {
  _SharedClient(this._inner);
  final http.Client _inner;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _inner.send(request);

  @override
  void close() {}
}
