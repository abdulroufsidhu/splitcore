// The public read path for balances. No writes: balances are derived
// server-side (server/hooks/recompute.go) and a pull replaces them.
import '../local/dao/balance_dao.dart';
import '../local/database.dart';
import '../models.dart';

class BalancesRepository {
  BalancesRepository(this._db);

  final SplitcoreDb _db;

  Stream<List<Balance>> watch(String groupId) =>
      _db.watch({'balances'}, () => BalanceDao(_db).listBalances(groupId));

  /// The current balances, for callers that want a value rather than a
  /// subscription — settleUp's input, and tests.
  Future<List<Balance>> get(String groupId) async => BalanceDao(_db).listBalances(groupId);
}
