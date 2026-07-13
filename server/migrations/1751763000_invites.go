package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(InitInvites, DropInvites)
}

// InitInvites adds the `invites` collection: a pending "add this email to
// this group" record, created by /api/splitcore/invite when the invited
// email doesn't have an account yet. The users-create hook (see
// hooks/invite.go) auto-joins matching invites the moment that email signs
// up, so there is no separate accept/decline step.
func InitInvites(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}
	groups, err := app.FindCollectionByNameOrId("groups")
	if err != nil {
		return err
	}

	invites, exists, err := getOrCreateCollection(app, "invites")
	if err != nil {
		return err
	}
	if !exists {
		invites.Fields.Add(
			&core.EmailField{Name: "email", Required: true},
			&core.RelationField{Name: "group", Required: true, CollectionId: groups.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "invited_by", Required: true, CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
			&core.SelectField{Name: "role", Required: true, Values: []string{"owner", "member"}, MaxSelect: 1},
			&core.SelectField{Name: "status", Required: true, Values: []string{"pending", "accepted"}, MaxSelect: 1},
		)
		// Reuses memberRule (defined in 1751760000_init_collections.go) —
		// it only needs a `group` field, which invites has, so group
		// members can see pending invites for their group.
		invites.ListRule = types.Pointer(memberRule)
		invites.ViewRule = types.Pointer(memberRule)
		// Writes only ever happen server-side, from /api/splitcore/invite
		// (create) and the users-create hook (accept) — both run as the
		// app itself, which bypasses these client-facing rules entirely.
		// Restricting them to the group owner just closes off any direct
		// client write attempt.
		invites.CreateRule = types.Pointer(`group.owner = @request.auth.id`)
		invites.UpdateRule = types.Pointer(`group.owner = @request.auth.id`)
		invites.DeleteRule = types.Pointer(`group.owner = @request.auth.id`)
		if err := app.Save(invites); err != nil {
			return err
		}
	}

	return nil
}

func DropInvites(app core.App) error {
	col, err := app.FindCollectionByNameOrId("invites")
	if err != nil {
		return nil
	}
	return app.Delete(col)
}
