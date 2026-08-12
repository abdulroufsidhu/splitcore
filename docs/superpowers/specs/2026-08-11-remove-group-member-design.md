# Removing a group member

## Problem

There is no way to remove someone from a group. The plumbing exists —
`GroupsApi.removeMember` issues a `DELETE` on `group_members`, and the
collection's `DeleteRule` is `group.owner = @request.auth.id` — but nothing
in the app calls it, and for most members it would fail anyway.

Every relation pointing at `group_members` is Required with
`CascadeDelete=false`: `expenses.payer`, `split_entries.member`,
`settlements.from_member` / `to_member`, `balances.member`. So the moment
someone appears in a single expense, PocketBase physically refuses to delete
their membership row. `server/hooks/account.go` already documents this
constraint and works around it for "delete my account" by anonymizing the
user instead of deleting the row.

## Behaviour

Outstanding money is the only thing that blocks a removal. History is always
preserved.

| Member's state | Result |
|---|---|
| Net balance ≠ 0 | Refused: "settle up first" |
| Balance 0, has ledger history | Deactivated — row stays, hidden from the app |
| Balance 0, no history | Deleted outright |

Deactivation keeps the row so that the member's past expenses, split entries
and settlements stay valid, and so every *other* member's balance stays
correct. A hard delete is reserved for the case where there is genuinely
nothing to preserve, so a mistaken invite leaves no trace.

Removing yourself is the same operation, exposed as "leave group": the same
row, the same rules, the same two outcomes. Only who may ask differs.

Two removals are always rejected:

- **The group owner**, whether removed by themselves or anyone else.
  `groups.owner` is a required non-cascading relation to `users`, and
  removing the owner's membership would revoke their own read access to the
  group (`groups.ListRule` is membership-based). Owners hand a group over or
  delete it.
- **By anyone who neither owns the group nor is the member in question.**

Re-adding a deactivated member by email reactivates the existing row. Without
this, deactivation is a one-way door and a misclick is unrecoverable.

## Server

`group_members` gains **`removed_at`** — an optional Date field where empty
means active. A newly added field is empty on every existing row, so all
current memberships read as active with no backfill.

Removal becomes a route rather than a delete rule, because it needs the
balance check and the delete-or-deactivate decision:

```
POST /api/splitcore/remove-member   {"member_id": "..."}
  (caller must own the group, or name their own membership)
  -> 200 {"status": "removed"}      row deleted
  -> 200 {"status": "deactivated"}  removed_at set
  -> 400                            outstanding balance, or the owner
  -> 404                            no such member, or caller may not touch it
```

This mirrors `POST /api/splitcore/delete-account` and reuses its
`memberNetCents`. The per-member half of `memberHasLedgerHistory` is
extracted as `memberReferenced(app, memberID)` so both callers share one
definition of "has history".

`memberBind` in `hooks.go` gains `OnRecordUpdate("group_members")`, so
deactivating a member bumps `groups.version` the same way adding or deleting
one does. Without the bump, no client ever learns the roster changed.

`/api/splitcore/members` returns `removed_at` on each row.

## SDK

- `GroupsApi.removeMember` calls the route and returns the status string.
- `GroupMember` gains `isActive`.
- `listMembers` returns **active members only**. Every existing caller —
  split pickers, settle-up, balances, member counts — already assumes that,
  so filtering at the source means no call site can silently regress.
  `listAllMembers` backs the one screen that shows former members.
- The local `members` table gains the column through `migrations[2]`;
  `schemaVersion` goes to 2. The migration ladder is append-only.

Removal is **online-only** — no outbox op. The balance gate lives on the
server, so an optimistic offline removal could show someone as gone and then
be refused on replay. `inviteOrAddMember` is already online-only for the same
reason. (`OutboxOps.memberRemove` is an existing dangling constant, never
enqueued and never applied; it is left untouched rather than expanding
scope.)

## UI

Tapping a member card in the group detail screen opens a sheet showing the
member's avatar, name, role and current balance. A destructive **Remove from
group** sits at the bottom, and its state carries the rules:

- Acting on yourself → the button reads **Leave group**, and the screen
  closes behind you once it succeeds.
- Acting on someone else without owning the group, or the target *is* the
  owner → no button at all.
- Target owes or is owed money → disabled, with the reason spelled out.
- Otherwise → tapping raises a confirmation dialog.

The success message distinguishes the two outcomes: "Alice removed" versus
"Alice removed — their past expenses stay in this group's history."

Each member card carries an `OWNER` tag when it belongs to the group's
owner. The label is rendered blank for everyone else rather than omitted, so
every card keeps the same height in the horizontal strip.

Below the member strip, a muted "Former members: …" line appears when any
deactivated members exist, so a removed person does not silently vanish.

## Accepted consequence

A deactivated member's row still exists, so the membership-based list rule
still grants them read access to that group's data. They keep seeing history
they were part of, though the app hides the group from their own list.
Locking them out would require deleting the row, which is precisely what the
foreign keys forbid. Splitwise behaves the same way.

## Testing

- **Go** — refuse on non-zero balance; deactivate when history exists; hard
  delete when it does not; reject a non-owner caller; reject removing the
  owner; re-add clears `removed_at`; `groups.version` bumps on both paths.
- **Dart** — `listMembers` excludes deactivated members, `listAllMembers`
  includes them; `removeMember` returns the server's status.
- **Flutter** — the button is absent when the caller may not act and when the
  target is the owner, reads "Leave group" on your own row, is withheld with a
  reason when money is outstanding or writes are unsent, and the confirmed
  path calls through. The owner tag appears on exactly one card.
