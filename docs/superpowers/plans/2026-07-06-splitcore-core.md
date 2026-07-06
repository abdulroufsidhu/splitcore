# Splitcore Core Library Implementation Plan (Plan 1 of 3)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pure Go expense-splitting calculation core (`splitcore`), compilable both as a Go import and as a C shared library, with cross-compile scripts for Android/iOS.

**Architecture:** Stdlib-only Go module with three domain packages (`money`, `settle`, `balance`), a JSON-string FFI handler layer (pure Go, fully testable), and a thin cgo export shim (`package main`) built with `-buildmode=c-shared`. All money is `int64` minor units. Largest-remainder rounding. Deterministic everywhere.

**Tech Stack:** Go 1.26 (stdlib only), cgo for exports, Python 3 ctypes for the .so smoke test, Android NDK / Xcode for cross-compiles.

## Global Constraints

- Money is always `int64` minor units (cents). No floats in any money path.
- `splitcore` imports nothing outside the Go stdlib.
- Determinism: same input order → same output. Ties in rounding broken by input index (ascending).
- Every split function must satisfy `sum(splits) == total` — no lost or duplicated cents.
- Percentages are basis points (`int64`, 10000 = 100%).
- Shares are positive integers.
- No panics across the FFI boundary; errors return as JSON `{"error": "..."}`.
- TDD: every step runs its test and shows the result before moving on.
- Module path: `github.com/abdulroufsidhu/slice_pay/splitcore`.

---

### Task 1: Repo scaffolding

**Files:**
- Create: `go.work`
- Create: `splitcore/go.mod`
- Create: `.gitignore`

**Interfaces:**
- Produces: Go module `github.com/abdulroufsidhu/slice_pay/splitcore` that later tasks add packages to.

- [ ] **Step 1: Create module and workspace**

```bash
cd /home/abdul/Projects/slice_pay
mkdir -p splitcore
cd splitcore && go mod init github.com/abdulroufsidhu/slice_pay/splitcore && cd ..
go work init ./splitcore
```

- [ ] **Step 2: Create `.gitignore`**

```gitignore
# build outputs
splitcore/build/out/
*.so
*.dylib
*.a
*.h.gch
libsplitcore.h

# editor/OS
.idea/
.vscode/
*.swp
.DS_Store
```

- [ ] **Step 3: Verify module compiles**

Run: `cd /home/abdul/Projects/slice_pay && go build ./...`
Expected: exits 0, no output.

- [ ] **Step 4: Commit**

```bash
git add go.work splitcore/go.mod .gitignore
git commit -m "chore: scaffold splitcore module and go workspace"
```

---

### Task 2: money package — weighted splitter + ComputeEqualSplit

**Files:**
- Create: `splitcore/money/split.go`
- Test: `splitcore/money/split_test.go`

**Interfaces:**
- Produces:
  - `type Split struct { MemberID string; AmountCents int64 }`
  - `func ComputeEqualSplit(totalCents int64, memberIDs []string) ([]Split, error)`
  - internal `splitByWeights(totalCents int64, ids []string, weights []int64) ([]Split, error)` (used by Task 3)
  - Sentinel errors: `ErrNoMembers`, `ErrNonPositiveTotal`, `ErrDuplicateMember`, `ErrOverflow`

- [ ] **Step 1: Write failing tests for ComputeEqualSplit**

Create `splitcore/money/split_test.go`:

```go
package money

import (
	"errors"
	"testing"
)

func sum(splits []Split) int64 {
	var s int64
	for _, sp := range splits {
		s += sp.AmountCents
	}
	return s
}

func TestComputeEqualSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		members []string
		want    []Split
		wantErr error
	}{
		{
			name:    "even division",
			total:   9000,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 3000}, {"b", 3000}, {"c", 3000}},
		},
		{
			name:    "100.00 over 3 — leftover cent to first member",
			total:   10000,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 3334}, {"b", 3333}, {"c", 3333}},
		},
		{
			name:    "0.01 over 3 — only first member pays",
			total:   1,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 1}, {"b", 0}, {"c", 0}},
		},
		{
			name:    "single member gets everything",
			total:   777,
			members: []string{"solo"},
			want:    []Split{{"solo", 777}},
		},
		{
			name:    "two leftover cents to first two members",
			total:   11,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 4}, {"b", 4}, {"c", 3}},
		},
		{
			name:    "empty members rejected",
			total:   100,
			members: nil,
			wantErr: ErrNoMembers,
		},
		{
			name:    "zero total rejected",
			total:   0,
			members: []string{"a"},
			wantErr: ErrNonPositiveTotal,
		},
		{
			name:    "negative total rejected",
			total:   -5,
			members: []string{"a"},
			wantErr: ErrNonPositiveTotal,
		},
		{
			name:    "duplicate member rejected",
			total:   100,
			members: []string{"a", "a"},
			wantErr: ErrDuplicateMember,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeEqualSplit(tt.total, tt.members)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("want %d splits, got %d", len(tt.want), len(got))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
			if sum(got) != tt.total {
				t.Errorf("splits sum %d != total %d", sum(got), tt.total)
			}
		})
	}
}

func TestComputeEqualSplitConservation(t *testing.T) {
	members := []string{"a", "b", "c", "d", "e", "f", "g"}
	for total := int64(1); total <= 2000; total++ {
		splits, err := ComputeEqualSplit(total, members)
		if err != nil {
			t.Fatalf("total %d: %v", total, err)
		}
		if sum(splits) != total {
			t.Fatalf("total %d: sum %d — cents lost or duplicated", total, sum(splits))
		}
	}
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./money/`
Expected: FAIL — `undefined: Split`, `undefined: ComputeEqualSplit`, etc.

- [ ] **Step 3: Implement**

Create `splitcore/money/split.go`:

