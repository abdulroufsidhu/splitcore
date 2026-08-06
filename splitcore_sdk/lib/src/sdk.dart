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
import 'repo/settlements_repository.dart';
import 'sync/connectivity.dart';
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
    final pb = PocketBase(
      pocketbaseUrl,
      authStore: tokenStore == null ? null : asAuthStore(tokenStore),
      httpClientFactory: () => _TimeoutClient(http.Client(), const Duration(seconds: 15)),
    );
    final calc = SplitcoreCalc.open(libraryPath);
    final db = databasePath == null ? SplitcoreDb.inMemory() : SplitcoreDb.openAt(databasePath);

    final groupsApi = GroupsApi(pb);
    final expensesApi = ExpensesApi(pb, calc);
    final balancesApi = BalancesApi(pb);
    // Late-bound: the API needs the engine to resync a stale group, and the
    // engine needs the API to list settlements. The cycle is broken by the
    // callback rather than by a second copy of either.
    late final SyncEngine sync;
    final settlementsApi = SettlementsApi(pb, (groupId) => sync.pullGroupIfStale(groupId));

    sync = SyncEngine(
      db: db,
      connectivity: connectivity ?? AlwaysOnline(),
      groups: groupsApi,
      expenses: expensesApi,
      settlements: settlementsApi,
      balances: balancesApi,
      staleness: (groupId, localVersion) =>
          checkStaleness(pb, groupId: groupId, localVersion: localVersion),
    )..start();

    return SplitcoreSdk._(
      AuthApi(pb),
      GroupsRepository(db, groupsApi, sync),
      ExpensesRepository(db, expensesApi, sync),
      SettlementsRepository(db, settlementsApi, sync),
      BalancesRepository(db),
      ExportApi(groupsApi, expensesApi, settlementsApi),
      sync,
      calc,
      db,
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

  /// Stops the sync engine and releases the database handle. The SDK is
  /// unusable afterwards.
  Future<void> close() async {
    await sync.dispose();
    await _db.close();
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
