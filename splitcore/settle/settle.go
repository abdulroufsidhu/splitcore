// Package settle turns a set of member balances into a minimal-ish list
// of transfers using a greedy max-debtor→max-creditor strategy. The
// result is deterministic (ties broken by member id ascending) and
// contains at most n−1 transfers for n members.
package settle

import "errors"

var (
	ErrUnbalanced      = errors.New("settle: balances do not sum to zero")
	ErrDuplicateMember = errors.New("settle: duplicate member id")
	ErrOverflow        = errors.New("settle: balance sum overflows int64")
)

// addChecked returns a+b and false if the signed addition overflows int64.
func addChecked(a, b int64) (int64, bool) {
	sum := a + b
	if (b > 0 && sum < a) || (b < 0 && sum > a) {
		return 0, false
	}
	return sum, true
}

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
		var ok bool
		sum, ok = addChecked(sum, b.NetCents)
		if !ok {
			return nil, ErrOverflow
		}
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
		if debtor == "" || maxDebt == 0 {
			// Unreachable given the sum==0 check above, but guarded so a
			// creditor without a matching debtor can never spin forever.
			return nil, ErrUnbalanced
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