```go
// Package money implements expense split calculations on int64 minor
// units (cents). All functions are deterministic: identical input order
// produces identical output. Leftover cents from integer division are
// assigned by largest remainder, ties broken by input index.
package money

import (
	"errors"
	"math"
	"sort"
)

var (
	ErrNoMembers        = errors.New("money: no members")
	ErrNonPositiveTotal = errors.New("money: total must be positive")
	ErrDuplicateMember  = errors.New("money: duplicate member id")
	ErrOverflow         = errors.New("money: computation would overflow int64")
)

// Split is one member's portion of an expense.
type Split struct {
	MemberID    string
	AmountCents int64
}

// ComputeEqualSplit divides totalCents evenly across memberIDs.
func ComputeEqualSplit(totalCents int64, memberIDs []string) ([]Split, error) {
	weights := make([]int64, len(memberIDs))
	for i := range weights {
		weights[i] = 1
	}
	return splitByWeights(totalCents, memberIDs, weights)
}

// splitByWeights allocates totalCents proportionally to weights using
// largest-remainder rounding. Preconditions checked here: positive
// total, at least one member, unique ids, positive weights, no overflow
// in totalCents*weight.
func splitByWeights(totalCents int64, ids []string, weights []int64) ([]Split, error) {
	if totalCents <= 0 {
		return nil, ErrNonPositiveTotal
	}
	if len(ids) == 0 {
		return nil, ErrNoMembers
	}
	seen := make(map[string]struct{}, len(ids))
	var weightSum int64
	for i, id := range ids {
		if _, dup := seen[id]; dup {
			return nil, ErrDuplicateMember
		}
		seen[id] = struct{}{}
		if weights[i] <= 0 {
			return nil, ErrNonPositiveShare
		}
		if weightSum > math.MaxInt64-weights[i] {
			return nil, ErrOverflow
		}
		weightSum += weights[i]
	}

	splits := make([]Split, len(ids))
	type rem struct {
		index     int
		remainder int64
	}
	rems := make([]rem, len(ids))
	var allocated int64
	for i, id := range ids {
		if weights[i] > math.MaxInt64/totalCents {
			return nil, ErrOverflow
		}
		num := totalCents * weights[i]
		amount := num / weightSum
		splits[i] = Split{MemberID: id, AmountCents: amount}
		rems[i] = rem{index: i, remainder: num % weightSum}
		allocated += amount
	}

	leftover := totalCents - allocated
	sort.SliceStable(rems, func(a, b int) bool {
		return rems[a].remainder > rems[b].remainder
	})
	for i := int64(0); i < leftover; i++ {
		splits[rems[i].index].AmountCents++
	}
	return splits, nil
}
```

Note: `ErrNonPositiveShare` is referenced but defined in Task 3. For this task, add it now so the package compiles:

```go
var ErrNonPositiveShare = errors.New("money: share/weight must be positive")
```

(add to the `var` block at top).

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./money/ -v`
Expected: PASS — all `TestComputeEqualSplit` subtests + conservation test.

- [ ] **Step 5: Commit**

```bash
git add splitcore/money/
git commit -m "feat(money): equal split with largest-remainder rounding"
```

---

### Task 3: money package — exact, percent, share splits

**Files:**
- Modify: `splitcore/money/split.go`
- Test: `splitcore/money/split_test.go` (append)

**Interfaces:**
- Consumes: `splitByWeights` from Task 2.
- Produces:
  - `type ExactEntry struct { MemberID string; AmountCents int64 }`
  - `type PercentEntry struct { MemberID string; BasisPoints int64 }`
  - `type ShareEntry struct { MemberID string; Shares int64 }`
  - `func ComputeExactSplit(totalCents int64, entries []ExactEntry) ([]Split, error)`
  - `func ComputePercentSplit(totalCents int64, entries []PercentEntry) ([]Split, error)`
  - `func ComputeShareSplit(totalCents int64, entries []ShareEntry) ([]Split, error)`
  - Sentinel errors: `ErrExactSumMismatch`, `ErrNegativeAmount`, `ErrPercentSumInvalid`, `ErrNonPositiveShare`

- [ ] **Step 1: Write failing tests**

Append to `splitcore/money/split_test.go`:

```go
func TestComputeExactSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []ExactEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "valid exact split",
			total: 5000,
			entries: []ExactEntry{
				{"a", 1200}, {"b", 3800},
			},
			want: []Split{{"a", 1200}, {"b", 3800}},
		},
		{
			name:  "zero entry allowed (member owes nothing)",
			total: 100,
			entries: []ExactEntry{
				{"a", 100}, {"b", 0},
			},
			want: []Split{{"a", 100}, {"b", 0}},
		},
		{
			name:    "sum mismatch rejected",
			total:   5000,
			entries: []ExactEntry{{"a", 1200}, {"b", 3700}},
			wantErr: ErrExactSumMismatch,
		},
		{
			name:    "negative entry rejected",
			total:   100,
			entries: []ExactEntry{{"a", 200}, {"b", -100}},
			wantErr: ErrNegativeAmount,
		},
		{
			name:    "duplicate member rejected",
			total:   200,
			entries: []ExactEntry{{"a", 100}, {"a", 100}},
			wantErr: ErrDuplicateMember,
		},
		{
			name:    "empty rejected",
			total:   100,
			entries: nil,
			wantErr: ErrNoMembers,
		},
		{
			name:    "zero total rejected",
			total:   0,
			entries: []ExactEntry{{"a", 0}},
			wantErr: ErrNonPositiveTotal,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeExactSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
		})
	}
}

func TestComputePercentSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []PercentEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "50/30/20",
			total: 10000,
			entries: []PercentEntry{
				{"a", 5000}, {"b", 3000}, {"c", 2000},
			},
			want: []Split{{"a", 5000}, {"b", 3000}, {"c", 2000}},
		},
		{
			name:  "thirds of 100.00 — largest remainder",
			total: 10000,
			entries: []PercentEntry{
				{"a", 3333}, {"b", 3333}, {"c", 3334},
			},
			// a: 3333.00→3333, b: 3333.00→3333, c: 3334.00→3334
			want: []Split{{"a", 3333}, {"b", 3333}, {"c", 3334}},
		},
		{
			name:  "remainder cent goes to largest fractional remainder",
			total: 101,
			entries: []PercentEntry{
				{"a", 5000}, {"b", 5000},
			},
			// 101*5000/10000 = 50.5 each; floor 50+50=100, leftover 1
			// equal remainders → tie broken by input order → a gets it
			want: []Split{{"a", 51}, {"b", 50}},
		},
		{
			name:    "sum below 10000 rejected",
			total:   100,
			entries: []PercentEntry{{"a", 5000}, {"b", 4999}},
			wantErr: ErrPercentSumInvalid,
		},
		{
			name:    "sum above 10000 rejected",
			total:   100,
			entries: []PercentEntry{{"a", 5000}, {"b", 5001}},
			wantErr: ErrPercentSumInvalid,
		},
		{
			name:    "zero basis points rejected",
			total:   100,
			entries: []PercentEntry{{"a", 10000}, {"b", 0}},
			wantErr: ErrNonPositiveShare,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputePercentSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
			if sum(got) != tt.total {
				t.Errorf("splits sum %d != total %d", sum(got), tt.total)
			}
		})
	}
}

func TestComputeShareSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []ShareEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "1:2:3 shares of 60.00",
			total: 6000,
			entries: []ShareEntry{
				{"a", 1}, {"b", 2}, {"c", 3},
			},
			want: []Split{{"a", 1000}, {"b", 2000}, {"c", 3000}},
		},
		{
			name:  "uneven: 2:1 of 0.05",
			total: 5,
			entries: []ShareEntry{
				{"a", 2}, {"b", 1},
			},
			// a: 10/3=3 rem 1, b: 5/3=1 rem 2 → leftover 1 → b (larger remainder)
			want: []Split{{"a", 3}, {"b", 2}},
		},
		{
			name:    "zero share rejected",
			total:   100,
			entries: []ShareEntry{{"a", 1}, {"b", 0}},
			wantErr: ErrNonPositiveShare,
		},
		{
			name:    "negative share rejected",
			total:   100,
			entries: []ShareEntry{{"a", 1}, {"b", -2}},
			wantErr: ErrNonPositiveShare,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeShareSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
			if sum(got) != tt.total {
				t.Errorf("splits sum %d != total %d", sum(got), tt.total)
			}
		})
	}
}

