// Last-known-good data, so a failed load shows yesterday's numbers with a
// banner instead of an error screen. Reads only: writes made offline are
// not queued, and the UI must not pretend otherwise.
//
// The SDK's LocalStore is in-memory and dies with the process, which is
// exactly the case that matters here — the user reopens the app on a train.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// The subset of a group needed to render the home list offline.
class GroupSummary {
  const GroupSummary({
    required this.id,
    required this.name,
    required this.currency,
    required this.myNetCents,
    required this.memberCount,
  });

  final String id;
  final String name;
  final String currency;
  final int myNetCents;
  final int memberCount;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'currency': currency,
    // Minor units as an int — never a double. A ledger denominated in
    // cents outgrows a double's exact-integer range sooner than it looks.
    'myNetCents': myNetCents,
    'memberCount': memberCount,
  };

  static GroupSummary fromJson(Map<String, Object?> json) => GroupSummary(
    id: json['id']! as String,
    name: json['name']! as String,
    currency: json['currency']! as String,
    myNetCents: (json['myNetCents']! as num).toInt(),
    memberCount: (json['memberCount']! as num).toInt(),
  );
}

class OfflineCache {
  OfflineCache(this._prefs);

  final SharedPreferences _prefs;

  static const _groupsKey = 'offline_groups_v1';
  static const _updatedKey = 'offline_groups_v1_at';

  Future<void> putGroups(List<GroupSummary> groups) =>
      _prefs.setString(_groupsKey, jsonEncode([for (final g in groups) g.toJson()]));

  /// The cached list, or null when nothing is cached or the cached blob no
  /// longer parses. A stale cache from an older app version is not worth a
  /// crash — dropping it costs one network fetch.
  List<GroupSummary>? groups() {
    final raw = _prefs.getString(_groupsKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as List<Object?>;
      return [for (final item in decoded) GroupSummary.fromJson(item! as Map<String, Object?>)];
    } catch (_) {
      return null;
    }
  }

  /// When the cached data was last known good, for the "showing data from
  /// ..." banner. Null when nothing has been cached.
  DateTime? get lastUpdated {
    final millis = _prefs.getInt(_updatedKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> markUpdated() => _prefs.setInt(_updatedKey, DateTime.now().millisecondsSinceEpoch);
}
