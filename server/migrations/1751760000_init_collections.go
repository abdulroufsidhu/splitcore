package migrations

import (
	"github.com/pocketbase/pocketbase/core"
	m "github.com/pocketbase/pocketbase/migrations"
	"github.com/pocketbase/pocketbase/tools/types"
)

func init() {
	m.Register(InitCollections, DropCollections)
}

const memberRule = `@request.auth.id != "" && @collection.group_members.group ?= group && @collection.group_members.user ?= @request.auth.id`
const memberRuleViaID = `@request.auth.id != "" && @collection.group_members.group ?= id && @collection.group_members.user ?= @request.auth.id`
const memberRuleViaExpense = `@request.auth.id != "" && @collection.group_members.group ?= expense.group && @collection.group_members.user ?= @request.auth.id`

// getOrCreateCollection returns the existing collection by name/id, or a
// freshly constructed (not yet saved) one if it doesn't exist. This keeps
// InitCollections idempotent: pocketbase's tests.NewTestApp() runs
// RunAllMigrations() during bootstrap, which already applies this
// registered migration, so a later explicit InitCollections(app) call
// (as tests do) must not fail just because the collections already exist.
func getOrCreateCollection(app core.App, name string) (col *core.Collection, existed bool, err error) {
	col, err = app.FindCollectionByNameOrId(name)
	if err == nil {
		return col, true, nil
	}
	return core.NewBaseCollection(name), false, nil
}

