// The sole facade a Flutter app should ever import. Wires the compute
// layer (SplitcoreCalc) and the PocketBase remote layer together; the
// frontend never talks to PocketBase or does split math directly.
import 'package:http/http.dart' as http;
import 'package:pocketbase/pocketbase.dart';

import 'calc_api.dart';
import 'models.dart';
import 'remote/auth_api.dart';
import 'remote/balances_api.dart';
import 'remote/expenses_api.dart';
import 'remote/groups_api.dart';
import 'remote/local_store.dart';
import 'remote/settlements_api.dart';

class SplitcoreSdk {
  SplitcoreSdk._(
    this.auth,
    this.groups,
    this.expenses,
    this.settlements,
    this.balances,
    this._calc,
  );

  /// Opens the splitcore native library at [libraryPath] and connects to
  /// the PocketBase server at [pocketbaseUrl]. Every sub-API below shares
  /// the same PocketBase client (so signing in on [auth] authenticates
  /// [groups], [expenses], etc.) and the same compute engine.
  ///
  /// Pass [authStore] (e.g. an `AsyncAuthStore` backed by `shared_preferences`)
  /// to persist the signed-in session across app restarts; defaults to
  /// PocketBase's in-memory store, which forgets sign-in on every launch.
  factory SplitcoreSdk.initialize({
    required String pocketbaseUrl,
    required String libraryPath,
    AuthStore? authStore,
  }) {
    final pb = PocketBase(
      pocketbaseUrl,
      authStore: authStore,
      httpClientFactory: () => _TimeoutClient(http.Client(), const Duration(seconds: 15)),
    );
    final calc = SplitcoreCalc.open(libraryPath);
    final store = LocalStore();
    return SplitcoreSdk._(
      AuthApi(pb),
      GroupsApi(pb),
      ExpensesApi(pb, calc),
      SettlementsApi(pb, calc, store),
      BalancesApi(pb),
      calc,
    );
  }

  final AuthApi auth;
  final GroupsApi groups;
  final ExpensesApi expenses;
  final SettlementsApi settlements;
  final BalancesApi balances;
  final SplitcoreCalc _calc;

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
