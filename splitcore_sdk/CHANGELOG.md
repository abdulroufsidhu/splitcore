# Changelog

## 0.2.0

**Breaking:** reads are local-first and reactive. `sdk.groups`, `sdk.expenses`,
`sdk.settlements` and `sdk.balances` are now repositories backed by a local
SQLite mirror rather than direct PocketBase clients. Replace
`await sdk.expenses.listExpenses(id)` with `sdk.expenses.watch(id)` to
re-render when a sync writes; the `Future` variants remain and read the same
local rows. `Page<T>` is gone from these APIs — local rows have no request to
economise on.

- Local-first writes. Every write commits to the local database and queues an
  outbox op; nothing waits on the network. Expenses, settlements, groups,
  members and receipts all work with no connection.
- Event-driven sync. The engine wakes on a connectivity transition, a local
  write, a PocketBase realtime event, or `sync.now()` — never on a schedule.
  The only timer is post-failure backoff.
- Conflict detection. A queued edit records the server `updated` it was built
  on; if the server has moved, the op parks and surfaces on `sync.events`
  instead of overwriting. Settle with `sync.resolve(seq, keepLocal:)`.
- Receipts queue by file path. If the file is gone at upload time the row
  still syncs and a `ReceiptMissing` event reports the loss.
- `ConnectivityMonitor` is injected by the caller (the package stays pure
  Dart); `FileTokenStore` ships as a working default.
- **Fixed:** a failed session refresh cleared the auth store on any error, so
  launching without a connection signed the user out. Only 401/403 clears it.

Requires a server with the `expenses.updated` autodate field
(`server/migrations/1754400000_expense_autodate.go`) — conflict detection has
no base without it. On Android and iOS the host app must depend on
`sqlite3_flutter_libs`.

## 0.1.0

- First release: split/settlement/balance math over the splitcore FFI library,
  plus PocketBase-backed groups, expenses, settlements and receipts.