func TestShareSplitConservation(t *testing.T) {
	entries := []ShareEntry{{"a", 3}, {"b", 5}, {"c", 7}, {"d", 11}}
	for total := int64(1); total <= 2000; total++ {
		splits, err := ComputeShareSplit(total, entries)
		if err != nil {
			t.Fatalf("total %d: %v", total, err)
		}
		if sum(splits) != total {
			t.Fatalf("total %d: sum %d — cents lost or duplicated", total, sum(splits))
		}
	}
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./money/`
Expected: FAIL — `undefined: ExactEntry`, `undefined: ComputeExactSplit`, etc.

- [ ] **Step 3: Implement**

Append to `splitcore/money/split.go` (and extend the `var` block):

```go
var (
	ErrExactSumMismatch  = errors.New("money: exact entries do not sum to total")
	ErrNegativeAmount    = errors.New("money: amount must not be negative")
	ErrPercentSumInvalid = errors.New("money: basis points must sum to 10000")
)

// ExactEntry is a caller-specified fixed amount for one member.
type ExactEntry struct {
	MemberID    string
	AmountCents int64
}

// PercentEntry is a member's portion in basis points (10000 = 100%).
type PercentEntry struct {
	MemberID    string
	BasisPoints int64
}

// ShareEntry is a member's weight as a positive integer share count.
type ShareEntry struct {
	MemberID string
	Shares   int64
}

// ComputeExactSplit validates caller-provided amounts: non-negative,
// unique members, summing exactly to totalCents.
func ComputeExactSplit(totalCents int64, entries []ExactEntry) ([]Split, error) {
	if totalCents <= 0 {
		return nil, ErrNonPositiveTotal
	}
	if len(entries) == 0 {
		return nil, ErrNoMembers
	}
	seen := make(map[string]struct{}, len(entries))
	splits := make([]Split, len(entries))
	var total int64
	for i, e := range entries {
		if _, dup := seen[e.MemberID]; dup {
			return nil, ErrDuplicateMember
		}
		seen[e.MemberID] = struct{}{}
		if e.AmountCents < 0 {
			return nil, ErrNegativeAmount
		}
		total += e.AmountCents
		splits[i] = Split{MemberID: e.MemberID, AmountCents: e.AmountCents}
	}
	if total != totalCents {
		return nil, ErrExactSumMismatch
	}
	return splits, nil
}

// ComputePercentSplit splits by basis points, which must sum to 10000.
func ComputePercentSplit(totalCents int64, entries []PercentEntry) ([]Split, error) {
	ids := make([]string, len(entries))
	weights := make([]int64, len(entries))
	var bpSum int64
	for i, e := range entries {
		ids[i] = e.MemberID
		weights[i] = e.BasisPoints
		bpSum += e.BasisPoints
	}
	if len(entries) > 0 && bpSum != 10000 {
		// check non-positive first so the more specific error wins
		for _, w := range weights {
			if w <= 0 {
				return nil, ErrNonPositiveShare
			}
		}
		return nil, ErrPercentSumInvalid
	}
	return splitByWeights(totalCents, ids, weights)
}

// ComputeShareSplit splits proportionally to positive integer shares.
func ComputeShareSplit(totalCents int64, entries []ShareEntry) ([]Split, error) {
	ids := make([]string, len(entries))
	weights := make([]int64, len(entries))
	for i, e := range entries {
		ids[i] = e.MemberID
		weights[i] = e.Shares
	}
	return splitByWeights(totalCents, ids, weights)
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./money/ -v`
Expected: PASS — all subtests.

- [ ] **Step 5: Commit**

```bash
git add splitcore/money/
git commit -m "feat(money): exact, percent (basis points), and share splits"
```

---

### Task 4: settle package — SimplifyDebts

**Files:**
- Create: `splitcore/settle/settle.go`
- Test: `splitcore/settle/settle_test.go`

**Interfaces:**
- Produces:
  - `type Balance struct { MemberID string; NetCents int64 }` (+ = is owed, − = owes)
  - `type Transfer struct { FromMemberID string; ToMemberID string; AmountCents int64 }`
  - `func SimplifyDebts(balances []Balance) ([]Transfer, error)`
  - Sentinel errors: `ErrUnbalanced`, `ErrDuplicateMember`

- [ ] **Step 1: Write failing tests**

Create `splitcore/settle/settle_test.go`:

```go
package settle

import (
	"errors"
	"testing"
)

// applyTransfers verifies transfers settle the balances to zero.
func applyTransfers(t *testing.T, balances []Balance, transfers []Transfer) {
	t.Helper()
	net := map[string]int64{}
	for _, b := range balances {
		net[b.MemberID] = b.NetCents
	}
	for _, tr := range transfers {
		if tr.AmountCents <= 0 {
			t.Fatalf("non-positive transfer: %+v", tr)
		}
		net[tr.FromMemberID] += tr.AmountCents
		net[tr.ToMemberID] -= tr.AmountCents
	}
	for id, n := range net {
		if n != 0 {
			t.Fatalf("member %s not settled: %d", id, n)
		}
	}
}

func TestSimplifyDebts(t *testing.T) {
	tests := []struct {
		name         string
		balances     []Balance
		want         []Transfer // nil means: only check invariants
		maxTransfers int
		wantErr      error
	}{
		{
			name: "simple pair",
			balances: []Balance{
				{"a", 500}, {"b", -500},
			},
			want:         []Transfer{{"b", "a", 500}},
			maxTransfers: 1,
		},
		{
			name: "triangle collapses to two transfers",
			balances: []Balance{
				{"a", 1000}, {"b", -400}, {"c", -600},
			},
			want:         []Transfer{{"c", "a", 600}, {"b", "a", 400}},
			maxTransfers: 2,
		},
		{
			name: "zero balances produce no transfers",
			balances: []Balance{
				{"a", 0}, {"b", 0},
			},
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name:         "empty input",
			balances:     nil,
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name: "single member zero",
			balances: []Balance{
				{"solo", 0},
			},
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name: "five members settle in at most four",
			balances: []Balance{
				{"a", 900}, {"b", -300}, {"c", 400}, {"d", -700}, {"e", -300},
			},
			maxTransfers: 4,
		},
		{
			name: "deterministic tie-break by member id",
			balances: []Balance{
				{"b", -250}, {"a", 500}, {"c", -250},
			},
			// b and c owe equally; b < c lexicographically, so b pays first
			want:         []Transfer{{"b", "a", 250}, {"c", "a", 250}},
			maxTransfers: 2,
		},
		{
			name: "unbalanced input rejected",
			balances: []Balance{
				{"a", 100}, {"b", -50},
			},
			wantErr: ErrUnbalanced,
		},
		{
			name: "duplicate member rejected",
			balances: []Balance{
				{"a", 100}, {"a", -100},
			},
			wantErr: ErrDuplicateMember,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := SimplifyDebts(tt.balances)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) > tt.maxTransfers {
				t.Errorf("want ≤%d transfers, got %d: %+v", tt.maxTransfers, len(got), got)
			}
			applyTransfers(t, tt.balances, got)
			if tt.want != nil {
				if len(got) != len(tt.want) {
					t.Fatalf("want %d transfers, got %d: %+v", len(tt.want), len(got), got)
				}
				for i := range got {
					if got[i] != tt.want[i] {
						t.Errorf("transfer[%d]: want %+v, got %+v", i, tt.want[i], got[i])
					}
				}
			}
		})
	}
}

