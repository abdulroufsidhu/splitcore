package hooks_test

import (
	"net/http"
	"testing"

	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tests"

	"github.com/abdulroufsidhu/splitcore/server/internal/testfix"
)

// ---------------------------------------------------------------------
// GET /api/splitcore/staleness
//
// TestAppFactory runs before ApiScenario reads scenario.URL/Headers (see
// tests.ApiScenario.test in the pocketbase source), so each scenario below
// builds its fixture inside TestAppFactory and mutates the outer scenario
// struct (captured by the closure) with the group id / token it just
// created.
// ---------------------------------------------------------------------

func TestStalenessUnauthenticated(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unauthenticated request is rejected",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)
		scenario.URL = "/api/splitcore/staleness?group=" + f.Group.Id + "&version=0"
		return f.App
	}
	scenario.ExpectedStatus = 401
	scenario.ExpectedContent = []string{`"status":401`}
	scenario.Test(t)
}

func TestStalenessMemberCurrent(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member with matching version sees current true",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/splitcore/staleness?group=" + f.Group.Id + "&version=0"
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.ExpectedContent = []string{`"current":true`, `"serverVersion":0`}
	scenario.Test(t)
}

func TestStalenessMemberStale(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "member with stale version sees current false and the server version",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		// Bump the group's version counter forward so the client's
		// (stale) version=0 no longer matches.
		expense := f.CreateExpense(t, f.AliceM, 3000, "exact")
		f.CreateSplit(t, expense, f.AliceM, 1000)
		f.CreateSplit(t, expense, f.BobM, 2000)

		serverVersion := f.Version(t)
		if serverVersion == 0 {
			t.Fatalf("expected version to have advanced past 0, got %d", serverVersion)
		}

		token, err := f.Bob.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/splitcore/staleness?group=" + f.Group.Id + "&version=0"
		scenario.Headers = map[string]string{"Authorization": token}
		scenario.ExpectedContent = []string{`"current":false`, `"serverVersion":3`}
		return f.App
	}
	scenario.ExpectedStatus = 200
	scenario.Test(t)
}

func TestStalenessNonMember(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "authenticated non-member is treated as not found",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

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

		token, err := carol.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/splitcore/staleness?group=" + f.Group.Id + "&version=0"
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.Test(t)
}

func TestStalenessUnknownGroup(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "unknown group id is treated as not found",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/splitcore/staleness?group=doesnotexist000&version=0"
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 404
	scenario.ExpectedContent = []string{`"status":404`}
	scenario.Test(t)
}

func TestStalenessMissingVersion(t *testing.T) {
	scenario := tests.ApiScenario{
		Name:   "missing version param is a bad request",
		Method: http.MethodGet,
	}
	scenario.TestAppFactory = func(t testing.TB) *tests.TestApp {
		f := testfix.New(t)

		token, err := f.Alice.NewAuthToken()
		if err != nil {
			t.Fatal(err)
		}

		scenario.URL = "/api/splitcore/staleness?group=" + f.Group.Id
		scenario.Headers = map[string]string{"Authorization": token}
		return f.App
	}
	scenario.ExpectedStatus = 400
	scenario.ExpectedContent = []string{`"status":400`}
	scenario.Test(t)
}
