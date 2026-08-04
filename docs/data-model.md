# Data model

Seven collections, defined as code in [server/migrations/](../server/migrations/).
PocketBase's built-in `users` auth collection is the eighth, unmodified except
that the app writes `name` and `avatar` on it.

## Source of truth

```
  source of truth                     derived cache
  ───────────────                     ─────────────
  expenses                            balances
  split_entries      ── recompute ──▶ (one row per member per group,
  settlements                          rewritten from scratch, never
                                       client-writable)
```

`balances` is never authoritative. Delete every row and the next mutation
rebuilds them exactly. If a stored balance ever disagrees with a recompute, the
recompute is right.

## Collections

### `groups`

| Field | Type | Notes |
|---|---|---|
| `name` | text, required, ≤200 | |
| `currency` | text, required, exactly 3 | ISO 4217 code. A label — no conversion logic exists |
| `version` | number, int | Monotonic counter. Hook-managed; client writes are overwritten |
| `owner` | relation → `users`, required | Set server-side from the authenticated user on create |
| `is_direct` | bool | Marks a 1:1 "person" group so the UI renders a name + avatar instead of a group |

Rules — List/View: member-only. Create: any authenticated user. Update/Delete:
`owner = @request.auth.id`.

`is_direct` is purely cosmetic. A direct group has the identical schema, rules,
expense machinery, and settlement flow as any other group; only the rendering
differs. That is the cheap version of "add a friend" — no separate entity, no
friends graph.

On create the hook forces `owner` to the authenticated user and `version` to 0,
then creates the owner's `group_members` row. On update it restores the stored
`version` and `owner` before saving, so neither can be climbed by a client. If
the stored record cannot be read, the update fails closed rather than proceeding
with the guard unapplied.

### `group_members`

| Field | Type | Notes |
|---|---|---|
| `group` | relation → `groups`, required | cascade delete |
| `user` | relation → `users`, required | no cascade |
| `role` | select: `owner` \| `member`, required | |

Unique index on `(group, user)`.
Rules — List/View: member-only. Create/Update/Delete: `group.owner = @request.auth.id`.

**A `group_members` row id — not a user id — is what expenses, settlements, and
balances reference.** Every money-facing id in the system is a membership id.
This keeps the `splitcore` engine free of any notion of a user account: it deals
in opaque member strings.

### `expenses`

| Field | Type | Notes |
|---|---|---|
| `group` | relation → `groups`, required | cascade delete |
| `payer` | relation → `group_members`, required | exactly one payer |
| `description` | text, ≤500 | |
| `amount_cents` | number, int | must be positive (hook-enforced) |
| `split_type` | select: `equal` \| `exact` \| `percent` \| `shares` | |
| `date` | date | |

Rules: member-only on all five operations.

One payer per expense, always. Two people paying for one dinner is two expenses.
A payer field that could hold several people means every split function needs to
know how much each of them put in, which is a second split problem hiding inside
the first.

### `split_entries`

| Field | Type | Notes |
|---|---|---|
| `expense` | relation → `expenses`, required | cascade delete |
| `member` | relation → `group_members`, required | |
| `amount_cents` | number, int | must be ≥ 0 (zero is legal — see below) |
| `receipt` | file, ≤10 MB, jpeg/png/webp/pdf | optional |

Rules: member-only, checked transitively through the parent expense's group.

Zero-amount entries are allowed on purpose: a member can be listed on a bill
while owing nothing on it. This matches exact-split semantics, and is asymmetric
with expenses (which must be strictly positive) by design.

### `settlements`

| Field | Type | Notes |
|---|---|---|
| `group` | relation → `groups`, required | cascade delete |
| `from_member` | relation → `group_members`, required | |
| `to_member` | relation → `group_members`, required | must differ from `from_member` |
| `amount_cents` | number, int | must be positive |
| `date` | date | |
| `note` | text, ≤500 | |

Rules: member-only on all five operations.

A settlement records that money changed hands outside the app. No payment
processing exists. Any positive amount is accepted, including more than what is
owed — overpaying simply flips the balance direction, which is what actually
happens in real life when someone rounds up.

### `balances`

| Field | Type | Notes |
|---|---|---|
| `group` | relation → `groups`, required | cascade delete |
| `member` | relation → `group_members`, required | |
| `net_cents` | number, int | positive = is owed money, negative = owes |

Unique index on `(group, member)`.
Rules — List/View: member-only. **Create/Update/Delete: no rule at all**, which
in PocketBase means only a superuser or server-side code can write. Any client
attempt returns `403`.

### `invites`

| Field | Type | Notes |
|---|---|---|
| `email` | email, required | |
| `group` | relation → `groups`, required | cascade delete |
| `invited_by` | relation → `users`, required | |
| `role` | select: `owner` \| `member`, required | |
| `status` | select: `pending` \| `accepted`, required | |

Rules — List/View: member-only (so a group can see its pending invites).
Create/Update/Delete: `group.owner = @request.auth.id`. In practice both writes
happen server-side from `/api/splitcore/invite` and the users-create hook, which
run as the app and bypass client rules entirely; the owner-only rules just close
off direct client writes.

## The access-rule pattern

Three filter expressions cover every collection:

```
memberRule           @request.auth.id != "" && @collection.group_members.group ?= group
                                            && @collection.group_members.user  ?= @request.auth.id
memberRuleViaID      … same, but ?= id             (for `groups` itself)
memberRuleViaExpense … same, but ?= expense.group  (for `split_entries`)
```

One idea — "you must have a membership row for this record's group" — expressed
three ways because the path to the group id differs. Non-members do not get a
filtered result; they get nothing, and `/api/splitcore/staleness` returns `404`
for both an unknown group and a real group the caller does not belong to, so
existence is never leaked.

## Referential integrity, and one sharp edge

Cascade deletes are set on the `group` relations (and `split_entries.expense`),
but *not* on the member relations — `expenses.payer`, `split_entries.member`,
`settlements.from_member` / `to_member` all point at `group_members` without
cascade. Deleting a member with history would orphan records, so PocketBase
refuses.

That creates an ordering problem when a whole group is deleted. PocketBase
cascades in alphabetical collection order: `balances`, `expenses`,
`group_members`, `settlements`. By the time `group_members` is deleted,
`expenses` (and their split entries) are already gone — `expenses` sorts first.
But `settlements` sorts *after* `group_members`, so its rows are still live and
still reference member rows the cascade is trying to delete, and the whole
delete fails.

The fix, in the `groups` delete hook: explicitly delete the group's settlements
before the group row hits the database. That pre-delete and the group delete
share one transaction, because the hook fires in the validation phase before
PocketBase opens its own — without the explicit transaction, a failed group
delete would leave the settlements permanently gone while the group survived.

## Incomplete expenses

PocketBase has no batch create, so a client writes an expense and then its split
entries one request at a time. In between, the expense's splits do not sum to
its amount.

The recompute skips any expense whose split entries do not sum exactly to
`amount_cents`. It contributes nothing to `balances` until it is complete. No
transient wrong balance ever appears, and no client-side transaction protocol is
needed — the completeness check *is* the protocol.