func TestSimplifyDebtsDeterminism(t *testing.T) {
	balances := []Balance{
		{"a", 900}, {"b", -300}, {"c", 400}, {"d", -700}, {"e", -300},
	}
	first, err := SimplifyDebts(balances)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		again, err := SimplifyDebts(balances)
		if err != nil {
			t.Fatal(err)
		}
		if len(again) != len(first) {
			t.Fatalf("run %d: transfer count changed", i)
		}
		for j := range again {
			if again[j] != first[j] {
				t.Fatalf("run %d: transfer[%d] differs: %+v vs %+v", i, j, again[j], first[j])
			}
		}
	}
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./settle/`
Expected: FAIL — `undefined: Balance`, `undefined: SimplifyDebts`.

- [ ] **Step 3: Implement**

Create `splitcore/settle/settle.go`:

```go
// Package settle turns a set of member balances into a minimal-ish list
// of transfers using a greedy max-debtor→max-creditor strategy. The
// result is deterministic (ties broken by member id ascending) and
// contains at most n−1 transfers for n members.
package settle

import "errors"

var (
	ErrUnbalanced      = errors.New("settle: balances do not sum to zero")
	ErrDuplicateMember = errors.New("settle: duplicate member id")
)

// Balance is a member's net position: positive = is owed money,
// negative = owes money.
type Balance struct {
	MemberID string
	NetCents int64
}

// Transfer is a suggested payment from one member to another.
type Transfer struct {
	FromMemberID string
	ToMemberID   string
	AmountCents  int64
}

// SimplifyDebts computes transfers that settle all balances to zero.
func SimplifyDebts(balances []Balance) ([]Transfer, error) {
	net := make(map[string]int64, len(balances))
	var sum int64
	for _, b := range balances {
		if _, dup := net[b.MemberID]; dup {
			return nil, ErrDuplicateMember
		}
		net[b.MemberID] = b.NetCents
		sum += b.NetCents
	}
	if sum != 0 {
		return nil, ErrUnbalanced
	}

	transfers := []Transfer{}
	for {
		var creditor, debtor string
		var maxCredit, maxDebt int64
		for id, n := range net {
			switch {
			case n > 0 && (n > maxCredit || (n == maxCredit && (creditor == "" || id < creditor))):
				creditor, maxCredit = id, n
			case n < 0 && (-n > maxDebt || (-n == maxDebt && (debtor == "" || id < debtor))):
				debtor, maxDebt = id, -n
			}
		}
		if creditor == "" { // all settled
			return transfers, nil
		}
		amount := min(maxCredit, maxDebt)
		transfers = append(transfers, Transfer{
			FromMemberID: debtor,
			ToMemberID:   creditor,
			AmountCents:  amount,
		})
		net[creditor] -= amount
		net[debtor] += amount
	}
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./settle/ -v`
Expected: PASS — including determinism test (map iteration is randomized in Go; the explicit tie-breaks make output stable regardless).

- [ ] **Step 5: Commit**

```bash
git add splitcore/settle/
git commit -m "feat(settle): greedy debt simplification, deterministic"
```

---

### Task 5: balance package — ComputeBalances

**Files:**
- Create: `splitcore/balance/balance.go`
- Test: `splitcore/balance/balance_test.go`

**Interfaces:**
- Consumes: `money.Split`, `settle.Balance` from Tasks 2/4.
- Produces:
  - `type Expense struct { PayerID string; AmountCents int64; Splits []money.Split }`
  - `type Settlement struct { FromMemberID string; ToMemberID string; AmountCents int64 }`
  - `func ComputeBalances(expenses []Expense, settlements []Settlement) ([]settle.Balance, error)` — output sorted by MemberID ascending
  - Sentinel errors: `ErrSplitSumMismatch`, `ErrNonPositiveAmount`, `ErrSelfSettlement`

- [ ] **Step 1: Write failing tests**

Create `splitcore/balance/balance_test.go`:

```go
package balance

import (
	"errors"
	"testing"

	"github.com/abdulroufsidhu/slice_pay/splitcore/money"
	"github.com/abdulroufsidhu/slice_pay/splitcore/settle"
)

func TestComputeBalances(t *testing.T) {
	tests := []struct {
		name        string
		expenses    []Expense
		settlements []Settlement
		want        []settle.Balance
		wantErr     error
	}{
		{
			name: "single expense, payer included in split",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 3000,
					Splits: []money.Split{
						{MemberID: "a", AmountCents: 1000},
						{MemberID: "b", AmountCents: 1000},
						{MemberID: "c", AmountCents: 1000},
					},
				},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 2000},
				{MemberID: "b", NetCents: -1000},
				{MemberID: "c", NetCents: -1000},
			},
		},
		{
			name: "settlement reduces debt",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 2000,
					Splits: []money.Split{
						{MemberID: "a", AmountCents: 1000},
						{MemberID: "b", AmountCents: 1000},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 600},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 400},
				{MemberID: "b", NetCents: -400},
			},
		},
		{
			name: "full settlement zeroes group",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 1000,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 1000},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 1000},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 0},
				{MemberID: "b", NetCents: 0},
			},
		},
		{
			name: "overpayment flips direction",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 500,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 500},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 800},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: -300},
				{MemberID: "b", NetCents: 300},
			},
		},
		{
			name:        "empty log yields empty balances",
			expenses:    nil,
			settlements: nil,
			want:        []settle.Balance{},
		},
		{
			name: "split sum mismatch rejected",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 1000,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 999},
					},
				},
			},
			wantErr: ErrSplitSumMismatch,
		},
		{
			name: "non-positive expense rejected",
			expenses: []Expense{
				{PayerID: "a", AmountCents: 0, Splits: nil},
			},
			wantErr: ErrNonPositiveAmount,
		},
		{
			name: "non-positive settlement rejected",
			settlements: []Settlement{
				{FromMemberID: "a", ToMemberID: "b", AmountCents: 0},
			},
			wantErr: ErrNonPositiveAmount,
		},
		{
			name: "self settlement rejected",
			settlements: []Settlement{
				{FromMemberID: "a", ToMemberID: "a", AmountCents: 100},
			},
			wantErr: ErrSelfSettlement,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeBalances(tt.expenses, tt.settlements)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("want %d balances, got %d: %+v", len(tt.want), len(got), got)
			}
			var sum int64
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("balance[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
				sum += got[i].NetCents
			}
			if sum != 0 {
				t.Errorf("balances sum to %d, want 0", sum)
			}
		})
	}
}

