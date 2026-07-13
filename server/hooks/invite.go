package hooks

import (
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// registerInvite binds POST /api/splitcore/invite, the "add a person to my
// group by email" endpoint. If the email already has an account, they're
// added to the group immediately; otherwise a pending `invites` row is
// created and the auto-join hook below fulfills it the moment that email
// signs up. There is no accept/decline step — Splitwise-simple, not a full
// friends network.
func registerInvite(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/splitcore/invite", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}

			var body struct {
				GroupID string `json:"group_id"`
				Email   string `json:"email"`
				Role    string `json:"role"`
			}
			if err := e.BindBody(&body); err != nil || body.GroupID == "" || body.Email == "" {
				return e.BadRequestError("group_id and email are required", nil)
			}
			if body.Role == "" {
				body.Role = "member"
			}

			// Only the group owner can invite — same trust boundary as
			// group_members' own CreateRule.
			group, err := e.App.FindFirstRecordByFilter("groups",
				"id = {:g} && owner = {:u}", dbx.Params{"g": body.GroupID, "u": e.Auth.Id})
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			existingUser, err := e.App.FindAuthRecordByEmail("users", body.Email)
			if err == nil {
				return addOrNoOpMember(e, group, existingUser, body.Role)
			}
			return createPendingInvite(e, group, body.Email, body.Role)
		})
		return se.Next()
	})
}

func addOrNoOpMember(e *core.RequestEvent, group *core.Record, user *core.Record, role string) error {
	already, err := e.App.FindFirstRecordByFilter("group_members",
		"group = {:g} && user = {:u}", dbx.Params{"g": group.Id, "u": user.Id})
	if err == nil && already != nil {
		return e.JSON(http.StatusOK, map[string]any{"status": "added"})
	}

	col, err := e.App.FindCollectionByNameOrId("group_members")
	if err != nil {
		return err
	}
	member := core.NewRecord(col)
	member.Set("group", group.Id)
	member.Set("user", user.Id)
	member.Set("role", role)
	if err := e.App.Save(member); err != nil {
		return err
	}
	return e.JSON(http.StatusOK, map[string]any{"status": "added"})
}

func createPendingInvite(e *core.RequestEvent, group *core.Record, email string, role string) error {
	col, err := e.App.FindCollectionByNameOrId("invites")
	if err != nil {
		return err
	}
	invite := core.NewRecord(col)
	invite.Set("email", email)
	invite.Set("group", group.Id)
	invite.Set("invited_by", e.Auth.Id)
	invite.Set("role", role)
	invite.Set("status", "pending")
	if err := e.App.Save(invite); err != nil {
		return err
	}
	return e.JSON(http.StatusOK, map[string]any{"status": "invited"})
}

// registerInviteAcceptance auto-joins a brand-new user to every group that
// has a pending invite for their email — the moment sign-up completes, not
// on next login, so listMembers reflects it right away.
func registerInviteAcceptance(app core.App) {
	app.OnRecordAfterCreateSuccess("users").BindFunc(func(e *core.RecordEvent) error {
		email := e.Record.GetString("email")
		invites, err := e.App.FindRecordsByFilter("invites",
			"email = {:e} && status = 'pending'", "", 0, 0, dbx.Params{"e": email})
		if err != nil {
			return e.Next()
		}

		membersCol, err := e.App.FindCollectionByNameOrId("group_members")
		if err != nil {
			return e.Next()
		}

		for _, invite := range invites {
			member := core.NewRecord(membersCol)
			member.Set("group", invite.GetString("group"))
			member.Set("user", e.Record.Id)
			member.Set("role", invite.GetString("role"))
			if err := e.App.Save(member); err != nil {
				continue
			}
			invite.Set("status", "accepted")
			_ = e.App.Save(invite)
		}

		return e.Next()
	})
}
