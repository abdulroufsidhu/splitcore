package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(InitExpenseAutodate, DropExpenseAutodate)
}

// InitExpenseAutodate adds `expenses.updated`, the timestamp the offline
// client's conflict detection is measured against.
//
// PocketBase stopped creating `created`/`updated` implicitly: a collection
// only has them if it declares autodate fields, and the initial migration
// declared none. Without this the server returns no `updated` at all, so a
// queued offline edit has no base to compare against and every replay
// overwrites whatever a co-member changed in the meantime — silently, in a
// shared ledger.
//
// Only `expenses` needs it. Creates carry a client-minted id, so a replay
// that already landed is caught by uniqueness rather than by a timestamp,
// and a delete of an already-deleted record 404s. Updates are the only ops
// that can conflict, and expenses are the only records this app updates.
func InitExpenseAutodate(app core.App) error {
	expenses, err := app.FindCollectionByNameOrId("expenses")
	if err != nil {
		return err
	}
	if expenses.Fields.GetByName("updated") != nil {
		return nil
	}
	expenses.Fields.Add(&core.AutodateField{Name: "updated", OnCreate: true, OnUpdate: true})
	return app.Save(expenses)
}

func DropExpenseAutodate(app core.App) error {
	expenses, err := app.FindCollectionByNameOrId("expenses")
	if err != nil {
		return nil
	}
	field := expenses.Fields.GetByName("updated")
	if field == nil {
		return nil
	}
	expenses.Fields.RemoveById(field.GetId())
	return app.Save(expenses)
}
