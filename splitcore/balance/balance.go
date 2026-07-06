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
