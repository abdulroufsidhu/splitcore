package hooks_test

import (
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"

	"github.com/abdulroufsidhu/splitcore/server/internal/testfix"
)

// ---------------------------------------------------------------------
// version counter
// ---------------------------------------------------------------------

func TestVersionIncrementsOnExpenseCreate(t *testing.T) {
	f := testfix.New(t)
	// Relative to whatever the fixture's own setup left behind: building it
	// adds two members, and those bump the version too.
	before := f.Version(t)

	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)

	if got := f.Version(t) - before; got != 3 {
		t.Fatalf("version delta after expense+2 splits = %d, want 3", got)
	}
}

func TestVersionIncrementsOnMembershipChange(t *testing.T) {
	f := testfix.New(t)
	before := f.Version(t)

	// A membership change moves no money, so nothing here recomputes — but
	// it does change what every member's client must re-fetch, and version
	// is the only signal they get. Left unbumped, a newly added member
	// stayed invisible on everyone else's device until an unrelated expense
	// happened to bump the version for them.
	usersCol, err := f.App.FindCollectionByNameOrId("users")
	if err != nil {
		t.Fatal(err)
	}
	carol := core.NewRecord(usersCol)
	carol.Set("email", "carol@example.com")
	carol.Set("password", "password123")
	carol.Set("verified", true)
	if err := f.App.Save(carol); err != nil {
		t.Fatal(err)
	}

	membersCol, err := f.App.FindCollectionByNameOrId("group_members")
	if err != nil {
		t.Fatal(err)
	}
	carolM := core.NewRecord(membersCol)
	carolM.Set("group", f.Group.Id)
	carolM.Set("user", carol.Id)
	carolM.Set("role", "member")
	if err := f.App.Save(carolM); err != nil {
		t.Fatal(err)
	}

	afterAdd := f.Version(t)
	if got := afterAdd - before; got != 1 {
		t.Fatalf("version delta after adding a member = %d, want 1", got)
	}

	if err := f.App.Delete(carolM); err != nil {
		t.Fatal(err)
	}
	if got := f.Version(t) - afterAdd; got != 1 {
		t.Fatalf("version delta after removing a member = %d, want 1", got)
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
// group delete cascade
// ---------------------------------------------------------------------

// TestDeletePopulatedGroupSucceeds is a regression test for the bug where
// deleting a group with expenses/settlements aborted: each cascaded
// expense/settlement/split_entries delete fired the recompute hook, which
// looked up the group by id to bump its version — but the group row was
// already gone (sql.ErrNoRows), aborting the whole delete transaction.
func TestDeletePopulatedGroupSucceeds(t *testing.T) {
	f := testfix.New(t)
	expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
	f.CreateSplit(t, expense, f.AliceM, 1000)
	f.CreateSplit(t, expense, f.BobM, 2000)
	f.CreateSettlement(t, f.BobM, f.AliceM, 500)

	if err := f.App.Delete(f.Group); err != nil {
		t.Fatalf("delete populated group: %v", err)
	}

	expenses, err := f.App.FindRecordsByFilter("expenses", "group = {:g}", "", 0, 0, dbx.Params{"g": f.Group.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(expenses) != 0 {
		t.Errorf("expenses remaining after group delete = %d, want 0", len(expenses))
	}

	settlements, err := f.App.FindRecordsByFilter("settlements", "group = {:g}", "", 0, 0, dbx.Params{"g": f.Group.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(settlements) != 0 {
		t.Errorf("settlements remaining after group delete = %d, want 0", len(settlements))
	}

	balances, err := f.App.FindRecordsByFilter("balances", "group = {:g}", "", 0, 0, dbx.Params{"g": f.Group.Id})
	if err != nil {
		t.Fatal(err)
	}
	if len(balances) != 0 {
		t.Errorf("balances remaining after group delete = %d, want 0", len(balances))
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

// ---------------------------------------------------------------------
// group re-parenting rejection
// ---------------------------------------------------------------------

// newOtherGroup creates a second group (owned by alice) with alice and bob
// as members, so tests can attempt to move a record into "another group".
func newOtherGroup(t testing.TB, f *testfix.Fixture) (group, aliceM2, bobM2 *core.Record) {
	t.Helper()

	groupsCol, err := f.App.FindCollectionByNameOrId("groups")
	if err != nil {
		t.Fatal(err)
	}
	group = core.NewRecord(groupsCol)
	group.Set("name", "Other Group")
	group.Set("currency", "USD")
	group.Set("owner", f.Alice.Id)
	if err := f.App.Save(group); err != nil {
		t.Fatal(err)
	}

	membersCol, err := f.App.FindCollectionByNameOrId("group_members")
	if err != nil {
		t.Fatal(err)
	}

	aliceM2 = core.NewRecord(membersCol)
	aliceM2.Set("group", group.Id)
	aliceM2.Set("user", f.Alice.Id)
	aliceM2.Set("role", "owner")
	if err := f.App.Save(aliceM2); err != nil {
		t.Fatal(err)
	}

	bobM2 = core.NewRecord(membersCol)
	bobM2.Set("group", group.Id)
	bobM2.Set("user", f.Bob.Id)
	bobM2.Set("role", "member")
	if err := f.App.Save(bobM2); err != nil {
		t.Fatal(err)
	}

	return group, aliceM2, bobM2
}

// refetch re-reads a record by id, exactly as the real PATCH request
// handler does (apis.recordUpdate calls FindRecordById before applying the
// request body). Record.Original() only reflects real pre-change state on
// a record loaded this way — a record that was merely NewRecord()'d and
// Save()'d in-process never has its originalData refreshed post-insert, so
// tests must re-fetch before mutating to exercise the re-parent guard
// faithfully.
func refetch(t testing.TB, f *testfix.Fixture, collection, id string) *core.Record {
	t.Helper()
	r, err := f.App.FindRecordById(collection, id)
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestExpenseGroupChangeRejected(t *testing.T) {
	f := testfix.New(t)
	created := f.CreateExpense(t, f.AliceM, 3000, "exact")

	otherGroup, aliceM2, _ := newOtherGroup(t, f)

	expense := refetch(t, f, "expenses", created.Id)
	// Payer is switched to a member of the new group too, so the only
	// thing that can fail here is the group re-parent guard itself (not
	// the pre-existing payer-must-belong-to-group check).
	expense.Set("group", otherGroup.Id)
	expense.Set("payer", aliceM2.Id)
	if err := f.App.Save(expense); err == nil {
		t.Fatal("expected error re-parenting expense to another group, got nil")
	}
}

func TestSettlementGroupChangeRejected(t *testing.T) {
	f := testfix.New(t)
	created := f.CreateSettlement(t, f.AliceM, f.BobM, 500)

	otherGroup, aliceM2, bobM2 := newOtherGroup(t, f)

	settlement := refetch(t, f, "settlements", created.Id)
	settlement.Set("group", otherGroup.Id)
	settlement.Set("from_member", aliceM2.Id)
	settlement.Set("to_member", bobM2.Id)
	if err := f.App.Save(settlement); err == nil {
		t.Fatal("expected error re-parenting settlement to another group, got nil")
	}
}

func TestSplitMovedToExpenseInAnotherGroupRejected(t *testing.T) {
	f := testfix.New(t)
	expense1 := f.CreateExpense(t, f.AliceM, 1000, "exact")
	created := f.CreateSplit(t, expense1, f.AliceM, 500)

	otherGroup, aliceM2, _ := newOtherGroup(t, f)

	expCol, err := f.App.FindCollectionByNameOrId("expenses")
	if err != nil {
		t.Fatal(err)
	}
	expense2 := core.NewRecord(expCol)
	expense2.Set("group", otherGroup.Id)
	expense2.Set("payer", aliceM2.Id)
	expense2.Set("amount_cents", 1000)
	expense2.Set("split_type", "exact")
	if err := f.App.Save(expense2); err != nil {
		t.Fatal(err)
	}

	split := refetch(t, f, "split_entries", created.Id)
	// Member is switched to one valid for expense2's group too, isolating
	// the failure to the group re-parent guard.
	split.Set("expense", expense2.Id)
	split.Set("member", aliceM2.Id)
	if err := f.App.Save(split); err == nil {
		t.Fatal("expected error moving split to an expense in another group, got nil")
	}
}

func TestSplitMovedToExpenseInSameGroupAllowed(t *testing.T) {
	f := testfix.New(t)
	expense1 := f.CreateExpense(t, f.AliceM, 1000, "exact")
	expense2 := f.CreateExpense(t, f.BobM, 2000, "exact")
	created := f.CreateSplit(t, expense1, f.AliceM, 500)

	split := refetch(t, f, "split_entries", created.Id)
	split.Set("expense", expense2.Id)
	if err := f.App.Save(split); err != nil {
		t.Fatalf("expected split move between expenses in the same group to succeed, got error: %v", err)
	}
}
