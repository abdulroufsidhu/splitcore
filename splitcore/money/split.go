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
	ErrNonPositiveShare = errors.New("money: share/weight must be positive")
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
