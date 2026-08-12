package hooks_test

import (
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/abdulroufsidhu/splitcore/server/internal/testfix"
)

// ---------------------------------------------------------------------
// POST /api/splitcore/transfer-ownership
//
// Handing a group over is the only way its owner ever leaves it —
// remove-member refuses the owner outright, because dropping their
// membership would revoke their own access to the group. So the route has
// to move groups.owner and both roles together, and it must not be
// reachable by anyone but the current owner.
// ---------------------------------------------------------------------

func TestTransferOwnershipMovesOwnerAndBothRoles(t *testing.T) {
	var f *testfix.Fixture
	var versionBefore int

	scenario := tests.ApiScenario{
		Name:   "the named member becomes owner and the caller becomes a member",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		versionBefore = f.Version(t)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"status":"transferred"`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatal(err)
		}
		if group.GetString("owner") != f.Bob.Id {
			t.Fatalf("groups.owner = %q, want Bob", group.GetString("owner"))
		}

		bobM, err := app.FindRecordById("group_members", f.BobM.Id)
		if err != nil {
			t.Fatal(err)
		}
		if bobM.GetString("role") != "owner" {
			t.Fatalf("new owner's role = %q, want owner", bobM.GetString("role"))
		}

		aliceM, err := app.FindRecordById("group_members", f.AliceM.Id)
		if err != nil {
			t.Fatal(err)
		}
		if aliceM.GetString("role") != "member" {
			t.Fatalf("old owner's role = %q, want member", aliceM.GetString("role"))
		}

		// Without a bump, no other device ever learns the group changed
		// hands, so the old owner keeps seeing the owner-only actions.
		if got := group.GetInt("version"); got <= versionBefore {
			t.Fatalf("version = %d, want > %d", got, versionBefore)
		}
	}
	scenario.Test(t)
}

func TestTransferOwnershipRejectsNonOwnerCaller(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a plain member cannot hand the group to themselves",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	// 404 rather than 403: the response never confirms a group the caller
	// cannot otherwise see.
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatal(err)
		}
		if group.GetString("owner") != f.Alice.Id {
			t.Fatal("a non-owner took the group")
		}
	}
	scenario.Test(t)
}

func TestTransferOwnershipRejectsMemberOfAnotherGroup(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "the member must belong to the group being handed over",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)

		// A second group, with a membership row that has nothing to do with
		// the first one.
		groupsCol, err := f.App.FindCollectionByNameOrId("groups")
		if err != nil {
			t.Fatal(err)
		}
		other := core.NewRecord(groupsCol)
		other.Set("name", "Other")
		other.Set("currency", "USD")
		other.Set("owner", f.Bob.Id)
		if err := f.App.Save(other); err != nil {
			t.Fatal(err)
		}
		membersCol, err := f.App.FindCollectionByNameOrId("group_members")
		if err != nil {
			t.Fatal(err)
		}
		outsider := core.NewRecord(membersCol)
		outsider.Set("group", other.Id)
		outsider.Set("user", f.Bob.Id)
		outsider.Set("role", "owner")
		if err := f.App.Save(outsider); err != nil {
			t.Fatal(err)
		}

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + outsider.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatal(err)
		}
		if group.GetString("owner") != f.Alice.Id {
			t.Fatal("the group changed hands to a member of another group")
		}
	}
	scenario.Test(t)
}

func TestTransferOwnershipRejectsRemovedMember(t *testing.T) {
	var f *testfix.Fixture

	scenario := tests.ApiScenario{
		Name:   "a removed member cannot be made owner",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		f.BobM.Set("removed_at", "2026-08-12 00:00:00.000Z")
		if err := f.App.Save(f.BobM); err != nil {
			t.Fatal(err)
		}

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatal(err)
		}
		if group.GetString("owner") != f.Alice.Id {
			t.Fatal("a removed member was made owner")
		}
	}
	scenario.Test(t)
}

func TestTransferOwnershipRejectsCurrentOwner(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "handing the group to whoever already owns it is refused",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.AliceM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}

func TestTransferOwnershipUnauthenticated(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unauthenticated request is rejected",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		scenario.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	scenario.ExpectedStatus = 401
	scenario.ExpectedContent = []string{`"status":401`}
	scenario.Test(t)
}

// The whole point of transferring: the old owner can then walk out, which
// remove-member refuses while they still own the group.
func TestTransferOwnershipLetsTheOldOwnerLeave(t *testing.T) {
	var f *testfix.Fixture

	transfer := tests.ApiScenario{
		Name:   "transfer, then leave",
		Method: http.MethodPost,
		URL:    "/api/splitcore/transfer-ownership",
	}
	transfer.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f = testfix.New(t)
		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}
		transfer.Headers = map[string]string{"Authorization": token}
		transfer.Body = strings.NewReader(
			`{"group_id":"` + f.Group.Id + `","member_id":"` + f.BobM.Id + `"}`)
		return f.App
	}
	transfer.ExpectedStatus = 200
	transfer.ExpectedContent = []string{`"status":"transferred"`}
	transfer.AfterTestFunc = func(t testing.TB, app *tests.TestApp, _ *http.Response) {
		// Alice now owns nothing, so removing her own membership is allowed
		// where a moment ago it was a 400.
		aliceM, err := app.FindRecordById("group_members", f.AliceM.Id)
		if err != nil {
			t.Fatal(err)
		}
		group, err := app.FindRecordById("groups", f.Group.Id)
		if err != nil {
			t.Fatal(err)
		}
		if aliceM.GetString("user") == group.GetString("owner") {
			t.Fatal("the old owner still owns the group, so they still cannot leave")
		}
	}
	transfer.Test(t)
}
