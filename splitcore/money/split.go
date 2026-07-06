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
	ErrNoMembers         = errors.New("money: no members")
	ErrNonPositiveTotal  = errors.New("money: total must be positive")
	ErrDuplicateMember   = errors.New("money: duplicate member id")
	ErrNonPositiveShare  = errors.New("money: share/weight must be positive")
	ErrOverflow          = errors.New("money: computation would overflow int64")
	ErrExactSumMismatch  = errors.New("money: exact entries do not sum to total")
	ErrNegativeAmount    = errors.New("money: amount must not be negative")
	ErrPercentSumInvalid = errors.New("money: basis points must sum to 10000")
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
