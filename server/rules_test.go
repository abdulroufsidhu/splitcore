package main_test

// Permission-rule matrix (characterization tests of the collection rules
// defined in migrations/1751760000_init_collections.go). These exercise
// the real PocketBase API router (via tests.ApiScenario) so the assertions
// reflect actual observed status codes, not guesses. See task-6-brief.md
// for the 12-row matrix these implement and .superpowers/sdd/task-6-report.md
// for any deviations between the brief's guessed status codes and PB's
// actual (conventional) behavior.

import (
	"fmt"
	"net/http"
	"strings"
	"testing"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/abdulroufsidhu/slice_pay/server/internal/testfix"
)

// newOutsider creates and saves a third user (carol) who is authenticated
// but not a member of f.Group, for the "outsider" rows of the matrix.
func newOutsider(t testing.TB, f *testfix.Fixture) *core.Record {
	t.Helper()

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

	return carol
}

// authHeader builds the Authorization header map for an authenticated
// request from the given user record.
func authHeader(t testing.TB, user *core.Record) map[string]string {
	t.Helper()

	token, err := user.NewAuthToken()
	if err != nil {
		t.Fatal(err)
	}

	return map[string]string{"Authorization": token}
}

// ---------------------------------------------------------------------
// #1 unauthenticated list groups: assert no leak (0 items, not an error
// that would itself disclose a group's existence).
// ---------------------------------------------------------------------

