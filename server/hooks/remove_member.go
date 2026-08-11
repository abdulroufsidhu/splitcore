package hooks

import (
	"net/http"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/core"
	"github.com/pocketbase/pocketbase/tools/types"
)

// registerRemoveMember binds POST /api/splitcore/remove-member, the owner's
// "take this person out of the group" action.
//
// It is a route rather than group_members' own DeleteRule because "remove"
// cannot always mean "delete the row". Every relation pointing at
// group_members is Required with CascadeDelete=false (see
// migrations/1751760000_init_collections.go), so a member who appears in
// even one expense is undeletable — and deleting the expenses and split
// entries that reference them would rewrite everyone else's balances and
// destroy shared history that is not the owner's to erase.
//
// Hence two outcomes:
//
//   - "removed"     — no ledger history at all: the row is deleted outright,
//     so a mistaken invite leaves no trace.
//   - "deactivated" — has history: the row stays (keeping balances and past
//     expenses correct) with removed_at set, and the SDK
//     filters it out of every member list.
//
// Both refuse while the member's balance is non-zero: removing someone who
// still owes money silently shifts the debt onto the rest of the group.
func registerRemoveMember(app core.App) {
	app.OnServe().BindFunc(func(se *core.ServeEvent) error {
		se.Router.POST("/api/splitcore/remove-member", func(e *core.RequestEvent) error {
			if e.Auth == nil {
				return e.UnauthorizedError("auth required", nil)
			}

			var body struct {
				MemberID string `json:"member_id"`
			}
			if err := e.BindBody(&body); err != nil || body.MemberID == "" {
				return e.BadRequestError("member_id is required", nil)
			}

			member, err := e.App.FindRecordById("group_members", body.MemberID)
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			// Only the group's owner may remove anyone — the same trust
			// boundary as group_members' own DeleteRule. 404 rather than 403
			// so this never confirms a membership the caller cannot see.
			group, err := e.App.FindFirstRecordByFilter("groups",
				"id = {:g} && owner = {:u}",
				dbx.Params{"g": member.GetString("group"), "u": e.Auth.Id})
			if err != nil {
				return e.NotFoundError("not found", nil)
			}

			// The owner's own membership is not removable: groups.owner is a
			// required non-cascading relation, and dropping the membership
			// would revoke the owner's read access to their own group, since
			// groups.ListRule is membership-based.
			if member.GetString("user") == group.GetString("owner") {
				return e.BadRequestError("the group owner cannot be removed", nil)
			}

			net, err := memberNetCents(e.App, member)
			if err != nil {
				return err
			}
			if net != 0 {
				return e.BadRequestError("settle this member's balance before removing them", nil)
			}

			referenced, err := memberReferenced(e.App, member.Id)
			if err != nil {
				return err
			}

			if referenced {
				member.Set("removed_at", types.NowDateTime())
				if err := e.App.Save(member); err != nil {
					return err
				}
				return e.JSON(http.StatusOK, map[string]string{"status": "deactivated"})
			}

			// No history, so nothing references this row except possibly a
			// zero balances row. Clear that first: balances.member is
			// Required and non-cascading, so it would block the delete.
			err = e.App.RunInTransaction(func(txApp core.App) error {
				stale, err := txApp.FindRecordsByFilter("balances",
					"member = {:m}", "", 0, 0, dbx.Params{"m": member.Id})
				if err != nil {
					return err
				}
				for _, b := range stale {
					if err := txApp.Delete(b); err != nil {
						return err
					}
				}
				return txApp.Delete(member)
			})
			if err != nil {
				return err
			}
			return e.JSON(http.StatusOK, map[string]string{"status": "removed"})
		})
		return se.Next()
	})
}