func TestComputeBalancesDeterministicOrder(t *testing.T) {
	expenses := []Expense{
		{
			PayerID:     "zed",
			AmountCents: 300,
			Splits: []money.Split{
				{MemberID: "mia", AmountCents: 100},
				{MemberID: "abe", AmountCents: 100},
				{MemberID: "zed", AmountCents: 100},
			},
		},
	}
	got, err := ComputeBalances(expenses, nil)
	if err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"abe", "mia", "zed"}
	for i, id := range wantOrder {
		if got[i].MemberID != id {
			t.Errorf("balance[%d]: want member %s, got %s", i, id, got[i].MemberID)
		}
	}
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./balance/`
Expected: FAIL — `undefined: Expense`, `undefined: ComputeBalances`.

- [ ] **Step 3: Implement**

Create `splitcore/balance/balance.go`:

```go
// Package balance recomputes member net balances from the full record
// set (expenses + settlements). This is the only way balances are ever
// produced; any stored balance table is a cache of this function's
// output. Deterministic: output sorted by MemberID ascending.
package balance

import (
	"errors"
	"sort"

	"github.com/abdulroufsidhu/slice_pay/splitcore/money"
	"github.com/abdulroufsidhu/slice_pay/splitcore/settle"
)

var (
	ErrSplitSumMismatch  = errors.New("balance: split entries do not sum to expense amount")
	ErrNonPositiveAmount = errors.New("balance: amount must be positive")
	ErrSelfSettlement    = errors.New("balance: settlement from and to must differ")
)

// Expense is one paid expense with its split entries.
type Expense struct {
	PayerID     string
	AmountCents int64
	Splits      []money.Split
}

// Settlement is a reimbursement payment between two members.
type Settlement struct {
	FromMemberID string
	ToMemberID   string
	AmountCents  int64
}

// ComputeBalances derives net balances from records. Positive net =
// member is owed money; negative = member owes.
func ComputeBalances(expenses []Expense, settlements []Settlement) ([]settle.Balance, error) {
	net := map[string]int64{}

	for _, e := range expenses {
		if e.AmountCents <= 0 {
			return nil, ErrNonPositiveAmount
		}
		var splitSum int64
		for _, s := range e.Splits {
			if s.AmountCents < 0 {
				return nil, ErrNonPositiveAmount
			}
			splitSum += s.AmountCents
		}
		if splitSum != e.AmountCents {
			return nil, ErrSplitSumMismatch
		}
		net[e.PayerID] += e.AmountCents
		for _, s := range e.Splits {
			net[s.MemberID] -= s.AmountCents
		}
	}

	for _, s := range settlements {
		if s.AmountCents <= 0 {
			return nil, ErrNonPositiveAmount
		}
		if s.FromMemberID == s.ToMemberID {
			return nil, ErrSelfSettlement
		}
		net[s.FromMemberID] += s.AmountCents
		net[s.ToMemberID] -= s.AmountCents
	}

	balances := make([]settle.Balance, 0, len(net))
	for id, n := range net {
		balances = append(balances, settle.Balance{MemberID: id, NetCents: n})
	}
	sort.Slice(balances, func(a, b int) bool {
		return balances[a].MemberID < balances[b].MemberID
	})
	return balances, nil
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./... -v`
Expected: PASS — money, settle, balance all green.

- [ ] **Step 5: Commit**

```bash
git add splitcore/balance/
git commit -m "feat(balance): deterministic balance recompute from records"
```

---

### Task 6: FFI handler layer (pure Go, JSON in/out)

**Files:**
- Create: `splitcore/ffi/handler/handler.go`
- Test: `splitcore/ffi/handler/handler_test.go`

**Interfaces:**
- Consumes: all public functions from Tasks 2–5.
- Produces (each takes a JSON request string, returns a JSON response string; errors → `{"error":"..."}`, never panics):
  - `func ComputeSplitsJSON(req string) string`
  - `func SimplifyDebtsJSON(req string) string`
  - `func ComputeBalancesJSON(req string) string`

JSON schemas (the contract the Dart SDK will code against):

```
ComputeSplits request:
  {"type":"equal","total_cents":10000,"entries":[{"member_id":"a"},...]}
  {"type":"exact","total_cents":N,"entries":[{"member_id":"a","amount_cents":N},...]}
  {"type":"percent","total_cents":N,"entries":[{"member_id":"a","basis_points":N},...]}
  {"type":"shares","total_cents":N,"entries":[{"member_id":"a","shares":N},...]}
ComputeSplits response:
  {"splits":[{"member_id":"a","amount_cents":N},...]}  |  {"error":"..."}

SimplifyDebts request:
  {"balances":[{"member_id":"a","net_cents":N},...]}
SimplifyDebts response:
  {"transfers":[{"from_member_id":"b","to_member_id":"a","amount_cents":N},...]}  |  {"error":"..."}

ComputeBalances request:
  {"expenses":[{"payer_id":"a","amount_cents":N,"splits":[{"member_id":"b","amount_cents":N},...]},...],
   "settlements":[{"from_member_id":"b","to_member_id":"a","amount_cents":N},...]}
ComputeBalances response:
  {"balances":[{"member_id":"a","net_cents":N},...]}  |  {"error":"..."}
```

- [ ] **Step 1: Write failing tests**

Create `splitcore/ffi/handler/handler_test.go`:

```go
package handler

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestComputeSplitsJSON(t *testing.T) {
	tests := []struct {
		name string
		req  string
		want string // exact JSON, or "" when wantErrSub is set
		errSub string
	}{
		{
			name: "equal",
			req:  `{"type":"equal","total_cents":10000,"entries":[{"member_id":"a"},{"member_id":"b"},{"member_id":"c"}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":3334},{"member_id":"b","amount_cents":3333},{"member_id":"c","amount_cents":3333}]}`,
		},
		{
			name: "exact",
			req:  `{"type":"exact","total_cents":500,"entries":[{"member_id":"a","amount_cents":200},{"member_id":"b","amount_cents":300}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":200},{"member_id":"b","amount_cents":300}]}`,
		},
		{
			name: "percent",
			req:  `{"type":"percent","total_cents":10000,"entries":[{"member_id":"a","basis_points":2500},{"member_id":"b","basis_points":7500}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":2500},{"member_id":"b","amount_cents":7500}]}`,
		},
		{
			name: "shares",
			req:  `{"type":"shares","total_cents":6000,"entries":[{"member_id":"a","shares":1},{"member_id":"b","shares":2}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":2000},{"member_id":"b","amount_cents":4000}]}`,
		},
		{
			name:   "domain error surfaces as json error",
			req:    `{"type":"percent","total_cents":100,"entries":[{"member_id":"a","basis_points":5000}]}`,
			errSub: "basis points",
		},
		{
			name:   "unknown type",
			req:    `{"type":"magic","total_cents":100,"entries":[]}`,
			errSub: "unknown split type",
		},
		{
			name:   "malformed json",
			req:    `{"type":`,
			errSub: "parse",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeSplitsJSON(tt.req)
			if tt.errSub != "" {
				var e struct {
					Error string `json:"error"`
				}
				if err := json.Unmarshal([]byte(got), &e); err != nil || e.Error == "" {
					t.Fatalf("want error json, got %s", got)
				}
				if !strings.Contains(e.Error, tt.errSub) {
					t.Fatalf("want error containing %q, got %q", tt.errSub, e.Error)
				}
				return
			}
			if got != tt.want {
				t.Errorf("want %s\ngot  %s", tt.want, got)
			}
		})
	}
}