func TestRulesUnauthListGroupsNoLeak(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unauthenticated list groups leaks nothing",
		Method: http.MethodGet,
		URL:    "/api/collections/groups/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"totalItems":0`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #2 outsider list groups: 200, totalItems 0.
// ---------------------------------------------------------------------

func TestRulesOutsiderListGroupsEmpty(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "outsider list groups sees zero items",
		Method: http.MethodGet,
		URL:    "/api/collections/groups/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		carol := newOutsider(t, f)
		scenario.Headers = authHeader(t, carol)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"totalItems":0`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #3 member list groups: 200, contains the group id.
// ---------------------------------------------------------------------

func TestRulesMemberListGroupsSeesGroup(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member list groups sees their group",
		Method: http.MethodGet,
		URL:    "/api/collections/groups/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		scenario.Headers = authHeader(t, f.Bob)
		scenario.ExpectedContent = []string{`"totalItems":1`, `"id":"` + f.Group.Id + `"`}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #4 outsider view group by id: 404 (PB hides existence via the rule
// filter on FindRecordById; see apis.recordView).
// ---------------------------------------------------------------------

func TestRulesOutsiderViewGroupNotFound(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "outsider view group by id is not found",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		carol := newOutsider(t, f)
		scenario.URL = "/api/collections/groups/records/" + f.Group.Id
		scenario.Headers = authHeader(t, carol)
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #5 outsider list expenses: 200, totalItems 0.
// ---------------------------------------------------------------------

func TestRulesOutsiderListExpensesEmpty(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "outsider list expenses sees zero items",
		Method: http.MethodGet,
		URL:    "/api/collections/expenses/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		f.CreateExpense(t, f.AliceM, 1000, "equal")

		carol := newOutsider(t, f)
		scenario.Headers = authHeader(t, carol)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"totalItems":0`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #6 outsider create expense in group: rejected. CreateRule is non-nil
// (memberRule), so a rule failure surfaces as 400 "Failed to create
// record" (apis.recordCreate), matching the brief's guess.
// ---------------------------------------------------------------------

func TestRulesOutsiderCreateExpenseRejected(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "outsider create expense is rejected",
		Method: http.MethodPost,
		URL:    "/api/collections/expenses/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		carol := newOutsider(t, f)

		body := fmt.Sprintf(`{"group":%q,"payer":%q,"amount_cents":1000,"split_type":"equal"}`, f.Group.Id, f.AliceM.Id)
		scenario.Body = strings.NewReader(body)
		scenario.Headers = authHeader(t, carol)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #7 member create expense (valid): 200.
// ---------------------------------------------------------------------

func TestRulesMemberCreateExpenseOK(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member create expense succeeds",
		Method: http.MethodPost,
		URL:    "/api/collections/expenses/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		body := fmt.Sprintf(`{"group":%q,"payer":%q,"amount_cents":1000,"split_type":"equal"}`, f.Group.Id, f.BobM.Id)
		scenario.Body = strings.NewReader(body)
		scenario.Headers = authHeader(t, f.Bob)
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"amount_cents":1000`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #8 outsider create settlement: rejected, 400 (same CreateRule shape
// as expenses).
// ---------------------------------------------------------------------

func TestRulesOutsiderCreateSettlementRejected(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "outsider create settlement is rejected",
		Method: http.MethodPost,
		URL:    "/api/collections/settlements/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		carol := newOutsider(t, f)

		body := fmt.Sprintf(`{"group":%q,"from_member":%q,"to_member":%q,"amount_cents":500}`, f.Group.Id, f.AliceM.Id, f.BobM.Id)
		scenario.Body = strings.NewReader(body)
		scenario.Headers = authHeader(t, carol)
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #9 member PATCH balances row: rejected. balances.UpdateRule is nil (by
// design — server/hook-only writes), so PB rejects before even fetching
// the record with 403 "Only superusers can perform this action"
// (apis.recordUpdate). The brief allowed either 404 or 403; 403 is the
// actual, PB-conventional code for a nil rule and is asserted here.
// ---------------------------------------------------------------------

func TestRulesMemberPatchBalanceRowRejected(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member cannot patch a balances row (no update rule)",
		Method: http.MethodPatch,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
		f.CreateSplit(t, expense, f.AliceM, 1000)
		f.CreateSplit(t, expense, f.BobM, 2000)

		row, err := f.App.FindFirstRecordByFilter("balances",
			"group = {:g} && member = {:m}",
			dbx.Params{"g": f.Group.Id, "m": f.BobM.Id})
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/collections/balances/records/" + row.Id
		scenario.Body = strings.NewReader(`{"net_cents":999999}`)
		scenario.Headers = authHeader(t, f.Bob)
		return f.App
	}
	scenario.ExpectedStatus = 403
	scenario.ExpectedContent = []string{`"status":403`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #10 member POST balances: rejected, 403 for the same nil-CreateRule
// reason as #9 (brief guessed 400; actual PB behavior for a nil rule is
// 403, asserted here — not a rule bug, balances intentionally has no
// create rule).
// ---------------------------------------------------------------------

func TestRulesMemberPostBalancesRejected(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member cannot create a balances row (no create rule)",
		Method: http.MethodPost,
		URL:    "/api/collections/balances/records",
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		body := fmt.Sprintf(`{"group":%q,"member":%q,"net_cents":100}`, f.Group.Id, f.BobM.Id)
		scenario.Body = strings.NewReader(body)
		scenario.Headers = authHeader(t, f.Bob)
		return f.App
	}
	scenario.ExpectedStatus = 403
	scenario.ExpectedContent = []string{`"status":403`}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #11 member (owner) PATCH group version=999: 200, but the stored
// version is unchanged because hooks.Register's OnRecordUpdateRequest
// hook resets version/owner from the persisted record before the update
// is submitted.
// ---------------------------------------------------------------------

func TestRulesOwnerPatchGroupVersionResetByHook(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "PATCH group version is reset by the hook, not client-writable",
		Method: http.MethodPatch,
	}

	var groupID string
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		groupID = f.Group.Id

		scenario.URL = "/api/collections/groups/records/" + f.Group.Id
		scenario.Body = strings.NewReader(`{"version":999}`)
		scenario.Headers = authHeader(t, f.Alice)
		scenario.ExpectedContent = []string{`"id":"` + f.Group.Id + `"`}
		scenario.NotExpectedContent = []string{`"version":999`}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.AfterTestFunc = func(t testing.TB, app *tests.TestApp, res *http.Response) {
		group, err := app.FindRecordById("groups", groupID)
		if err != nil {
			t.Fatal(err)
		}
		if group.GetInt("version") == 999 {
			t.Fatalf("stored group version = 999 after PATCH version=999, want unchanged (hook must reset it)")
		}
	}
	scenario.Test(t)
}

// ---------------------------------------------------------------------
// #12 non-owner member PATCH group name: rejected. groups.UpdateRule is
// "owner = @request.auth.id"; a non-owner fails the rule filter applied
// inside FindRecordById, which surfaces as 404 (apis.recordUpdate), not
// 403 — the brief allowed either.
// ---------------------------------------------------------------------

func TestRulesNonOwnerPatchGroupNameRejected(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "non-owner member cannot patch group name",
		Method: http.MethodPatch,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		scenario.URL = "/api/collections/groups/records/" + f.Group.Id
		scenario.Body = strings.NewReader(`{"name":"Renamed By Bob"}`)
		scenario.Headers = authHeader(t, f.Bob)
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.Test(t)
}
