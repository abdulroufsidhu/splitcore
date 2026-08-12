# splitcore server

A PocketBase backend for splitcore: expense-splitting groups, members,
expenses, split entries, settlements, and a server-computed balances
cache — all guarded by member-only PocketBase collection rules, with
domain validation, a per-group version counter, and balance recompute
wired in as record hooks.

## Running

```bash
cd server
go run . serve --http=0.0.0.0:8090
```

Serves on `http://0.0.0.0:8090` (API at `/api/`, admin UI at `/_/`).

Without `--http`, PocketBase binds `127.0.0.1` only, and a phone, emulator,
or Waydroid guest cannot reach it. Point the app at the host address the
guest sees: `192.168.240.1` (Waydroid gateway), `10.0.2.2` (Android
emulator), or the machine's LAN IP for a physical device.

Migrations (`migrations/1751760000_init_collections.go`) create all six
collections on first run. Under `go run`, `main.go` detects it's running
from a temp build (`os.Args[0]` prefixed with the OS temp dir) and enables
PocketBase's `migratecmd` **automigrate**, so pending migrations apply
automatically on `serve` — no extra step needed for local dev.

For a compiled binary (`go build && ./server serve`), automigrate is off;
apply migrations explicitly first:

```bash
go run . migrate up
./server serve
```

PocketBase's admin UI is served at `/_/` once the server is running; use
it to create the first superuser (`./server superuser upsert <email> <password>`
works too, non-interactively).

## Collections

| Collection | Purpose | Access rule shape |
|---|---|---|
| `groups` | An expense-splitting group: name, currency, owner, and a `version` counter bumped on every mutation. | List/View: member-only. Create: any authenticated user (becomes owner). Update/Delete: owner-only. |
| `group_members` | Join table linking a `groups` row to a `users` row with a `role` (`owner`/`member`). | List/View: member-only. Create/Update/Delete: group owner-only. |
| `expenses` | A single expense paid by one member, split across members via `split_entries`. | List/View/Create/Update/Delete: member-only (checked against the expense's `group`). |
| `split_entries` | One member's share of an `expenses` row, in cents; optional receipt file. | Member-only, checked transitively via the parent expense's group. |
| `settlements` | A direct payment between two members that offsets their balances. | Member-only (checked against the settlement's `group`). |
| `balances` | Server-computed net balance per member per group (cache only — see below). | List/View: member-only. Create/Update/Delete: no rule set — only a superuser or the server-side recompute hook can write it; regular API clients always get `403`. |

## Staleness endpoint

`GET /api/splitcore/staleness?group=<id>&version=<int>`

Lets a client with a cached group snapshot check in O(1) whether it's
still current, without re-fetching expenses/splits/settlements/balances.

- Requires authentication (`401` if missing).
- `group` and an integer `version` query param are required (`400` if
  either is missing/invalid).
- The caller must be a member of `group` — both an unknown group id and a
  known group the caller doesn't belong to return `404` (existence is
  never leaked to non-members).
- On success (`200`):
  ```json
  { "current": true, "serverVersion": 3 }
  ```
  `current` is `clientVersion == serverVersion`; `serverVersion` is the
  group's current `version` counter so the client knows what to compare
  against (and can decide whether to re-fetch).

## Incomplete-expense semantics

An expense is **complete** only once its `split_entries` amounts sum
exactly to the expense's `amount_cents`. Balance recompute
(`hooks/recompute.go`) skips any expense that isn't complete yet — it
contributes nothing to `balances` until the client finishes writing all
of its split entries. This lets a client create an expense and its splits
as separate requests without a transient, incorrect balance appearing in
between.

## Balances are cache-only

`balances` rows are a server-maintained cache, rewritten from scratch
(delete + reinsert, one row per member) inside a single transaction every
time an `expenses`, `split_entries`, or `settlements` record is created,
updated, or deleted (`hooks/recompute.go`). The same transaction also
bumps the group's `version` counter. Clients must not treat `balances` as
the source of truth to write to — the collection has no client-facing
create/update/delete rule, so any such attempt is rejected with `403`.
Clients that need to compute or verify balances locally (e.g. for
optimistic UI or offline use) should use the `splitcore` Go module
(`splitcore/balance`) directly against their locally cached
expenses/splits/settlements, and use the staleness endpoint above to know
when that local computation is out of date.

## Account deletion semantics

`POST /api/splitcore/delete-account` closes the **caller's own** account. It
takes no user id, so there is nothing to authorize beyond being signed in.

It has two outcomes, and the client must tell the user which one happened:

| Response | When | Effect |
|---|---|---|
| `{"status":"deleted"}` | The user owns no group and appears in no expense, split, or settlement | Memberships removed, `users` row erased |
| `{"status":"anonymized"}` | The user owns a group, or appears anywhere in the ledger | `users` row kept but stripped: tombstone email, no name or avatar, unverified, unusable password. Memberships and history untouched |

Both refuse with `400` while any of the user's memberships carries a
non-zero balance — leaving with money owed silently shifts the debt onto
everyone else in the group.

**Why anonymize rather than delete.** Every relation pointing at
`group_members` — `expenses.payer`, `split_entries.member`,
`settlements.from_member`/`to_member`, `balances.member` — is `Required`
with `CascadeDelete: false`, and both `group_members.user` and
`groups.owner` reference `users` the same way. So for anyone who has
participated: the `users` row cannot be deleted (a membership references
it), the membership cannot be deleted (split entries reference it), and
deleting those split entries would rewrite *other members'* balances and
erase shared history that is not this user's to destroy.
