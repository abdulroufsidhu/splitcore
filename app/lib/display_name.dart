// Member display names. The backend only exposes {id, email} for a user
// (see splitcore_sdk AppUser/GroupMember) and PocketBase's default `users`
// rules block looking up anyone else's record by id/email (verified: a
// signed-in user gets 404 querying another user), so a GroupMember we don't
// own only ever gives us a userId, never a name or email.
//
// ponytail: falls back to a short id tag for non-self members. Real names
// need a public-readable profile field (e.g. `display_name` on `users`, or
// a members-of-my-groups view) — add server-side when that matters more
// than shipping the UI.
import 'package:splitcore_sdk/splitcore_sdk.dart';

String displayName(GroupMember member, AppUser? me) {
  if (me != null && member.userId == me.id) return 'You';
  final tag = member.userId.length >= 4 ? member.userId.substring(0, 4) : member.userId;
  return 'Member $tag';
}

String initialsFor(GroupMember member, AppUser? me) {
  if (me != null && member.userId == me.id) return meInitial(me);
  return member.userId.isNotEmpty ? member.userId[0].toUpperCase() : '?';
}

String meInitial(AppUser? me) =>
    (me != null && me.email.isNotEmpty) ? me.email[0].toUpperCase() : 'Y';
