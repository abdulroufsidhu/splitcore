// Thin wrapper over GET /api/splitcore/staleness (server/hooks/staleness.go)
// — an O(1) metadata check, never a full recompute.
import 'package:pocketbase/pocketbase.dart';

import '../models.dart';

Future<StalenessResult> checkStaleness(
  PocketBase pb, {
  required String groupId,
  required int localVersion,
}) async {
  final response = await pb.send<Map<String, dynamic>>(
    '/api/splitcore/staleness',
    query: {'group': groupId, 'version': localVersion.toString()},
  );
  return StalenessResult(
    current: response['current'] as bool,
    serverVersion: response['serverVersion'] as int,
  );
}
