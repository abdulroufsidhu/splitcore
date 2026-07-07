package hooks

import (
	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"github.com/abdulroufsidhu/slice_pay/splitcore/balance"
	"github.com/abdulroufsidhu/slice_pay/splitcore/money"
)

// bumpAndRecompute increments the group's version and rewrites its
// balances rows from the current record set. Incomplete expenses
// (split entries not yet summing to the amount) are skipped — they
// contribute nothing until the client finishes writing them.
//
// The whole bump+rewrite runs in a single transaction so a failure
// mid-recompute (e.g. during balance reinsertion) can never leave the
// version bumped alongside partial or missing balances rows.
func bumpAndRecompute(app core.App, groupID string) error {
	return app.RunInTransaction(func(txApp core.App) error {
		return bumpAndRecomputeTx(txApp, groupID)
	})
}

func bumpAndRecomputeTx(app core.App, groupID string) error {
	group, err := app.FindRecordById("groups", groupID)
	if err != nil {
		return err
	}
	group.Set("version", group.GetInt("version")+1)
	if err := app.Save(group); err != nil {
		return err
	}

	expenses, err := app.FindRecordsByFilter("expenses", "group = {:g}", "", 0, 0, dbx.Params{"g": groupID})
	if err != nil {
		return err
	}
	var coreExpenses []balance.Expense
	for _, exp := range expenses {
		entries, err := app.FindRecordsByFilter("split_entries", "expense = {:e}", "", 0, 0, dbx.Params{"e": exp.Id})
		if err != nil {
			return err
		}
		var splits []money.Split
		var sum int64
		for _, en := range entries {
			amt := int64(en.GetInt("amount_cents"))
			splits = append(splits, money.Split{MemberID: en.GetString("member"), AmountCents: amt})
			sum += amt
		}
		amount := int64(exp.GetInt("amount_cents"))
		if sum != amount { // incomplete — skip
			continue
		}
		coreExpenses = append(coreExpenses, balance.Expense{
			PayerID:     exp.GetString("payer"),
			AmountCents: amount,
			Splits:      splits,
		})
	}

	settleRecs, err := app.FindRecordsByFilter("settlements", "group = {:g}", "", 0, 0, dbx.Params{"g": groupID})
	if err != nil {
		return err
	}
	var coreSettlements []balance.Settlement
	for _, s := range settleRecs {
		coreSettlements = append(coreSettlements, balance.Settlement{
			FromMemberID: s.GetString("from_member"),
			ToMemberID:   s.GetString("to_member"),
			AmountCents:  int64(s.GetInt("amount_cents")),
		})
	}

	nets, err := balance.ComputeBalances(coreExpenses, coreSettlements)
	if err != nil {
		return err
	}

	old, err := app.FindRecordsByFilter("balances", "group = {:g}", "", 0, 0, dbx.Params{"g": groupID})
	if err != nil {
		return err
	}
	for _, r := range old {
		if err := app.Delete(r); err != nil {
			return err
		}
	}
	balCol, err := app.FindCollectionByNameOrId("balances")
	if err != nil {
		return err
	}
	for _, n := range nets {
		r := core.NewRecord(balCol)
		r.Set("group", groupID)
		r.Set("member", n.MemberID)
		r.Set("net_cents", n.NetCents)
		if err := app.Save(r); err != nil {
			return err
		}
	}
	return nil
}
