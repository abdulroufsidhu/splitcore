// In-memory, version-tagged, per-group snapshot cache. No persistence in
// v1 — everything is fetch-on-demand and lost on process restart; the
// interface is deliberately narrow so a persistent-cache implementation
// could be swapped in later without touching callers.
import '../models.dart';

class GroupSnapshot {
  const GroupSnapshot({required this.version, required this.balances});

  final int version;
  final List<Balance> balances;

  @override
  bool operator ==(Object other) =>
      other is GroupSnapshot && other.version == version && _listEquals(other.balances, balances);

  @override
  int get hashCode => Object.hash(version, Object.hashAll(balances));

  static bool _listEquals(List<Balance> a, List<Balance> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class LocalStore {
  final Map<String, GroupSnapshot> _snapshots = {};

  GroupSnapshot? snapshotFor(String groupId) => _snapshots[groupId];

  void put(String groupId, GroupSnapshot snapshot) => _snapshots[groupId] = snapshot;
}
