package hooks_test

import (
	"testing"

	"github.com/pocketbase/pocketbase/core"

	"github.com/abdulroufsidhu/slice_pay/server/internal/testfix"
)

// ---------------------------------------------------------------------
// version counter
// ---------------------------------------------------------------------

func TestVersionIncrementsOnExpenseCreate(t *testing.T) {
	f := testfix.New(t)
	if v := f.Version(t); v != 0 {
		t.Fatalf("initial version = %d, want 0", v)
	}

	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)

	if v := f.Version(t); v != 3 {
		t.Fatalf("version after expense+2 splits = %d, want 3", v)
	}
}

func TestVersionIncrementsOnSettlement(t *testing.T) {
	f := testfix.New(t)
	before := f.Version(t)

	f.CreateSettlement(t, f.AliceM, f.BobM, 500)

	if got := f.Version(t) - before; got != 1 {
		t.Fatalf("version delta after settlement create = %d, want 1", got)
	}
}

func TestVersionIncrementsOnDelete(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)

	before := f.Version(t)

	if err := f.App.Delete(expense); err != nil {
		t.Fatalf("delete expense: %v", err)
	}

	// Cascade-deleted split_entries may fire their own delete hooks too, so
	// we only require the version to have moved forward, not an exact +1.
	if got := f.Version(t); got <= before {
		t.Fatalf("version after delete = %d, want > %d", got, before)
	}
}

// ---------------------------------------------------------------------
// balances cache
// ---------------------------------------------------------------------

func TestBalancesAfterCompleteExpense(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)

	balances := f.Balances(t)
	if balances[f.AliceM.Id] != 2000 {
		t.Errorf("alice balance = %d, want 2000", balances[f.AliceM.Id])
	}
	if balances[f.BobM.Id] != -2000 {
		t.Errorf("bob balance = %d, want -2000", balances[f.BobM.Id])
	}
}

func TestIncompleteExpenseExcluded(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	// no second split entered yet: 1000 != 3000, expense is incomplete

	balances := f.Balances(t)
	for member, net := range balances {
		if net != 0 {
			t.Errorf("member %s balance = %d, want 0 (incomplete expense must be excluded)", member, net)
		}
	}
}

func TestSettlementUpdatesBalances(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)

	// bob settles 500 to alice
	f.CreateSettlement(t, f.BobM, f.AliceM, 500)

	balances := f.Balances(t)
	if balances[f.AliceM.Id] != 1500 {
		t.Errorf("alice balance after settlement = %d, want 1500", balances[f.AliceM.Id])
	}
	if balances[f.BobM.Id] != -1500 {
		t.Errorf("bob balance after settlement = %d, want -1500", balances[f.BobM.Id])
	}
}

func TestBalancesRewrittenNotDuplicated(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)
	// another mutation triggering a second recompute
	f.CreateSettlement(t, f.BobM, f.AliceM, 500)

	balances := f.Balances(t)
	if len(balances) != 2 {
		t.Fatalf("balances row count = %d, want 2 (one per member, rewritten not duplicated)", len(balances))
	}
}

// ---------------------------------------------------------------------
// validation
// ---------------------------------------------------------------------

func TestExpenseNonPositiveAmountRejected(t *testing.T) {
	f := testfix.New(t)

	col, err := f.App.FindCollectionByNameOrId("expenses")
	if err != nil {
		t.Fatal(err)
	}
	expense := core.NewRecord(col)
	expense.Set("group", f.Group.Id)
	expense.Set("payer", f.AliceM.Id)
	expense.Set("amount_cents", 0)
	expense.Set("split_type", "exact")

	if err := f.App.Save(expense); err == nil {
		t.Fatal("expected error for non-positive expense amount, got nil")
	}
}

func TestExpensePayerFromOtherGroupRejected(t *testing.T) {
	f := testfix.New(t)

	groupsCol, err := f.App.FindCollectionByNameOrId("groups")
	if err != nil {
		t.Fatal(err)
	}
	otherGroup := core.NewRecord(groupsCol)
	otherGroup.Set("name", "Other Group")
	otherGroup.Set("currency", "USD")
	otherGroup.Set("owner", f.Alice.Id)
	if err := f.App.Save(otherGroup); err != nil {
		t.Fatal(err)
	}

	membersCol, err := f.App.FindCollectionByNameOrId("group_members")
	if err != nil {
		t.Fatal(err)
	}
	otherMember := core.NewRecord(membersCol)
	otherMember.Set("group", otherGroup.Id)
	otherMember.Set("user", f.Alice.Id)
	otherMember.Set("role", "owner")
	if err := f.App.Save(otherMember); err != nil {
		t.Fatal(err)
	}

	expCol, err := f.App.FindCollectionByNameOrId("expenses")
	if err != nil {
		t.Fatal(err)
	}
	expense := core.NewRecord(expCol)
	expense.Set("group", f.Group.Id)
	expense.Set("payer", otherMember.Id) // member belongs to otherGroup, not f.Group
	expense.Set("amount_cents", 1000)
	expense.Set("split_type", "exact")

	if err := f.App.Save(expense); err == nil {
		t.Fatal("expected error for payer from a different group, got nil")
	}
}

func TestSplitNegativeAmountRejected(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 1000, "exact")

	col, err := f.App.FindCollectionByNameOrId("split_entries")
	if err != nil {
		t.Fatal(err)
	}
	split := core.NewRecord(col)
	split.Set("expense", expense.Id)
	split.Set("member", f.AliceM.Id)
	split.Set("amount_cents", -100)

	if err := f.App.Save(split); err == nil {
		t.Fatal("expected error for negative split amount, got nil")
	}
}

func TestSplitZeroAmountAllowed(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 1000, "exact")

	split := f.CreateSplit(t, expense, f.BobM, 0)
	if split.GetInt("amount_cents") != 0 {
		t.Errorf("split amount = %d, want 0", split.GetInt("amount_cents"))
	}
}

func TestSettlementSelfRejected(t *testing.T) {
	f := testfix.New(t)

	col, err := f.App.FindCollectionByNameOrId("settlements")
	if err != nil {
		t.Fatal(err)
	}
	s := core.NewRecord(col)
	s.Set("group", f.Group.Id)
	s.Set("from_member", f.AliceM.Id)
	s.Set("to_member", f.AliceM.Id)
	s.Set("amount_cents", 100)

	if err := f.App.Save(s); err == nil {
		t.Fatal("expected error for self-settlement, got nil")
	}
}

func TestSettlementNonPositiveRejected(t *testing.T) {
	f := testfix.New(t)

	col, err := f.App.FindCollectionByNameOrId("settlements")
	if err != nil {
		t.Fatal(err)
	}
	s := core.NewRecord(col)
	s.Set("group", f.Group.Id)
	s.Set("from_member", f.AliceM.Id)
	s.Set("to_member", f.BobM.Id)
	s.Set("amount_cents", 0)

	if err := f.App.Save(s); err == nil {
		t.Fatal("expected error for non-positive settlement amount, got nil")
	}
}

func TestSettlementOverpayAllowed(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)
	// bob owes 2000; overpay by settling 3000 to alice
	f.CreateSettlement(t, f.BobM, f.AliceM, 3000)

	balances := f.Balances(t)
	if balances[f.BobM.Id] <= 0 {
		t.Errorf("bob balance after overpay = %d, want positive (sign flipped)", balances[f.BobM.Id])
	}
	if balances[f.AliceM.Id] >= 0 {
		t.Errorf("alice balance after overpay = %d, want negative (sign flipped)", balances[f.AliceM.Id])
	}
}
