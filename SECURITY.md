# Security Policy

## Reporting a vulnerability

Report privately via GitHub's **Security → Report a vulnerability** on
`abdulroufsidhu/splitcore`. Do not open a public issue for an unpatched
vulnerability. Expect an acknowledgement within 7 days.

Please include: what you can access that you should not, the steps to
reproduce it, and the affected component (`splitcore`, `server`,
`splitcore_sdk`, or `app`).

## Supported versions

Splitcore is pre-1.0. Only the `master` branch receives security fixes.

## Security model

- **Authentication** is PocketBase's `users` auth collection; the client
  holds a JWT persisted by the platform's shared-preferences store.
- **Authorization** is enforced by PocketBase collection rules, not by the
  client. Every collection is member-scoped: you can only list or view
  rows belonging to a group you are a member of. `groups` update/delete is
  owner-only. `balances` has no client-facing write rule at all — only the
  server-side recompute hook can write it.
- **Server-side validation** in `server/hooks/` is authoritative. The
  client computes splits locally for a responsive UI, but the server
  re-validates every write; a malicious client cannot write a split that
  disagrees with the engine.
- **Trust boundary:** treat everything from the client as hostile. Any new
  hook that reads a client-supplied id must re-check group membership.

## Deployment expectations

- **Always terminate TLS** in front of the server. PocketBase serves plain
  HTTP by default; a token sent over HTTP is a token stolen.
- Change the default superuser credentials before exposing the admin UI.
- Restrict `/_/` (the admin UI) at the reverse proxy to trusted addresses.
- Back up `pb_data/` — it holds the SQLite database *and* uploaded
  receipts. See `docs/deployment.md`.
