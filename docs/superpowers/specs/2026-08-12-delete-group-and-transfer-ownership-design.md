# Deleting a group, and handing it over

## Problem

A group is permanent. Nothing deletes one, and nothing moves its ownership.

The second gap makes the first worse. `groups.owner` is a required
non-cascading relation, and `groups.ListRule` is membership-based, so the
owner's membership row cannot be dropped without revoking their own access to
their own group. `remove-member` refuses it outright: *"the group owner cannot
leave or be removed."* An owner who wants out of a group has no move at all —
they can neither leave it nor delete it. Transfer is the missing exit.

## Deleting

Deletion is for everyone in the group, not just the owner. Every expense,
split, settlement and balance goes with it, on every member's device.

Only the group's owner may ask, and only when nobody owes anybody: any
`balances` row for the group with `net_cents != 0` refuses the delete. That is
the same rule already guarding `remove-member` and `leave group` — money is
settled before anyone walks away from it. The way out is always open: record
the settlements, or delete the expenses that created the debt.

### Server

Almost all of this already exists. `groups.DeleteRule` is
`owner = @request.auth.id`, and `OnRecordDelete("groups")` (hooks.go) already
pre-deletes the group's settlements inside the delete transaction so
PocketBase's alphabetical cascade does not trip over
`settlements.from_member` → `group_members`, which is Required and
non-cascading. `TestDeletePopulatedGroupSucceeds` covers it.

The only addition is the balance gate, at the top of that same hook:

```
DELETE /api/collections/groups/records/:id
  -> 204   deleted, with every child record
  -> 400   some member's balance is non-zero
  -> 404   not the owner (the delete rule's own answer)
```

The gate lives in the hook rather than in a new route because the hook is the
one place every delete path — SDK, admin UI, a future script — passes through.

### SDK

`GroupsApi.deleteGroup` calls the collection's delete.
`GroupsRepository.deleteGroup` wraps it exactly as `removeMember` does: drain
the outbox, refuse with `UnsyncedWritesException` if anything is still
`pending` or `conflict`, delete, then sync. Unsent work makes the balances the
server judges by untrustworthy, and a queued write against a group that is
about to vanish is a write that can never land.

Online-only, no outbox op — an optimistic offline delete could hide a group
and then be refused on replay.

Nothing new is needed locally. `_pull()` already calls
`deleteGroupsMissingFrom`, and the local schema carries
`ON DELETE CASCADE` with `PRAGMA foreign_keys = ON`, so members, expenses,
split entries, settlements, balances and `sync_state` all follow the group
out. That is also how *other* members learn: the group stops coming back from
`listMyGroups`, and their next pull drops it.

### UI

An overflow menu in the group-detail app bar, shown to the owner only, with a
single destructive **Delete group**. The confirmation names the group and says
plainly that it deletes for everyone and cannot be undone. An outstanding
balance or unsent writes are reported in place of the confirmation, never
after the tap. On success the screen pops back to the group list.

## Handing over

Transferring makes the named member the owner and demotes the caller to a
regular member. It moves no money, so nothing blocks it beyond permission.

Ownership cannot move through the collection API: `OnRecordUpdateRequest`
("groups") deliberately restores the stored `owner` on every PATCH, so the
field is unwritable by clients by design. Hence a route:

```
POST /api/splitcore/transfer-ownership   {"group_id": "...", "member_id": "..."}
  -> 200 {"status": "transferred"}
  -> 400 the member is deactivated, or already the owner
  -> 404 no such group or member, the member belongs to another group,
         or the caller does not own the group
```

Non-owners get 404 rather than 403, matching `remove-member`: the response
never confirms a group the caller cannot otherwise see.

One transaction sets `groups.owner`, promotes the new owner's
`group_members.role` to `owner`, and demotes the old owner's to `member`.
Those two member saves fire `memberBind`, which bumps `groups.version`, so
every client re-pulls the roster.

A deactivated member is refused: handing a group to someone the group has
already removed would resurrect them as its owner.

### UI

The member sheet already opened by tapping a card. For the owner, looking at
an active member who is not themselves, a secondary **Make owner** sits above
the destructive action. Confirming explains both halves — "X will own this
group. You will become a regular member and can then leave."

After it succeeds the screen closes. The group it was showing was passed in
as a snapshot whose `ownerId` decides the `OWNER` tag, the delete menu and
whether leaving is offered — all three of which just changed — and reloading
the screen's own data would not refresh any of them. Going back to the list,
which re-reads the group, is both cheaper and harder to get wrong. Reopening
the group shows the tag on its new holder, and the former owner's own sheet
now offers **Leave group** where it used to say *"You own this group, so you
can't leave it."*

## Testing

- **Go** — delete refuses while a balance is non-zero and succeeds once
  settled; transfer swaps both roles and sets `groups.owner`; version bumps;
  a non-owner caller gets 404; a member from another group gets 404; a
  deactivated member gets 400; transferring to the current owner gets 400.
- **Dart** — `deleteGroup` throws `UnsyncedWritesException` with queued work
  and leaves the group intact; after a successful delete the group and its
  children are gone from the local database; `transferOwnership` moves
  `Group.ownerId` for both the caller and another member's SDK.
- **Flutter** — the overflow menu is absent for non-owners; **Make owner** is
  absent on your own card, on the owner's card, and for non-owner callers; the
  confirmed paths call through; deletion pops the screen.
