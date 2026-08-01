// Member display names. GroupsApi.listMembers resolves each member's name
// via the server's /api/splitcore/members route (see server/hooks/members.go),
// which is allowed to read every group member's profile because it checks
// group membership itself — PocketBase's default `users` rules would 404 a
// direct cross-user lookup.
//
// ponytail: falls back to a short id tag when a member hasn't set a name
// yet. Good enough until "no name set" is common enough to want a nicer nudge.
import 'package:splitcore_sdk/splitcore_sdk.dart';

String displayName(GroupMember member, AppUser? me) {
  if (me != null && member.userId == me.id) return 'You';
  if (member.name.isNotEmpty) return member.name;
  final tag = member.userId.length >= 4 ? member.userId.substring(0, 4) : member.userId;
  return 'Member $tag';
}

String initialsFor(GroupMember member, AppUser? me) {
  if (me != null && member.userId == me.id) return meInitial(me);
  if (member.name.isNotEmpty) return member.name[0].toUpperCase();
  return member.userId.isNotEmpty ? member.userId[0].toUpperCase() : '?';
}

String meInitial(AppUser? me) => (me != null && me.name.isNotEmpty)
    ? me.name[0].toUpperCase()
    : (me != null && me.email.isNotEmpty)
        ? me.email[0].toUpperCase()
        : 'Y';

/// Looks up a member by user id or member id — null if not found, e.g. the
/// current user's membership hasn't propagated yet, or a stale id from a
/// snapshot taken before someone left. Callers should handle null instead of
/// crashing (see the old `firstWhere` sites this replaces).
GroupMember? memberFor(List<GroupMember> members, String id) {
  for (final m in members) {
    if (m.userId == id || m.id == id) return m;
  }
  return null;
}

/// The other member of a direct (1:1) group, from [me]'s point of view —
/// null if they haven't joined yet (pending invite).
GroupMember? otherMember(List<GroupMember> members, AppUser me) {
  final others = members.where((m) => m.userId != me.id);
  return others.isEmpty ? null : others.first;
}

/// Resolves a direct group's display name from the viewer's side: the other
/// member's name (or a "Member" id tag, same fallback as any other member —
/// see [displayName]), or — if they haven't joined yet — the name the
/// creator typed at invite time, still encoded as "Person | Me" by
/// home.dart's "Add person" flow.
String directPersonName(List<GroupMember> members, AppUser me, String groupName) {
  final other = otherMember(members, me);
  if (other == null) return groupName.split('|').first.trim();
  return displayName(other, me);
}
