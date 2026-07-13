// Reads the server's cached `balances` collection — never client-writable,
// hook-rewritten on every expense/split_entries/settlements mutation (see
// server/hooks/hooks.go). This is the default read path; recompute-from-log
// is reserved for the staleness-triggered resync in SettlementsApi.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

class BalancesApi {
  BalancesApi(this._pb);

  final PocketBase _pb;

  Future<List<Balance>> getBalances(String groupId) async {
    final records = await _pb.collection('balances').getFullList(filter: "group = '$groupId'");
    return [
      for (final r in records)
        Balance(memberId: r.getStringValue('member'), netCents: r.getIntValue('net_cents')),
    ];
  }
}
