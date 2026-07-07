package hooks

import (
	"net/http"
	"strconv"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// registerStaleness binds GET /api/splitcore/staleness, an O(1) check
// clients use to decide whether their cached group state is current
// without re-fetching the full balances/expenses payload.
func registerStaleness(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/splitcore/staleness", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}

			groupID := e.Request.URL.Query().Get("group")
			versionStr := e.Request.URL.Query().Get("version")
			clientV, err := strconv.Atoi(versionStr)
			if groupID == "" || err != nil {
				return e.BadRequestError("group and integer version are required", nil)
			}

			// Membership gate — 404 for both non-member and unknown group so
			// the response never leaks whether the group exists.
			_, err = e.App.FindFirstRecordByFilter("group_members",
				"group = {:g} && user = {:u}",
				dbx.Params{"g": groupID, "u": e.Auth.Id})
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			group, err := e.App.FindRecordById("groups", groupID)
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			serverV := group.GetInt("version")
			return e.JSON(http.StatusOK, map[string]any{
				"current":       clientV == serverV,
				"serverVersion": serverV,
			})
		})
		return se.Next()
	})
}