func TestSimplifyDebtsJSON(t *testing.T) {
	req := `{"balances":[{"member_id":"a","net_cents":500},{"member_id":"b","net_cents":-500}]}`
	want := `{"transfers":[{"from_member_id":"b","to_member_id":"a","amount_cents":500}]}`
	if got := SimplifyDebtsJSON(req); got != want {
		t.Errorf("want %s\ngot  %s", want, got)
	}

	// error path
	got := SimplifyDebtsJSON(`{"balances":[{"member_id":"a","net_cents":1}]}`)
	if !strings.Contains(got, "sum to zero") {
		t.Errorf("want unbalanced error, got %s", got)
	}

	// empty transfers must encode as [] not null
	got = SimplifyDebtsJSON(`{"balances":[]}`)
	if got != `{"transfers":[]}` {
		t.Errorf("want empty array, got %s", got)
	}
}

func TestComputeBalancesJSON(t *testing.T) {
	req := `{"expenses":[{"payer_id":"a","amount_cents":1000,"splits":[{"member_id":"b","amount_cents":1000}]}],"settlements":[{"from_member_id":"b","to_member_id":"a","amount_cents":400}]}`
	want := `{"balances":[{"member_id":"a","net_cents":600},{"member_id":"b","net_cents":-600}]}`
	if got := ComputeBalancesJSON(req); got != want {
		t.Errorf("want %s\ngot  %s", want, got)
	}

	// empty log must encode as [] not null
	got := ComputeBalancesJSON(`{"expenses":[],"settlements":[]}`)
	if got != `{"balances":[]}` {
		t.Errorf("want empty array, got %s", got)
	}
}
```

- [ ] **Step 2: Run tests, verify failure**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./ffi/handler/`
Expected: FAIL — `undefined: ComputeSplitsJSON`, etc.

- [ ] **Step 3: Implement**

Create `splitcore/ffi/handler/handler.go`:

```go
// Package handler is the JSON boundary used by the C FFI exports. It is
// pure Go (no cgo) so the entire FFI contract is unit-testable. Every
// function takes a JSON request and returns a JSON response; failures
// return {"error":"..."} and never panic.
package handler

import (
	"encoding/json"
	"fmt"

	"github.com/abdulroufsidhu/slice_pay/splitcore/balance"
	"github.com/abdulroufsidhu/slice_pay/splitcore/money"
	"github.com/abdulroufsidhu/slice_pay/splitcore/settle"
)

type splitEntry struct {
	MemberID    string `json:"member_id"`
	AmountCents int64  `json:"amount_cents,omitempty"`
	BasisPoints int64  `json:"basis_points,omitempty"`
	Shares      int64  `json:"shares,omitempty"`
}

type splitsRequest struct {
	Type       string       `json:"type"`
	TotalCents int64        `json:"total_cents"`
	Entries    []splitEntry `json:"entries"`
}

type splitOut struct {
	MemberID    string `json:"member_id"`
	AmountCents int64  `json:"amount_cents"`
}

func errJSON(err error) string {
	b, _ := json.Marshal(map[string]string{"error": err.Error()})
	return string(b)
}

// ComputeSplitsJSON dispatches to the split function named by "type".
func ComputeSplitsJSON(req string) string {
	var r splitsRequest
	if err := json.Unmarshal([]byte(req), &r); err != nil {
		return errJSON(fmt.Errorf("parse request: %w", err))
	}

	var splits []money.Split
	var err error
	switch r.Type {
	case "equal":
		ids := make([]string, len(r.Entries))
		for i, e := range r.Entries {
			ids[i] = e.MemberID
		}
		splits, err = money.ComputeEqualSplit(r.TotalCents, ids)
	case "exact":
		entries := make([]money.ExactEntry, len(r.Entries))
		for i, e := range r.Entries {
			entries[i] = money.ExactEntry{MemberID: e.MemberID, AmountCents: e.AmountCents}
		}
		splits, err = money.ComputeExactSplit(r.TotalCents, entries)
	case "percent":
		entries := make([]money.PercentEntry, len(r.Entries))
		for i, e := range r.Entries {
			entries[i] = money.PercentEntry{MemberID: e.MemberID, BasisPoints: e.BasisPoints}
		}
		splits, err = money.ComputePercentSplit(r.TotalCents, entries)
	case "shares":
		entries := make([]money.ShareEntry, len(r.Entries))
		for i, e := range r.Entries {
			entries[i] = money.ShareEntry{MemberID: e.MemberID, Shares: e.Shares}
		}
		splits, err = money.ComputeShareSplit(r.TotalCents, entries)
	default:
		return errJSON(fmt.Errorf("unknown split type %q", r.Type))
	}
	if err != nil {
		return errJSON(err)
	}

	out := make([]splitOut, len(splits))
	for i, s := range splits {
		out[i] = splitOut{MemberID: s.MemberID, AmountCents: s.AmountCents}
	}
	b, _ := json.Marshal(map[string][]splitOut{"splits": out})
	return string(b)
}

type balanceIO struct {
	MemberID string `json:"member_id"`
	NetCents int64  `json:"net_cents"`
}

type transferOut struct {
	FromMemberID string `json:"from_member_id"`
	ToMemberID   string `json:"to_member_id"`
	AmountCents  int64  `json:"amount_cents"`
}

// SimplifyDebtsJSON wraps settle.SimplifyDebts.
func SimplifyDebtsJSON(req string) string {
	var r struct {
		Balances []balanceIO `json:"balances"`
	}
	if err := json.Unmarshal([]byte(req), &r); err != nil {
		return errJSON(fmt.Errorf("parse request: %w", err))
	}
	balances := make([]settle.Balance, len(r.Balances))
	for i, b := range r.Balances {
		balances[i] = settle.Balance{MemberID: b.MemberID, NetCents: b.NetCents}
	}
	transfers, err := settle.SimplifyDebts(balances)
	if err != nil {
		return errJSON(err)
	}
	out := make([]transferOut, len(transfers))
	for i, tr := range transfers {
		out[i] = transferOut{FromMemberID: tr.FromMemberID, ToMemberID: tr.ToMemberID, AmountCents: tr.AmountCents}
	}
	b, _ := json.Marshal(map[string][]transferOut{"transfers": out})
	return string(b)
}

type expenseIn struct {
	PayerID     string     `json:"payer_id"`
	AmountCents int64      `json:"amount_cents"`
	Splits      []splitOut `json:"splits"`
}

type settlementIn struct {
	FromMemberID string `json:"from_member_id"`
	ToMemberID   string `json:"to_member_id"`
	AmountCents  int64  `json:"amount_cents"`
}

// ComputeBalancesJSON wraps balance.ComputeBalances.
func ComputeBalancesJSON(req string) string {
	var r struct {
		Expenses    []expenseIn    `json:"expenses"`
		Settlements []settlementIn `json:"settlements"`
	}
	if err := json.Unmarshal([]byte(req), &r); err != nil {
		return errJSON(fmt.Errorf("parse request: %w", err))
	}
	expenses := make([]balance.Expense, len(r.Expenses))
	for i, e := range r.Expenses {
		splits := make([]money.Split, len(e.Splits))
		for j, s := range e.Splits {
			splits[j] = money.Split{MemberID: s.MemberID, AmountCents: s.AmountCents}
		}
		expenses[i] = balance.Expense{PayerID: e.PayerID, AmountCents: e.AmountCents, Splits: splits}
	}
	settlements := make([]balance.Settlement, len(r.Settlements))
	for i, s := range r.Settlements {
		settlements[i] = balance.Settlement{FromMemberID: s.FromMemberID, ToMemberID: s.ToMemberID, AmountCents: s.AmountCents}
	}
	balances, err := balance.ComputeBalances(expenses, settlements)
	if err != nil {
		return errJSON(err)
	}
	out := make([]balanceIO, len(balances))
	for i, b := range balances {
		out[i] = balanceIO{MemberID: b.MemberID, NetCents: b.NetCents}
	}
	b, _ := json.Marshal(map[string][]balanceIO{"balances": out})
	return string(b)
}
```

