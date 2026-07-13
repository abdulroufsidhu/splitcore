// Merges a group's expenses + settlements into one date-sorted feed —
// shared by the per-group inline list (group_detail.dart) and the global
// activity screen (screens/activity.dart).
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'display_name.dart';

enum ActivityKind { expense, settlement }

/// One row in an activity feed: an expense or a settlement, normalized to
/// the same shape so both can be sorted/rendered together.
class ActivityItem {
  const ActivityItem({
    required this.kind,
    required this.date,
    required this.groupId,
    required this.groupName,
    required this.currency,
    required this.title,
    required this.subtitle,
    required this.amountCents,
    this.expense,
  });

  final ActivityKind kind;
  final DateTime date;
  final String groupId;
  final String groupName;
  final String currency;
  final String title;
  final String subtitle;
  final int amountCents;

  /// Set for expense items only — lets the UI open its receipt on tap.
  final Expense? expense;
}

/// Builds a date-sorted (newest first) feed for one group's expenses and
/// settlements.
List<ActivityItem> buildActivity({
  required Group group,
  required List<GroupMember> members,
  required AppUser me,
  required List<Expense> expenses,
  required List<Settlement> settlements,
}) {
  String nameOf(String memberId) {
    for (final m in members) {
      if (m.id == memberId) return displayName(m, me);
    }
    return 'Someone';
  }

  final items = <ActivityItem>[
    for (final e in expenses)
      ActivityItem(
        kind: ActivityKind.expense,
        date: e.date,
        groupId: group.id,
        groupName: group.name,
        currency: group.currency,
        title: e.description,
        subtitle: '${nameOf(e.payerMemberId)} paid · split ${e.splitType}',
        amountCents: e.amountCents,
        expense: e,
      ),
    for (final s in settlements)
      ActivityItem(
        kind: ActivityKind.settlement,
        date: s.date,
        groupId: group.id,
        groupName: group.name,
        currency: group.currency,
        title: '${nameOf(s.fromMemberId)} paid ${nameOf(s.toMemberId)}',
        subtitle: 'Payment recorded',
        amountCents: s.amountCents,
      ),
  ];
  items.sort((a, b) => b.date.compareTo(a.date));
  return items;
}
