// Package balance recomputes member net balances from the full record
// set (expenses + settlements). This is the only way balances are ever
// produced; any stored balance table is a cache of this function's
// output. Deterministic: output sorted by MemberID ascending.
package balance

import (
	"errors"
	"sort"

	"github.com/abdulroufsidhu/splitcore/splitcore/money"
	"github.com/abdulroufsidhu/splitcore/splitcore/settle"
)

var (
	ErrSplitSumMismatch  = errors.New("balance: split entries do not sum to expense amount")
	ErrNonPositiveAmount = errors.New("balance: amount must be positive")
	ErrSelfSettlement    = errors.New("balance: settlement from and to must differ")
	ErrOverflow          = errors.New("balance: amount sum overflows int64")
)

// addChecked returns a+b and false if the signed addition overflows int64.
func addChecked(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}

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
			// Zero-amount splits are intentionally allowed here (a member
			// can be included in a bill while owing nothing), matching
			// money.ComputeExactSplit's semantics.
			if s.AmountCents < 0 {
				return nil, ErrNonPositiveAmount
			}
			var ok bool
			splitSum, ok = addChecked(splitSum, s.AmountCents)
			if !ok {
				return nil, ErrOverflow
			}
		}
		if splitSum != e.AmountCents {
			return nil, ErrSplitSumMismatch
		}
		var ok bool
		if net[e.PayerID], ok = addChecked(net[e.PayerID], e.AmountCents); !ok {
			return nil, ErrOverflow
		}
		for _, s := range e.Splits {
			if net[s.MemberID], ok = addChecked(net[s.MemberID], -s.AmountCents); !ok {
				return nil, ErrOverflow
			}
		}
	}

	for _, s := range settlements {
		if s.AmountCents <= 0 {
			return nil, ErrNonPositiveAmount
		}
		if s.FromMemberID == s.ToMemberID {
			return nil, ErrSelfSettlement
		}
		var ok bool
		if net[s.FromMemberID], ok = addChecked(net[s.FromMemberID], s.AmountCents); !ok {
			return nil, ErrOverflow
		}
		if net[s.ToMemberID], ok = addChecked(net[s.ToMemberID], -s.AmountCents); !ok {
			return nil, ErrOverflow
		}
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
