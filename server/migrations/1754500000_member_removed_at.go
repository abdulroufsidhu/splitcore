package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
)

func init() {
	m.Register(InitMemberRemovedAt, DropMemberRemovedAt)
}

// InitMemberRemovedAt adds `group_members.removed_at`: when a member is
// removed from a group but cannot be deleted, this is when it happened.
// Empty means an active member.
//
// Removal cannot always delete the row. Every relation pointing at
// group_members — expenses.payer, split_entries.member,
// settlements.from_member/to_member, balances.member — is Required with
// CascadeDelete=false, so a member who appears in even one expense is
// undeletable, and deleting the records that reference them would rewrite
// other people's balances. Marking the row instead keeps that history
// intact while taking the member out of the app (see
// server/hooks/remove_member.go).
//
// A newly added field is empty on every existing row, so all current
// memberships read as active without a backfill.
func InitMemberRemovedAt(app core.App) error {
	members, err := app.FindCollectionByNameOrId("group_members")
	if err != nil {
		return err
	}
	if members.Fields.GetByName("removed_at") != nil {
		return nil
	}
	members.Fields.Add(&core.DateField{Name: "removed_at"})
	return app.Save(members)
}

func DropMemberRemovedAt(app core.App) error {
	members, err := app.FindCollectionByNameOrId("group_members")
	if err != nil {
		return nil
	}
	field := members.Fields.GetByName("removed_at")
	if field == nil {
		return nil
	}
	members.Fields.RemoveById(field.GetId())
	return app.Save(members)
}
