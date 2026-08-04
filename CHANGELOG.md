# Changelog

All notable changes to this project are documented here. The format is
based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this
project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Expense editing (`updateExpense`), expense search, and paginated
  expense/settlement listings (`Page<T>`).
- Password reset, email verification, and account deletion. Deletion
  erases the account when there is no ledger history and anonymizes it
  otherwise — see `server/README.md` for why erasure is impossible for a
  participant.
- Group ledger export to CSV (`sdk.export.groupToCsv`).
- `TokenStore`: SDK-owned session persistence, so the app no longer
  depends on `package:pocketbase`.
- Root `README.md`, `LICENSE` (MIT), `CONTRIBUTING.md`, `SECURITY.md`, and
  this changelog.
- Native build scripts for macOS (universal dylib) and Windows
  (mingw-w64), completing the set alongside the existing Linux, Android,
  and iOS scripts (`splitcore/build/`).
- Root `Makefile` — `make check` is the single gate shared by developers
  and CI.
- GitHub Actions CI: format, vet, analyze, and all three test suites.
- `Dockerfile` and `docker-compose.yml` for the server, with a health
  check and a documented backup/restore procedure.

### Changed
- Go module paths renamed from `github.com/abdulroufsidhu/slice_pay/...`
  to `github.com/abdulroufsidhu/splitcore/...` to match the repository.
- Flutter package renamed `app` → `splitcore_app`, with a real description
  and README replacing the Flutter template.
- Dart sources formatted at a repo-wide 100-column width, pinned in both
  `analysis_options.yaml` files.
- `prompt.md` moved to `docs/`.

### Fixed
- PocketBase filters are parameterized rather than interpolated, so a
  value containing a quote cannot inject filter syntax.
- A failed expense create no longer leaves an orphan, permanently
  uncounted expense behind.
- Concurrent session refreshes share one request instead of racing.
- The app's default backend URL was a hardcoded LAN address
  (`192.168.240.1`) that only worked on one developer's machine. It is now
  resolved per platform, with `--dart-define=POCKETBASE_URL` overriding.
- `.gitignore`'s blanket Dart/Flutter `build/` rule was also matching
  `splitcore/build`, which holds the native build scripts themselves.