- [ ] **Step 4: Run tests, verify pass**

Run: `cd /home/abdul/Projects/slice_pay/splitcore && go test ./ffi/handler/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add splitcore/ffi/handler/
git commit -m "feat(ffi): JSON handler layer for FFI boundary"
```

---

### Task 7: cgo exports + Linux .so + smoke test

**Files:**
- Create: `splitcore/ffi/main.go`
- Create: `splitcore/build/build_linux.sh`
- Create: `splitcore/build/smoke_test.py`

**Interfaces:**
- Consumes: `handler.ComputeSplitsJSON`, `handler.SimplifyDebtsJSON`, `handler.ComputeBalancesJSON`.
- Produces C symbols: `SplitcoreComputeSplits`, `SplitcoreSimplifyDebts`, `SplitcoreComputeBalances`, `SplitcoreFree` in `libsplitcore.so` (later: Android/iOS artifacts).

- [ ] **Step 1: Write the cgo export shim**

Create `splitcore/ffi/main.go`:

```go
// Command ffi builds splitcore as a C shared library. Every export
// takes a JSON request string and returns a malloc'd JSON response
// string that the caller MUST release via SplitcoreFree.
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"unsafe"

	"github.com/abdulroufsidhu/slice_pay/splitcore/ffi/handler"
)

//export SplitcoreComputeSplits
func SplitcoreComputeSplits(req *C.char) *C.char {
	return C.CString(handler.ComputeSplitsJSON(C.GoString(req)))
}

//export SplitcoreSimplifyDebts
func SplitcoreSimplifyDebts(req *C.char) *C.char {
	return C.CString(handler.SimplifyDebtsJSON(C.GoString(req)))
}

//export SplitcoreComputeBalances
func SplitcoreComputeBalances(req *C.char) *C.char {
	return C.CString(handler.ComputeBalancesJSON(C.GoString(req)))
}

//export SplitcoreFree
func SplitcoreFree(p *C.char) {
	C.free(unsafe.Pointer(p))
}

func main() {}
```

- [ ] **Step 2: Write the Linux build script**

Create `splitcore/build/build_linux.sh`:

```bash
#!/usr/bin/env bash
# Builds libsplitcore.so for the host Linux machine.
# Output: splitcore/build/out/linux/libsplitcore.so (+ generated header)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/linux"
mkdir -p "$OUT"

cd "$SCRIPT_DIR/.."
CGO_ENABLED=1 go build -buildmode=c-shared \
  -o "$OUT/libsplitcore.so" ./ffi

echo "Built: $OUT/libsplitcore.so"
```

Run: `chmod +x splitcore/build/build_linux.sh && ./splitcore/build/build_linux.sh`
Expected: `Built: .../out/linux/libsplitcore.so`

- [ ] **Step 3: Verify exported symbols**

Run: `nm -D splitcore/build/out/linux/libsplitcore.so | grep Splitcore`
Expected output contains:

```
T SplitcoreComputeBalances
T SplitcoreComputeSplits
T SplitcoreFree
T SplitcoreSimplifyDebts
```

- [ ] **Step 4: Write ctypes smoke test**

Create `splitcore/build/smoke_test.py`:

```python
#!/usr/bin/env python3
"""Smoke test for libsplitcore.so — proves the C ABI works end to end."""
import ctypes
import json
import os
import sys

so_path = os.path.join(os.path.dirname(__file__), "out", "linux", "libsplitcore.so")
lib = ctypes.CDLL(so_path)

for fn in ("SplitcoreComputeSplits", "SplitcoreSimplifyDebts", "SplitcoreComputeBalances"):
    getattr(lib, fn).argtypes = [ctypes.c_char_p]
    getattr(lib, fn).restype = ctypes.c_void_p  # keep pointer for Free
lib.SplitcoreFree.argtypes = [ctypes.c_void_p]


def call(fn, req: dict) -> dict:
    ptr = getattr(lib, fn)(json.dumps(req).encode())
    try:
        return json.loads(ctypes.string_at(ptr).decode())
    finally:
        lib.SplitcoreFree(ptr)


splits = call("SplitcoreComputeSplits", {
    "type": "equal", "total_cents": 10000,
    "entries": [{"member_id": m} for m in ("a", "b", "c")],
})
assert splits == {"splits": [
    {"member_id": "a", "amount_cents": 3334},
    {"member_id": "b", "amount_cents": 3333},
    {"member_id": "c", "amount_cents": 3333},
]}, splits

transfers = call("SplitcoreSimplifyDebts", {
    "balances": [{"member_id": "a", "net_cents": 500},
                 {"member_id": "b", "net_cents": -500}],
})
assert transfers == {"transfers": [
    {"from_member_id": "b", "to_member_id": "a", "amount_cents": 500},
]}, transfers

balances = call("SplitcoreComputeBalances", {
    "expenses": [{"payer_id": "a", "amount_cents": 1000,
                  "splits": [{"member_id": "b", "amount_cents": 1000}]}],
    "settlements": [{"from_member_id": "b", "to_member_id": "a", "amount_cents": 400}],
})
assert balances == {"balances": [
    {"member_id": "a", "net_cents": 600},
    {"member_id": "b", "net_cents": -600},
]}, balances

err = call("SplitcoreComputeSplits", {"type": "magic", "total_cents": 1, "entries": []})
assert "error" in err, err

print("smoke test OK")
```

