# Splitcore

A Splitwise-style expense splitter — groups record shared expenses,
Splitcore works out who owes whom, and settlements clear the balances.

**The one architectural rule:** there is exactly one implementation of the
money math, and both the server and the client run that same compiled Go
code. The server calls it as a Go package; the Flutter app calls it over
FFI. Split amounts can never disagree between client and server, because
there is no second implementation to disagree with.

```
splitcore/        Pure Go, stdlib only. money / settle / balance + cgo FFI shim.
server/           Go + PocketBase. Schema, access rules, validation hooks, balance recompute.
splitcore_sdk/    Dart. FFI bindings + PocketBase client. The only API the app may use.
app/              Flutter. UI only — no money math, no direct PocketBase access.
docs/             Architecture, data model, data flow, API reference, decisions.
```

## Quick start

Requires **Go 1.26.4**, **Flutter (Dart 3.9+)**, **Python 3** (ABI smoke
test), and a C toolchain (`gcc`) for cgo.

```bash
git clone git@github.com:abdulroufsidhu/splitcore.git
cd splitcore
make check     # builds the native library and runs every test suite
```

Then, in two terminals:

```bash
make server    # PocketBase on http://0.0.0.0:8090 (admin UI at /_/)
make app       # builds libsplitcore.so and launches the Flutter app
```

On first run, open `http://127.0.0.1:8090/_/` to create the superuser
account; migrations create all six collections automatically under
`go run`. Then sign up in the app, create a group, add an expense, and
settle up.

## Make targets

| Target | Does |
|---|---|
| `make check` | fmt check + vet + analyze + every test. What CI runs. |
| `make native` | Build `libsplitcore.so` for this Linux host |
| `make bundle-native` | Cross-compile Android ABIs and copy into the Flutter runner |
| `make server` | Run PocketBase on `0.0.0.0:8090` |
| `make app` | Run the Flutter app against a local server |
| `make test` | Go + Dart SDK + Flutter tests |
| `make fmt` | Format Go and Dart in place |
| `make clean` | Delete build outputs |

## Building the native library

`splitcore/build/` holds one script per target — Linux, Android (4 ABIs),
iOS, macOS, Windows — plus a `ctypes` smoke test that exercises the C ABI
with no Dart or Go in the loop. See
[`splitcore/build/BUILD.md`](splitcore/build/BUILD.md) for host
requirements and cross-compilation gotchas.

## Running the server

See [`server/README.md`](server/README.md) for collections, access rules,
the staleness endpoint, and the balances-cache contract.

For a container: `docker compose up -d` (see [Deployment](#deployment)
below).

## Running the app

```bash
cd app && flutter run --dart-define=POCKETBASE_URL=https://your-server
```

Without the define, the app targets the local dev server — `10.0.2.2:8090`
on Android emulators, `127.0.0.1:8090` elsewhere. Physical devices always
need the explicit define. See [`app/README.md`](app/README.md).

## Running the tests

```bash
make test        # everything
make test-go     # Go unit tests + FFI ABI smoke test
make test-sdk    # Dart SDK tests (spawns a real PocketBase subprocess)
make test-app    # Flutter widget tests
```

The SDK's integration tests start the actual server on an ephemeral port
with a temp data directory — they test the real wire contract, not a mock.

## Deployment

```bash
docker compose up -d
curl http://localhost:8090/api/health
```

See [`docs/deployment.md`](docs/deployment.md) for HTTPS termination,
backups, and restore.

## Documentation

| Doc | Covers |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Component boundaries and why they are where they are |
| [docs/data-model.md](docs/data-model.md) | Collections, fields, relations |
| [docs/data-flow.md](docs/data-flow.md) | A request's path from tap to balance |
| [docs/api-reference.md](docs/api-reference.md) | SDK and HTTP surface |
| [docs/decisions.md](docs/decisions.md) | Architectural decisions and their tradeoffs |
| [docs/development.md](docs/development.md) | Day-to-day workflow |
| [docs/deployment.md](docs/deployment.md) | Containers, HTTPS, backups |

## Roadmap

- **Now:** module/repo consistency, CI, native packaging, containerized server.
- **Next:** SDK correctness — parameterized filters, pagination, atomic
  expense writes, expense editing, password reset and email verification.
- **Then:** app maturity — offline reads, error and retry states,
  accessibility, localization, search, export.

## License

MIT — see [LICENSE](LICENSE).
