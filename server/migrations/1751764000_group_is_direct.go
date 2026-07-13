package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(InitGroupIsDirect, DropGroupIsDirect)
}

// InitGroupIsDirect adds `groups.is_direct`: marks a group created via the
// app's "Add person" one-to-one flow, so the UI can show it as a person
// (name + avatar) instead of a group. Purely a display flag — same schema,
// access rules, and expense/settlement machinery as any other group.
func InitGroupIsDirect(app core.App) error {
	groups, err := app.FindCollectionByNameOrId("groups")
	if err != nil {
		return err
	}
	if groups.Fields.GetByName("is_direct") != nil {
		return nil
	}
	groups.Fields.Add(&core.BoolField{Name: "is_direct"})
	return app.Save(groups)
}

func DropGroupIsDirect(app core.App) error {
	groups, err := app.FindCollectionByNameOrId("groups")
	if err != nil {
		return nil
	}
	field := groups.Fields.GetByName("is_direct")
	if field == nil {
		return nil
	}
	groups.Fields.RemoveById(field.GetId())
	return app.Save(groups)
}
