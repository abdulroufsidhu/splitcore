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