// InitCollections creates all splitcore collections. Exported so tests
// can build the schema on a bare test app without running the migration
// framework.
func InitCollections(app core.App) error {
	users, err := app.FindCollectionByNameOrId("users")
	if err != nil {
		return err
	}

	groups, exists, err := getOrCreateCollection(app, "groups")
	if err != nil {
		return err
	}
	if !exists {
		groups.Fields.Add(
			&core.TextField{Name: "name", Required: true, Max: 200},
			&core.TextField{Name: "currency", Required: true, Min: 3, Max: 3},
			&core.NumberField{Name: "version", OnlyInt: true},
			&core.RelationField{Name: "owner", Required: true, CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
		)
		// groups.ListRule/ViewRule reference @collection.group_members,
		// which does not exist yet at this point (PB's rule validator
		// resolves referenced collections against what is already
		// persisted). Save groups first with only the rules that don't
		// cross-reference group_members, then backfill list/view once
		// group_members exists below.
		groups.CreateRule = types.Pointer(`@request.auth.id != ""`)
		groups.UpdateRule = types.Pointer(`owner = @request.auth.id`)
		groups.DeleteRule = types.Pointer(`owner = @request.auth.id`)
		if err := app.Save(groups); err != nil {
			return err
		}
	}

	members, exists, err := getOrCreateCollection(app, "group_members")
	if err != nil {
		return err
	}
	if !exists {
		members.Fields.Add(
			&core.RelationField{Name: "group", Required: true, CollectionId: groups.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "user", Required: true, CollectionId: users.Id, MaxSelect: 1, CascadeDelete: false},
			&core.SelectField{Name: "role", Required: true, Values: []string{"owner", "member"}, MaxSelect: 1},
		)
		members.AddIndex("idx_group_members_unique", true, "`group`, `user`", "")
		members.CreateRule = types.Pointer(`group.owner = @request.auth.id`)
		members.UpdateRule = types.Pointer(`group.owner = @request.auth.id`)
		members.DeleteRule = types.Pointer(`group.owner = @request.auth.id`)
		if err := app.Save(members); err != nil {
			return err
		}
	}

	// Now that group_members is persisted, backfill the membership-based
	// rules on groups and group_members that reference it (only needed
	// the first time; on re-run these are already set).
	if groups.ListRule == nil {
		groups.ListRule = types.Pointer(memberRuleViaID)
		groups.ViewRule = types.Pointer(memberRuleViaID)
		if err := app.Save(groups); err != nil {
			return err
		}
	}
	if members.ListRule == nil {
		members.ListRule = types.Pointer(memberRule)
		members.ViewRule = types.Pointer(memberRule)
		if err := app.Save(members); err != nil {
			return err
		}
	}

	expenses, exists, err := getOrCreateCollection(app, "expenses")
	if err != nil {
		return err
	}
	if !exists {
		expenses.Fields.Add(
			&core.RelationField{Name: "group", Required: true, CollectionId: groups.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "payer", Required: true, CollectionId: members.Id, MaxSelect: 1, CascadeDelete: false},
			&core.TextField{Name: "description", Max: 500},
			&core.NumberField{Name: "amount_cents", OnlyInt: true},
			&core.SelectField{Name: "split_type", Required: true, Values: []string{"equal", "exact", "percent", "shares"}, MaxSelect: 1},
			&core.DateField{Name: "date"},
		)
		expenses.ListRule = types.Pointer(memberRule)
		expenses.ViewRule = types.Pointer(memberRule)
		expenses.CreateRule = types.Pointer(memberRule)
		expenses.UpdateRule = types.Pointer(memberRule)
		expenses.DeleteRule = types.Pointer(memberRule)
		if err := app.Save(expenses); err != nil {
			return err
		}
	}

	splitEntries, exists, err := getOrCreateCollection(app, "split_entries")
	if err != nil {
		return err
	}
	if !exists {
		splitEntries.Fields.Add(
			&core.RelationField{Name: "expense", Required: true, CollectionId: expenses.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "member", Required: true, CollectionId: members.Id, MaxSelect: 1, CascadeDelete: false},
			&core.NumberField{Name: "amount_cents", OnlyInt: true},
			&core.FileField{
				Name:      "receipt",
				MaxSelect: 1,
				MaxSize:   10 << 20,
				MimeTypes: []string{"image/jpeg", "image/png", "image/webp", "application/pdf"},
			},
		)
		splitEntries.ListRule = types.Pointer(memberRuleViaExpense)
		splitEntries.ViewRule = types.Pointer(memberRuleViaExpense)
		splitEntries.CreateRule = types.Pointer(memberRuleViaExpense)
		splitEntries.UpdateRule = types.Pointer(memberRuleViaExpense)
		splitEntries.DeleteRule = types.Pointer(memberRuleViaExpense)
		if err := app.Save(splitEntries); err != nil {
			return err
		}
	}

	settlements, exists, err := getOrCreateCollection(app, "settlements")
	if err != nil {
		return err
	}
	if !exists {
		settlements.Fields.Add(
			&core.RelationField{Name: "group", Required: true, CollectionId: groups.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "from_member", Required: true, CollectionId: members.Id, MaxSelect: 1, CascadeDelete: false},
			&core.RelationField{Name: "to_member", Required: true, CollectionId: members.Id, MaxSelect: 1, CascadeDelete: false},
			&core.NumberField{Name: "amount_cents", OnlyInt: true},
			&core.DateField{Name: "date"},
			&core.TextField{Name: "note", Max: 500},
		)
		settlements.ListRule = types.Pointer(memberRule)
		settlements.ViewRule = types.Pointer(memberRule)
		settlements.CreateRule = types.Pointer(memberRule)
		settlements.UpdateRule = types.Pointer(memberRule)
		settlements.DeleteRule = types.Pointer(memberRule)
		if err := app.Save(settlements); err != nil {
			return err
		}
	}

	balances, exists, err := getOrCreateCollection(app, "balances")
	if err != nil {
		return err
	}
	if !exists {
		balances.Fields.Add(
			&core.RelationField{Name: "group", Required: true, CollectionId: groups.Id, MaxSelect: 1, CascadeDelete: true},
			&core.RelationField{Name: "member", Required: true, CollectionId: members.Id, MaxSelect: 1, CascadeDelete: false},
			&core.NumberField{Name: "net_cents", OnlyInt: true},
		)
		balances.AddIndex("idx_balances_unique", true, "`group`, `member`", "")
		balances.ListRule = types.Pointer(memberRule)
		balances.ViewRule = types.Pointer(memberRule)
		// CreateRule/UpdateRule/DeleteRule stay nil: balances are never
		// client-writable, only superuser or server-side hooks (Task 4).
		if err := app.Save(balances); err != nil {
			return err
		}
	}

	return nil
}

// DropCollections removes all splitcore collections (reverse dependency order).
func DropCollections(app core.App) error {
	for _, name := range []string{"balances", "settlements", "split_entries", "expenses", "group_members", "groups"} {
		col, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			continue
		}
		if err := app.Delete(col); err != nil {
			return err
		}
	}
	return nil
}
