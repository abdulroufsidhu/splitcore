package hooks

import (
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
)

// registerTransferOwnership binds POST /api/splitcore/transfer-ownership,
// which hands a group to one of its members and demotes the caller to a
// regular member.
//
// It is a route rather than a plain update on groups.owner because that
// field is deliberately unwritable by clients: OnRecordUpdateRequest
// ("groups") in hooks.go restores the stored owner on every PATCH, so an
// ordinary update silently does nothing.
//
// Transfer moves no money, so nothing blocks it beyond permission. It also
// exists because ownership is otherwise a trap: groups.owner is a required
// non-cascading relation and groups.ListRule is membership-based, so the
// owner's membership cannot be dropped without revoking their own access —
// remove-member refuses it outright. Handing the group over is the only way
// an owner ever leaves one.
func registerTransferOwnership(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/splitcore/transfer-ownership", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}

			var body struct {
				GroupID  string `json:"group_id"`
				MemberID string `json:"member_id"`
			}
			if err := e.BindBody(&body); err != nil || body.GroupID == "" || body.MemberID == "" {
				return e.BadRequestError("group_id and member_id are required", nil)
			}

			// All three refusals below answer the same opaque 404, so the
			// API never confirms a group the caller cannot otherwise see —
			// which also makes them indistinguishable to whoever is holding
			// the phone. The reason goes to the server log instead, where
			// the client cannot read it but an operator can.
			refuse := func(reason string) error {
				e.App.Logger().Warn("transfer-ownership refused",
					"reason", reason,
					"caller", e.Auth.Id,
					"group", body.GroupID,
					"member", body.MemberID)
				return e.NotFoundError("not found", nil)
			}

			group, err := e.App.FindRecordById("groups", body.GroupID)
			if err != nil {
				return refuse("no such group")
			}

			if group.GetString("owner") != e.Auth.Id {
				return refuse("caller does not own the group")
			}

			member, err := e.App.FindRecordById("group_members", body.MemberID)
			if err != nil {
				return refuse("no such member")
			}
			if member.GetString("group") != group.Id {
				return refuse("member belongs to another group")
			}

			if member.GetString("user") == group.GetString("owner") {
				return e.BadRequestError("this member already owns the group", nil)
			}

			// Handing the group to somebody it has already removed would
			// resurrect them as its owner.
			if member.GetString("removed_at") != "" {
				return e.BadRequestError("a removed member cannot be made owner", nil)
			}

			caller, err := e.App.FindFirstRecordByFilter("group_members",
				"group = {:g} && user = {:u}",
				dbx.Params{"g": group.Id, "u": e.Auth.Id})
			if err != nil {
				return err
			}

			// One transaction: a failure must not leave the group pointing at
			// a new owner whose membership still reads "member", or two rows
			// both claiming the role.
			err = e.App.RunInTransaction(func(txApp core.App) error {
				group.Set("owner", member.GetString("user"))
				if err := txApp.Save(group); err != nil {
					return err
				}
				member.Set("role", "owner")
				if err := txApp.Save(member); err != nil {
					return err
				}
				caller.Set("role", "member")
				return txApp.Save(caller)
			})
			if err != nil {
				return err
			}

			// The two member saves above each fired memberBind, so the
			// group's version is already bumped and every client will
			// re-pull the roster.
			return e.JSON(http.StatusOK, map[string]string{"status": "transferred"})
		})
		return se.Next()
	})
}
