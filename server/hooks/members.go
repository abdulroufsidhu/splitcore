package hooks

import (
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// registerMembers binds GET /api/splitcore/members?group_id=X. PocketBase's
// default `users` view/list rule is self-only (id = @request.auth.id), so a
// group member can never look up another member's name/avatar directly —
// this app-privileged route is the one place that's allowed to cross that
// boundary, and only after confirming the caller shares the group.
func registerMembers(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.GET("/api/splitcore/members", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}

			groupID := e.Request.URL.Query().Get("group_id")
			if groupID == "" {
				return e.BadRequestError("group_id is required", nil)
			}

			// Caller must themselves be a member of the group.
			_, err := e.App.FindFirstRecordByFilter("group_members",
				"group = {:g} && user = {:u}", dbx.Params{"g": groupID, "u": e.Auth.Id})
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			members, err := e.App.FindRecordsByFilter("group_members",
				"group = {:g}", "", 0, 0, dbx.Params{"g": groupID})
			if err != nil {
				return err
			}

			out := make([]map[string]any, 0, len(members))
			for _, m := range members {
				userID := m.GetString("user")
				user, err := e.App.FindRecordById("users", userID)
				name, avatar := "", ""
				if err == nil {
					name = user.GetString("name")
					avatar = user.GetString("avatar")
				}
				out = append(out, map[string]any{
					"id":   m.Id,
					"user": userID,
					"role": m.GetString("role"),
					"name": name,
					// Empty for an active member. Removed members are still
					// returned: they own past expenses, so a client rendering
					// history has to be able to name them (see
					// server/hooks/remove_member.go).
					"removed_at": m.GetString("removed_at"),
					"avatar":     avatar,
				})
			}
			return e.JSON(http.StatusOK, out)
		})
		return se.Next()
	})
}
