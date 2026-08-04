# SlicePay — Project Wiki

SlicePay is a Splitwise-style expense-splitting app: groups of people record
shared expenses, the app works out who owes whom, and settlements ("I paid you
back") clear the balances.

It is a monorepo with four deliverables and one hard architectural rule:
**there is exactly one implementation of the money math, and both the server
and the client run that same compiled code.**

```
slice_pay/
├── splitcore/       Pure Go. Split/settle/balance math. Zero framework deps.
│   └── ffi/         cgo shim → libsplitcore.so / .a  (JSON in, JSON out)
├── server/          Go + PocketBase. Schema, access rules, hooks, 3 custom routes.
├── splitcore_sdk/   Dart package. FFI to libsplitcore + all PocketBase traffic.
└── app/             Flutter app. Talks only to splitcore_sdk. Never to PocketBase.
```

## Wiki pages

| Page | What's in it |
|---|---|
| [architecture.md](architecture.md) | The four layers, what each owns, why the boundaries sit where they do |
| [data-model.md](data-model.md) | Every collection, field, and access rule |
| [data-flow.md](data-flow.md) | End-to-end traces: create expense, settle up, invite, receipts, auth |
| [decisions.md](decisions.md) | Every non-obvious choice and the reasoning behind it |
| [development.md](development.md) | Build, run, test, cross-compile, and the traps that cost time |
| [api-reference.md](api-reference.md) | Custom HTTP routes + the SDK's public Dart surface |

Historical records live in [superpowers/](superpowers/): the original approved
design spec and the three implementation plans, kept as-is. They describe the
project as it was planned; the pages above describe it as it is.

## The one-paragraph version

Money is `int64` minor units (cents) everywhere — never a float. The record set
(expenses + split entries + settlements) is the source of truth; balances are
always a derived cache that can be recomputed from scratch. The `splitcore` Go
package does all arithmetic, and it ships twice: imported directly by the Go
server, and compiled to a C shared library the Dart SDK calls over FFI. Client
and server math cannot drift, because it is literally the same binary logic.
Each group carries a monotonic `version` counter that the server bumps on every
mutation, so a client can ask "am I current?" in one cheap request instead of
re-fetching everything.

## Scope

**In:** groups, members, expenses, split entries (equal / exact / percent /
shares), settlements as reimbursements, receipt images on split entries, cached
balances, email invites, 1:1 "direct" groups.

**Out, deliberately:** bank sync, IOU tracking, multi-currency conversion,
recurring expenses, push notifications. Currency is a group-level label with no
conversion logic anywhere — needing two currencies means creating two groups.