- [ ] **Step 5: Run smoke test**

Run: `python3 splitcore/build/smoke_test.py`
Expected: `smoke test OK`

- [ ] **Step 6: Commit**

```bash
git add splitcore/ffi/main.go splitcore/build/build_linux.sh splitcore/build/smoke_test.py
git commit -m "feat(ffi): cgo exports, linux c-shared build, ctypes smoke test"
```

---

### Task 8: Android + iOS build scripts and docs

**Files:**
- Create: `splitcore/build/build_android.sh`
- Create: `splitcore/build/build_ios.sh`
- Create: `splitcore/build/BUILD.md`

**Interfaces:**
- Produces: `jniLibs/<abi>/libsplitcore.so` per Android ABI; `out/ios/libsplitcore.a` + header for iOS arm64.

- [ ] **Step 1: Write Android build script**

Create `splitcore/build/build_android.sh`:

```bash
#!/usr/bin/env bash
# Cross-compiles libsplitcore.so for all standard Android ABIs.
# Requires ANDROID_NDK_HOME (or auto-detects newest NDK under
# $ANDROID_HOME/ndk). Output: build/out/android/jniLibs/<abi>/libsplitcore.so
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/android/jniLibs"
API=24

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
  base="${ANDROID_HOME:-$HOME/Android/Sdk}/ndk"
  if [[ -d "$base" ]]; then
    ANDROID_NDK_HOME="$base/$(ls "$base" | sort -V | tail -n1)"
  fi
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
  echo "error: ANDROID_NDK_HOME not set and no NDK found" >&2
  exit 1
fi

TOOLCHAIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"

# abi:GOARCH:clang-target
targets=(
  "arm64-v8a:arm64:aarch64-linux-android"
  "armeabi-v7a:arm:armv7a-linux-androideabi"
  "x86_64:amd64:x86_64-linux-android"
  "x86:386:i686-linux-android"
)

cd "$SCRIPT_DIR/.."
for t in "${targets[@]}"; do
  IFS=: read -r abi goarch triple <<<"$t"
  mkdir -p "$OUT/$abi"
  echo "building $abi ..."
  env CGO_ENABLED=1 GOOS=android GOARCH="$goarch" \
    ${goarch:+$( [[ $goarch == arm ]] && echo GOARM=7 )} \
    CC="$TOOLCHAIN/${triple}${API}-clang" \
    go build -buildmode=c-shared -o "$OUT/$abi/libsplitcore.so" ./ffi
done

echo "Done. jniLibs at: $OUT"
```

- [ ] **Step 2: Write iOS build script**

Create `splitcore/build/build_ios.sh`:

```bash
#!/usr/bin/env bash
# Cross-compiles splitcore as a static library for iOS arm64.
# MUST run on macOS with Xcode installed (cgo needs Apple clang + SDK).
# Go does not support -buildmode=c-shared on iOS; c-archive is the
# supported route — link the .a into the app and expose via a module map.
# Output: build/out/ios/libsplitcore.a + libsplitcore.h
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
  echo "error: iOS build requires macOS with Xcode" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$SCRIPT_DIR/out/ios"
mkdir -p "$OUT"

cd "$SCRIPT_DIR/.."
env CGO_ENABLED=1 GOOS=ios GOARCH=arm64 \
  SDK=iphoneos \
  CC="$(xcrun --sdk iphoneos --find clang)" \
  CGO_CFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64" \
  CGO_LDFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -arch arm64" \
  go build -buildmode=c-archive -o "$OUT/libsplitcore.a" ./ffi

echo "Built: $OUT/libsplitcore.a"
```

- [ ] **Step 3: Write BUILD.md**

Create `splitcore/build/BUILD.md`:

```markdown
# splitcore build guide

All scripts output under `splitcore/build/out/` (gitignored).

## Verification status

| Target | Script | Verified in dev environment? |
|---|---|---|
| Linux x86_64 `.so` | `build_linux.sh` | ✅ built + ctypes smoke test |
| Android (4 ABIs) | `build_android.sh` | ⚠️ script runs only if NDK installed — check output table below after running |
| iOS arm64 `.a` | `build_ios.sh` | ❌ requires macOS/Xcode — **user must verify** |

## Linux (host)

    ./build_linux.sh
    python3 smoke_test.py        # end-to-end ABI check

## Android

Requires NDK. Set `ANDROID_NDK_HOME`, or the script auto-detects the
newest NDK under `$ANDROID_HOME/ndk`.

    ./build_android.sh

Produces `out/android/jniLibs/{arm64-v8a,armeabi-v7a,x86_64,x86}/libsplitcore.so`.
Copy the `jniLibs` folder into the Flutter Android app module
(`android/app/src/main/jniLibs/`), or reference from the SDK's plugin build.

Min API: 24 (change `API=` in the script if you need lower; Go requires ≥21).

## iOS

Run **on macOS**:

    ./build_ios.sh

Produces a static archive `out/ios/libsplitcore.a` + `libsplitcore.h`.
Integration: add the `.a` and header to the Xcode project (or wrap in a
CocoaPod/SwiftPM target), then Dart FFI resolves symbols from the process
image via `DynamicLibrary.process()` — static libs are linked into the
app binary on iOS.

Simulator note: for the iOS *simulator* on Apple Silicon you need a
separate `GOOS=ios GOARCH=arm64` build against the `iphonesimulator`
SDK, combined with the device build via `lipo`/`xcodebuild
-create-xcframework`. Deferred until there's an actual iOS app target.
```

- [ ] **Step 4: Make scripts executable, try Android build if NDK present**

```bash
chmod +x splitcore/build/build_android.sh splitcore/build/build_ios.sh
ls "$HOME/Android/Sdk/ndk" 2>/dev/null && ./splitcore/build/build_android.sh || echo "NDK absent — Android build unverified, flag to user"
```

Expected: either all four ABIs build (record success in BUILD.md), or the NDK-absent message (leave BUILD.md status as ⚠️).

- [ ] **Step 5: Commit**

```bash
git add splitcore/build/
git commit -m "feat(build): android/ios cross-compile scripts and build docs"
```

---

## Verification summary duty (for the executor)

After Task 8, report to the user:
- Full `go test ./...` output for splitcore
- Smoke test output
- Which cross-compile targets were actually built vs which need user hardware
