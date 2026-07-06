// Package testfix builds a fully-populated splitcore test app (schema +
// two users, one group, both users as group_members) for use by the
// hook and API tests in Tasks 4-6.
package testfix

import (
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/abdulroufsidhu/slice_pay/server/hooks"
	"github.com/abdulroufsidhu/slice_pay/server/migrations"
)

// Fixture holds a test app with schema + two users, one group
// (currency USD, owner alice), and both users as group_members.
type Fixture struct {
	App          *tests.TestApp
	Alice, Bob   *core.Record // users
	Group        *core.Record
	AliceM, BobM *core.Record // group_members rows
}

// New creates a fresh test app with the splitcore schema and a
// group/alice/bob fixture already saved, and registers t.Cleanup to tear
// it down. tb is testing.TB (not just *testing.T) so it can also be
// called from within t.Run subtests or benchmarks.
func New(tb testing.TB) *Fixture {
	tb.Helper()

	app, err := tests.NewTestApp()
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(app.Cleanup)

	// tests.NewTestApp() already runs all registered migrations, so this
	// is a safe, mostly-no-op call (see migrations.getOrCreateCollection).
	if err := migrations.InitCollections(app); err != nil {
		tb.Fatal(err)
	}
	hooks.Register(app)

	usersCol, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		tb.Fatal(err)
	}

	alice := core.NewRecord(usersCol)
	alice.Set("email", "alice@example.com")
	alice.Set("password", "password123")
	alice.Set("verified", true)
	if err := app.Save(alice); err != nil {
		tb.Fatal(err)
	}

	bob := core.NewRecord(usersCol)
	bob.Set("email", "bob@example.com")
	bob.Set("password", "password123")
	bob.Set("verified", true)
	if err := app.Save(bob); err != nil {
		tb.Fatal(err)
	}

	groupsCol, err := app.FindCollectionByNameOrId("groups")
	if err != nil {
		tb.Fatal(err)
	}
	group := core.NewRecord(groupsCol)
	group.Set("name", "Test Group")
	group.Set("currency", "USD")
	group.Set("owner", alice.Id)
	if err := app.Save(group); err != nil {
		tb.Fatal(err)
	}

	membersCol, err := app.FindCollectionByNameOrId("group_members")
	if err != nil {
		tb.Fatal(err)
	}

	aliceM := core.NewRecord(membersCol)
	aliceM.Set("group", group.Id)
	aliceM.Set("user", alice.Id)
	aliceM.Set("role", "owner")
	if err := app.Save(aliceM); err != nil {
		tb.Fatal(err)
	}

	bobM := core.NewRecord(membersCol)
	bobM.Set("group", group.Id)
	bobM.Set("user", bob.Id)
	bobM.Set("role", "member")
	if err := app.Save(bobM); err != nil {
		tb.Fatal(err)
	}

	return &Fixture{
		App:    app,
		Alice:  alice,
		Bob:    bob,
		Group:  group,
		AliceM: aliceM,
		BobM:   bobM,
	}
}

// CreateExpense saves and returns a new expenses record. payer must be a
// group_members record (e.g. f.AliceM or f.BobM), not a users record.
func (f *Fixture) CreateExpense(tb testing.TB, payer *core.Record, amount int64, splitType string) *core.Record {
	tb.Helper()

	col, err := f.App.FindCollectionByNameOrId("expenses")
	if err != nil {
		tb.Fatal(err)
	}

	expense := core.NewRecord(col)
	expense.Set("group", f.Group.Id)
	expense.Set("payer", payer.Id)
	expense.Set("amount_cents", amount)
	expense.Set("split_type", splitType)
	if err := f.App.Save(expense); err != nil {
		tb.Fatal(err)
	}

	return expense
}

// CreateSplit saves and returns a new split_entries record.
func (f *Fixture) CreateSplit(tb testing.TB, expense, member *core.Record, amount int64) *core.Record {
	tb.Helper()

	col, err := f.App.FindCollectionByNameOrId("split_entries")
	if err != nil {
		tb.Fatal(err)
	}

	split := core.NewRecord(col)
	split.Set("expense", expense.Id)
	split.Set("member", member.Id)
	split.Set("amount_cents", amount)
	if err := f.App.Save(split); err != nil {
		tb.Fatal(err)
	}

	return split
}

// CreateSettlement saves and returns a new settlements record.
func (f *Fixture) CreateSettlement(tb testing.TB, from, to *core.Record, amount int64) *core.Record {
	tb.Helper()

	col, err := f.App.FindCollectionByNameOrId("settlements")
	if err != nil {
		tb.Fatal(err)
	}

	settlement := core.NewRecord(col)
	settlement.Set("group", f.Group.Id)
	settlement.Set("from_member", from.Id)
	settlement.Set("to_member", to.Id)
	settlement.Set("amount_cents", amount)
	if err := f.App.Save(settlement); err != nil {
		tb.Fatal(err)
	}

	return settlement
}

// Balances returns the current balances rows for f.Group, keyed by member
// (group_members) record id, with values in net_cents.
func (f *Fixture) Balances(tb testing.TB) map[string]int64 {
	tb.Helper()

	recs, err := f.App.FindRecordsByFilter("balances", "group = {:g}", "", 0, 0, dbx.Params{"g": f.Group.Id})
	if err != nil {
		tb.Fatal(err)
	}

	balances := make(map[string]int64, len(recs))
	for _, r := range recs {
		balances[r.GetString("member")] = int64(r.GetInt("net_cents"))
	}

	return balances
}

// Version re-fetches f.Group from the app and returns its current
// version counter.
func (f *Fixture) Version(tb testing.TB) int {
	tb.Helper()

	group, err := f.App.FindRecordById("groups", f.Group.Id)
	if err != nil {
		tb.Fatal(err)
	}

	return group.GetInt("version")
}
