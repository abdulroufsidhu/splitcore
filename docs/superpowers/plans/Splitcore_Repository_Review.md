# Splitcore Repository Review

## Overall assessment

-   **Architecture:** Strong
-   **Backend/domain design:** Promising
-   **Testing effort:** Good in Go core and server
-   **Flutter app maturity:** Early-to-mid stage
-   **Production readiness:** Low
-   **Portfolio potential:** High after cleanup

Your strongest architectural decision is sharing a single Go calculation
engine between the backend and Flutter (via FFI), avoiding duplicated
financial logic.

------------------------------------------------------------------------

# Highest Priority Issues

## 1. Rename `slice_pay` module paths

**Severity:** High

Repository name (`splitcore`) and Go module paths (`slice_pay`) are
inconsistent.

### Actions

-   Rename Go modules to `github.com/abdulroufsidhu/splitcore/...`
-   Update imports
-   Remove obsolete `replace` directives
-   Standardize product naming (Splitcore vs SlicePay)

------------------------------------------------------------------------

## 2. Create a proper root README

**Severity:** High

Include: - Project overview - Architecture - Repository structure -
Setup instructions - Building native libraries - Running server -
Running Flutter - Running tests - Roadmap - License

------------------------------------------------------------------------

## 3. Add GitHub Actions CI

**Severity:** High

Automate: - Go tests - Go vet - gofmt - Dart analyze/test - Flutter
analyze/test - Native FFI builds

------------------------------------------------------------------------

## 4. Hide PocketBase behind the SDK

**Severity:** Medium-High

The Flutter UI should not directly depend on PocketBase.

------------------------------------------------------------------------

## 5. Fix default backend URL

**Severity:** High

Avoid machine-specific defaults. Use platform-specific configuration or
`--dart-define`.

------------------------------------------------------------------------

## 6. Automate native library packaging

**Severity:** High

Provide repeatable build scripts for: - Android - iOS - Linux - macOS -
Windows

------------------------------------------------------------------------

## 7. Expand Flutter tests

**Severity:** High

Add tests for: - Authentication - Groups - Expenses - Settlements -
Offline behavior - Error states

------------------------------------------------------------------------

## 8. Improve state management

**Severity:** Medium

Separate: - UI - Presentation - SDK - Navigation

------------------------------------------------------------------------

## 9. Harden authentication refresh

**Severity:** Medium-High

Handle: - Offline mode - Invalid sessions - Concurrent refreshes -
Unexpected exceptions

------------------------------------------------------------------------

## 10. Add deployment assets

**Severity:** High

Create: - Dockerfile - docker-compose - Health checks - Backup
strategy - HTTPS documentation

------------------------------------------------------------------------

# Backend Review

## Strengths

-   Shared Go domain engine
-   Permission-aware backend
-   Derived balances
-   Transactional recomputation
-   Rule tests
-   Version tracking

## Verify

-   Concurrent updates
-   Delete behavior
-   Atomic expense creation
-   Large-scale balance recomputation performance

------------------------------------------------------------------------

# Repository Hygiene

-   Add root README
-   Replace default Flutter README
-   Update pubspec description
-   Move `prompt.md` into `docs/`
-   Add LICENSE
-   Add CONTRIBUTING.md
-   Add SECURITY.md
-   Add CHANGELOG.md

------------------------------------------------------------------------

# Missing Product Features

-   Expense editing
-   Expense deletion
-   Activity history
-   Invitations
-   Password reset
-   Email verification
-   Profile deletion
-   Receipt lifecycle
-   Search
-   Pagination
-   Offline mode
-   Data export
-   Accessibility
-   Localization

------------------------------------------------------------------------

# Recommended Roadmap

## Phase 1

-   Rename modules
-   Add README
-   Add LICENSE
-   Add CI
-   Improve setup
-   Add Makefile

## Phase 2

-   Refactor Flutter architecture
-   Introduce SDK abstractions
-   Improve state management

## Phase 3

-   Finish native packaging
-   Add FFI integration tests
-   Document supported platforms

## Phase 4

-   Containerize backend
-   Add monitoring
-   Add backups
-   Security review
-   Load testing

------------------------------------------------------------------------

# First Milestone

A new developer should be able to:

1.  Clone the repository.
2.  Run documented setup.
3.  Start the backend.
4.  Launch the Flutter app.
5.  Create users.
6.  Create a group.
7.  Add expenses.
8.  Settle balances.

All of this should be verified by CI.

------------------------------------------------------------------------

# First PR Checklist

-   [ ] Rename module paths
-   [ ] Add root README
-   [ ] Add LICENSE
-   [ ] Add GitHub Actions
-   [ ] Add Makefile
-   [ ] Fix backend URL configuration
-   [ ] Update Flutter metadata
-   [ ] Move/remove `prompt.md`

------------------------------------------------------------------------

# Final Verdict

The project has a solid technical foundation with a well-designed shared
domain engine. The biggest opportunity is improving developer
experience: documentation, CI, packaging, testing, and deployment.
Completing those areas will significantly improve both production
readiness and portfolio quality.
