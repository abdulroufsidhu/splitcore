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
// POST /api/splitcore/remove-member
//
// Same TestAppFactory pattern as account_test.go. The fixture is captured
// by the outer variable so AfterTestFunc can assert against the same app.
//
// Removal cannot always delete the row — see server/hooks/remove_member.go
// — so the outcome is "removed" for a member with no history and
// "deactivated" for one with history. Both refuse while money is owed.
// ---------------------------------------------------------------------

// settledHistory gives Bob ledger history whose balances net to zero: Alice
// pays 1000 split evenly, then Bob settles his 500 back. Removing Bob has to
// keep the row, but must not be blocked on the balance.
func settledHistory(t testing.TB, f *testfix.Fixture) {
	t.Helper()
	expense := f.CreateExpense(t, f.AliceM, 1000, "equal")
	f.CreateSplit(t, expense, f.AliceM, 500)
	f.CreateSplit(t, expense, f.BobM, 500)
	f.CreateSettlement(t, f.BobM, f.AliceM, 500)
}

func TestRemoveMemberDeletesMemberWithNoHistory(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a member who appears nowhere in the ledger is deleted outright",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"removed"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		if _, err := app.FindRecordById("group_members", f.BobM.Id); err == nil {
			t.Fatal("membership survived a removal with no ledger history")
		}
	}
	scenario.Test(t)
}

func TestRemoveMemberDeactivatesMemberWithHistory(t *testing.T) {
	var f *testfix.Fixture
	var balancesBefore map[string]int64

	scenario := tests.ApiScenario{
		Name:   "a member with settled history is deactivated, not deleted",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		settledHistory(t, f)
		balancesBefore = f.Balances(t)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"deactivated"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		member, err := app.FindRecordById("group_members", f.BobM.Id)
		if err != nil {
			t.Fatalf("membership was deleted despite carrying history: %v", err)
		}
		if member.GetString("removed_at") == "" {
			t.Fatal("removed_at is empty, so the member still reads as active")
		}
		// The whole point of keeping the row: nobody else's numbers move.
		after := f.Balances(t)
		for id, before := range balancesBefore {
			if after[id] != before {
				t.Fatalf("balance for %s changed on removal: %d -> %d", id, before, after[id])
			}
		}
	}
	scenario.Test(t)
}

func TestRemoveMemberRefusesWhileMoneyIsOwed(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a member with an outstanding balance cannot be removed",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		// No settlement: Bob still owes Alice 500.
		expense := f.CreateExpense(t, f.AliceM, 1000, "equal")
		f.CreateSplit(t, expense, f.AliceM, 500)
		f.CreateSplit(t, expense, f.BobM, 500)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		member, err := app.FindRecordById("group_members", f.BobM.Id)
		if err != nil {
			t.Fatalf("membership was removed despite the outstanding balance: %v", err)
		}
		if member.GetString("removed_at") != "" {
			t.Fatal("member was deactivated despite the outstanding balance")
		}
	}
	scenario.Test(t)
}

func TestRemoveMemberRejectsTheOwner(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "the group owner cannot remove their own membership",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.AliceM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}

func TestRemoveMemberRejectsNonOwner(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a plain member cannot remove anyone",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		// Bob is a member, not the owner, and tries to remove Alice.
		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.AliceM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		if _, err := app.FindRecordById("group_members", f.AliceM.Id); err != nil {
			t.Fatal("a non-owner managed to remove a membership")
		}
	}
	scenario.Test(t)
}

func TestRemoveMemberUnauthenticated(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unauthenticated request is rejected",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 401
	scenario.ExpectedContent = []string{`"status":401`}
	scenario.Test(t)
}

// Deactivation is an update, not a delete, so it only reaches other members'
// devices if it moves the group's version too.
func TestRemoveMemberBumpsVersionOnBothPaths(t *testing.T) {
	t.Run("deactivate", func(t *testing.T) {
		f := testfix.New(t)
		settledHistory(t, f)
		before := f.Version(t)

		f.BobM.Set("removed_at", "2026-08-11 00:00:00.000Z")
		if err := f.App.Save(f.BobM); err != nil {
			t.Fatal(err)
		}
		if got := f.Version(t) - before; got != 1 {
			t.Fatalf("version delta after deactivating a member = %d, want 1", got)
		}
	})

	t.Run("delete", func(t *testing.T) {
		f := testfix.New(t)
		before := f.Version(t)

		if err := f.App.Delete(f.BobM); err != nil {
			t.Fatal(err)
		}
		if got := f.Version(t) - before; got != 1 {
			t.Fatalf("version delta after deleting a member = %d, want 1", got)
		}
	})
}

// Removal has to be undoable, or a misclick strands a member's history in a
// group they can no longer reach.
func TestInviteReactivatesRemovedMember(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "re-inviting a removed member clears removed_at",
		Method: http.MethodPost,
		URL:    "/api/splitcore/invite",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		f.BobM.Set("removed_at", "2026-08-11 00:00:00.000Z")
		if err := f.App.Save(f.BobM); err != nil {
			t.Fatal(err)
		}

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","email":"bob@example.com"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"added"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		member, err := app.FindRecordById("group_members", f.BobM.Id)
		if err != nil {
			t.Fatalf("membership vanished: %v", err)
		}
		if member.GetString("removed_at") != "" {
			t.Fatal("removed_at survived the re-invite, so the member is still removed")
		}
		// Reactivated in place — a duplicate row would break every relation
		// that points at the original.
		rows, err := app.FindRecordsByFilter("group_members",
			"group = {:g} && user = {:u}", "", 0, 0,
			dbx.Params{"g": f.Group.Id, "u": f.Bob.Id})
		if err != nil {
			t.Fatal(err)
		}
		if len(rows) != 1 {
			t.Fatalf("memberships for Bob = %d, want 1", len(rows))
		}
	}
	scenario.Test(t)
}

// The members endpoint has to keep returning removed members: they own past
// expenses, and a client rendering history still needs to name them.
func TestMembersEndpointReportsRemovedAt(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "listMembers reports removed_at so the client can filter",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		f.BobM.Set("removed_at", "2026-08-11 00:00:00.000Z")
		if err := f.App.Save(f.BobM); err != nil {
			t.Fatal(err)
		}

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.URL = "/api/splitcore/members?group_id=" + f.Group.Id
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"removed_at":"2026-08-11 00:00:00.000Z"`}
	scenario.Test(t)
}

func TestLeaveGroupAsPlainMember(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a member can remove their own membership",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		// Bob, who owns nothing, naming his own membership.
		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"removed"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		if _, err := app.FindRecordById("group_members", f.BobM.Id); err == nil {
			t.Fatal("membership survived the member leaving")
		}
	}
	scenario.Test(t)
}

func TestLeaveGroupKeepsHistory(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "leaving with settled history keeps the row, like being removed",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		settledHistory(t, f)

		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"deactivated"`}
	scenario.Test(t)
}

func TestLeaveGroupRefusedWhileOwing(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a member cannot walk out while they still owe money",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		expense := f.CreateExpense(t, f.AliceM, 1000, "equal")
		f.CreateSplit(t, expense, f.AliceM, 500)
		f.CreateSplit(t, expense, f.BobM, 500)

		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		if _, err := app.FindRecordById("group_members", f.BobM.Id); err != nil {
			t.Fatal("member left despite owing money")
		}
	}
	scenario.Test(t)
}

func TestOwnerCannotLeaveTheirOwnGroup(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "the owner cannot leave their own group",
		Method: http.MethodPost,
		URL:    "/api/splitcore/remove-member",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(`{"member_id":"` + f.AliceM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}
