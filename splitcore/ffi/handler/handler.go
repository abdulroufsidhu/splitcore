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
