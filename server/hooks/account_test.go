package hooks_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/abdulroufsidhu/splitcore/server/internal/testfix"
)

// ---------------------------------------------------------------------
// POST /api/splitcore/delete-account
//
// Same TestAppFactory pattern as staleness_test.go: the factory runs
// before the scenario reads URL/Headers, so it builds the fixture and
// mutates the captured scenario. The fixture is also captured by the outer
// variable so assertions can run against the same app after Test returns.
//
// Every relation pointing at group_members (expenses.payer,
// split_entries.member, settlements.from/to_member, balances.member) is
// required and non-cascading, so a user who appears anywhere in the ledger
// cannot be erased without rewriting other members' balances. Hence two
// outcomes: erase when there is no history, anonymize when there is.
// ---------------------------------------------------------------------

func TestDeleteAccountErasesUserWithNoHistory(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "user with no ledger history is erased outright",
		Method: http.MethodPost,
		URL:    "/api/splitcore/delete-account",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"deleted"`}
	// AfterTestFunc, not code after Test: Test runs a subtest whose cleanup
	// closes the app, so assertions afterwards hit a torn-down database.
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		if _, err := app.FindRecordById("users", f.Bob.Id); err == nil {
			t.Fatal("user record survived a delete with no ledger history")
		}
		rows, err := app.FindRecordsByFilter("group_members", "user = {:u}", "", 0, 0,
			dbx.Params{"u": f.Bob.Id})
		if err != nil {
			t.Fatalf("find memberships: %v", err)
		}
		if len(rows) != 0 {
			t.Fatalf("memberships remaining after erase = %d, want 0", len(rows))
		}
	}
	scenario.Test(t)
}

func TestDeleteAccountAnonymizesUserWithHistory(t *testing.T) {
	var f *testfix.Fixture
	var balancesBefore map[string]int64

	scenario := tests.ApiScenario{
		Name:   "user with settled ledger history is anonymized, not erased",
		Method: http.MethodPost,
		URL:    "/api/splitcore/delete-account",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)

		expense := f.CreateExpense(t, f.AliceM, 1000, "equal")
		f.CreateSplit(t, expense, f.AliceM, 500)
		f.CreateSplit(t, expense, f.BobM, 500)
		f.CreateSettlement(t, f.BobM, f.AliceM, 500)
		balancesBefore = f.Balances(t)

		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"anonymized"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		bob, err := app.FindRecordById("users", f.Bob.Id)
		if err != nil {
			t.Fatalf("user row must survive so the ledger stays intact: %v", err)
		}
		if got := bob.GetString("email"); !strings.HasPrefix(got, "deleted-") {
			t.Fatalf("email = %q, want a deleted- tombstone", got)
		}
		if got := bob.GetString("name"); got != "" {
			t.Fatalf("name = %q, want empty", got)
		}
		if bob.GetBool("verified") {
			t.Fatal("anonymized account is still verified")
		}

		rows, err := app.FindRecordsByFilter("group_members", "user = {:u}", "", 0, 0,
			dbx.Params{"u": f.Bob.Id})
		if err != nil {
			t.Fatalf("find memberships: %v", err)
		}
		if len(rows) != 1 {
			t.Fatalf("memberships after anonymize = %d, want 1", len(rows))
		}

		for member, before := range balancesBefore {
			if got := f.Balances(t)[member]; got != before {
				t.Fatalf("balance for %s changed from %d to %d — anonymizing rewrote the ledger",
					member, before, got)
			}
		}
	}
	scenario.Test(t)
}

func TestDeleteAccountBlockedByOutstandingBalance(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "outstanding balance blocks both paths",
		Method: http.MethodPost,
		URL:    "/api/splitcore/delete-account",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)

		expense := f.CreateExpense(t, f.AliceM, 1000, "equal")
		f.CreateSplit(t, expense, f.AliceM, 500)
		f.CreateSplit(t, expense, f.BobM, 500)

		if balances := f.Balances(t); balances[f.BobM.Id] != -500 {
			t.Fatalf("precondition: bob's balance = %d, want -500", balances[f.BobM.Id])
		}

		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		bob, err := app.FindRecordById("users", f.Bob.Id)
		if err != nil {
			t.Fatalf("user row must be untouched after a refused delete: %v", err)
		}
		if bob.GetString("email") != "bob@example.com" {
			t.Fatalf("a refused delete anonymized the account anyway: %q", bob.GetString("email"))
		}
	}
	scenario.Test(t)
}

func TestDeleteAccountRequiresAuth(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unauthenticated delete-account is rejected",
		Method: http.MethodPost,
		URL:    "/api/splitcore/delete-account",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		return testfix.New(t).App
	}
	scenario.ExpectedStatus = 401
	scenario.ExpectedContent = []string{`"status":401`}
	scenario.Test(t)
}

// Owning a group is enough on its own: groups.owner is a required,
// non-cascading reference to users, so the row cannot be erased while a
// group points at it — and deleting the group instead would destroy every
// other member's history.
func TestDeleteAccountAnonymizesGroupOwnerWithNoExpenses(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "group owner with no expenses is anonymized, not erased",
		Method: http.MethodPost,
		URL:    "/api/splitcore/delete-account",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		// Alice owns the fixture group and has no expenses at all.
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"anonymized"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatalf("the owned group must survive: %v", err)
		}
		if group.GetString("owner") != f.Alice.Id {
			t.Fatal("ownership was reassigned by an account deletion")
		}
		if _, err := app.FindRecordById("users", f.Alice.Id); err != nil {
			t.Fatalf("owner row must survive so the group stays valid: %v", err)
		}
	}
	scenario.Test(t)
}
