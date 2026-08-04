// Regression test for the 1:1 group naming bug: both sides of a direct
// group must resolve to the OTHER person, not "whoever's name comes first
// in the stored string." See display_name.dart's directPersonName.
import 'package:flutter_test/flutter_test.dart';
import 'package:splitcore_sdk/splitcore_sdk.dart';

import 'package:splitcore_app/display_name.dart';

void main() {
  final owner = AppUser(id: 'owner-1', email: 'owner@example.com', name: 'Owner Olivia');
  final friend = AppUser(id: 'friend-1', email: 'friend@example.com', name: 'Friend Fatima');

  final members = [
    GroupMember(id: 'm1', groupId: 'g1', userId: owner.id, role: 'owner', name: owner.name),
    GroupMember(id: 'm2', groupId: 'g1', userId: friend.id, role: 'member', name: friend.name),
  ];

  test('owner and friend resolve to opposite people for the same direct group', () {
    expect(directPersonName(members, owner, 'Friend Fatima'), 'Friend Fatima');
    expect(directPersonName(members, friend, 'Friend Fatima'), 'Owner Olivia');
  });

  test('falls back to the creator-typed name when the other person has not joined yet', () {
    final pending = [members.first]; // only the owner has a group_members row so far
    expect(directPersonName(pending, owner, 'Friend Fatima'), 'Friend Fatima');
  });

  test('falls back to a member id tag when the other person has not set a name', () {
    final noName = [
      members.first,
      GroupMember(id: 'm2', groupId: 'g1', userId: friend.id, role: 'member'),
    ];
    expect(directPersonName(noName, owner, 'Friend Fatima'), 'Member frie');
  });

  group('memberFor', () {
    test('finds by userId or by member id', () {
      expect(memberFor(members, owner.id)?.id, 'm1');
      expect(memberFor(members, 'm2')?.id, 'm2');
    });

    test('returns null instead of throwing when no member matches', () {
      // Regression: this used to be a `firstWhere` that crashed the whole
      // screen when membership hadn't propagated yet.
      expect(memberFor(members, 'not-a-member'), isNull);
      expect(memberFor(<GroupMember>[], owner.id), isNull);
    });
  });
}
