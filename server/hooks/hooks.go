// Package hooks wires splitcore validation, the per-group version
// counter, and balance recompute into PocketBase record events.
package hooks

import (
	"database/sql"
	"errors"
	"fmt"

	"github.com/pocketbase/dbx"
	"github.com/pocketbase/pocketbase/apis"
	"github.com/pocketbase/pocketbase/core"
)

// Register binds all app hooks. Called once from main.
func Register(app core.App) {
	app.OnRecordCreateRequest("groups").BindFunc(func(e *core.RecordRequestEvent) error {
		if e.Auth != nil {
			e.Record.Set("owner", e.Auth.Id)
		}
		e.Record.Set("version", 0)

		if err := e.Next(); err != nil {
			return err
		}
		return createOwnerMembership(e.App, e.Record)
	})

	app.OnRecordUpdateRequest("groups").BindFunc(func(e *core.RecordRequestEvent) error {
		stored, err := e.App.FindRecordById("groups", e.Record.Id)
		if err != nil {
			// Fail closed: never proceed with an update whose version/owner
			// guard could not be applied.
			return err
		}
		e.Record.Set("version", stored.GetInt("version"))
		e.Record.Set("owner", stored.GetString("owner"))
		return e.Next()
	})

	bind := func(e *core.RecordEvent) error {
		groupID, err := groupIDFor(e.App, e.Record, e.Type)
		if err != nil {
			return err
		}

		if e.Type != core.ModelEventTypeDelete {
			if err := validateRecord(e.App, e.Record); err != nil {
				return err
			}
		}

		if err := e.Next(); err != nil {
			return err
		}

		if groupID == "" {
			// Parent expense already gone (cascade-delete ordering) — the
			// expense's own delete hook already bumped/recomputed.
			return nil
		}
		return bumpAndRecompute(e.App, groupID)
	}
	app.OnRecordCreate("expenses", "split_entries", "settlements").BindFunc(bind)
	app.OnRecordUpdate("expenses", "split_entries", "settlements").BindFunc(bind)
	app.OnRecordDelete("expenses", "split_entries", "settlements").BindFunc(bind)

	// A membership change moves no money, so there is nothing to recompute
	// — but it does change what every member's client must have cached, and
	// `version` is the only signal clients have that a group moved on. Left
	// unbumped, a user added to a group stayed invisible on every other
	// member's device (so nobody could split an expense with them) until an
	// unrelated expense happened to bump the version and force a re-pull.
	memberBind := func(e *core.RecordEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		return bumpVersion(e.App, e.Record.GetString("group"))
	}
	app.OnRecordCreate("group_members").BindFunc(memberBind)
	app.OnRecordDelete("group_members").BindFunc(memberBind)

	app.OnRecordDelete("groups").BindFunc(func(e *core.RecordEvent) error {
		// PocketBase's built-in delete cascade processes the collections
		// referencing "groups" in alphabetical order: balances, expenses,
		// group_members, settlements. expenses.payer and split_entries.member
		// point at group_members without CascadeDelete, but by the time
		// group_members is cascade-deleted, every expense (and its
		// split_entries) already cascaded away — "expenses" sorts before
		// "group_members". settlements.from_member/to_member also point at
		// group_members without CascadeDelete, but "settlements" sorts
		// *after* "group_members", so its rows are still live when
		// group_members is cascade-deleted, and PocketBase refuses to
		// delete a group_members row that's still a required reference.
		// Deleting this group's settlements up front, before the group row
		// (and its cascade) ever hits the DB, clears that reference first.
		//
		// The pre-delete and the group delete itself must share one
		// transaction: this hook fires in the validation phase, before
		// OnRecordDeleteExecute opens its own tx, so without the explicit
		// RunInTransaction here a failed group delete would leave the
		// settlements permanently gone while the group survived. Nested
		// RunInTransaction calls reuse the outer tx, so swapping e.App to
		// txApp for the duration of e.Next() keeps the whole delete
		// (pre-delete + cascade) atomic.
		return e.App.RunInTransaction(func(txApp core.App) error {
			if err := deleteGroupSettlements(txApp, e.Record.Id); err != nil {
				return err
			}
			orig := e.App
			e.App = txApp
			defer func() { e.App = orig }()
			return e.Next()
		})
	})

	registerStaleness(app)
	registerInvite(app)
	registerInviteAcceptance(app)
	registerMembers(app)
	registerAccountDeletion(app)
}

// deleteGroupSettlements deletes every settlements row for groupID. Used to
// pre-clear settlements' non-cascading references to this group's
// group_members rows before the group itself (and PocketBase's built-in
// cascade) is deleted — see the OnRecordDelete("groups") comment above.
func deleteGroupSettlements(app core.App, groupID string) error {
	settlements, err := app.FindRecordsByFilter("settlements", "group = {:g}", "", 0, 0, dbx.Params{"g": groupID})
	if err != nil {
		return err
	}
	for _, s := range settlements {
		if err := app.Delete(s); err != nil {
			return err
		}
	}
	return nil
}

// createOwnerMembership adds a group_members row with role "owner" for the
// group's owner, right after a groups record is created.
func createOwnerMembership(app core.App, group *core.Record) error {
	col, err := app.FindCollectionByNameOrId("group_members")
	if err != nil {
		return err
	}
	m := core.NewRecord(col)
	m.Set("group", group.Id)
	m.Set("user", group.GetString("owner"))
	m.Set("role", "owner")
	return app.Save(m)
}

// groupIDFor resolves the owning group id for a record from one of
// expenses, split_entries, or settlements. Only for a split_entries
// DELETE whose parent expense is already gone (cascade-delete ordering)
// does it return an empty id and no error so the caller can skip
// recompute silently; every other lookup failure is propagated.
func groupIDFor(app core.App, record *core.Record, eventType string) (string, error) {
	switch record.Collection().Name {
	case "expenses", "settlements":
		return record.GetString("group"), nil
	case "split_entries":
		expense, err := app.FindRecordById("expenses", record.GetString("expense"))
		if err != nil {
			if eventType == core.ModelEventTypeDelete && errors.Is(err, sql.ErrNoRows) {
				return "", nil
			}
			return "", err
		}
		return expense.GetString("group"), nil
	default:
		return "", fmt.Errorf("hooks: unsupported collection %q", record.Collection().Name)
	}
}

// validateRecord enforces the domain semantics for expenses, split_entries,
// and settlements records prior to create/update.
func validateRecord(app core.App, record *core.Record) error {
	switch record.Collection().Name {
	case "expenses":
		if err := validateExpense(app, record); err != nil {
			return err
		}
		return rejectGroupReparent(record)
	case "split_entries":
		if err := validateSplitEntry(app, record); err != nil {
			return err
		}
		return rejectSplitReparent(app, record)
	case "settlements":
		if err := validateSettlement(app, record); err != nil {
			return err
		}
		return rejectGroupReparent(record)
	}
	return nil
}

// rejectGroupReparent forbids changing the "group" relation of an existing
// expenses or settlements record on update. Moving a record between groups
// would leave the old group's cached balances stale (the recompute only
// ever touches one group per hook invocation), so it is disallowed outright
// rather than attempting to recompute both groups.
//
// New records (not yet persisted) have no prior group to compare against,
// so record.Original() is blank and this is a no-op for creates.
func rejectGroupReparent(record *core.Record) error {
	if record.IsNew() {
		return nil
	}
	original := record.Original()
	if original.GetString("group") != "" && original.GetString("group") != record.GetString("group") {
		return apis.NewBadRequestError("group re-parenting is not allowed", nil)
	}
	return nil
}

// rejectSplitReparent forbids moving a split_entries row to an expense that
// belongs to a different group than its current expense. Moving a split
// between two expenses within the same group is legal and unaffected.
func rejectSplitReparent(app core.App, record *core.Record) error {
	if record.IsNew() {
		return nil
	}
	original := record.Original()
	oldExpenseID := original.GetString("expense")
	newExpenseID := record.GetString("expense")
	if oldExpenseID == "" || oldExpenseID == newExpenseID {
		return nil
	}

	oldExpense, err := app.FindRecordById("expenses", oldExpenseID)
	if err != nil {
		if errors.Is(err, sql.ErrNoRows) {
			// The old parent expense is gone (e.g. cascade-delete
			// ordering) — nothing to compare against, so let the update
			// proceed.
			return nil
		}
		// Any other failure means the guard could not be applied — fail
		// closed rather than silently allowing a potential re-parent.
		return err
	}
	newExpense, err := app.FindRecordById("expenses", newExpenseID)
	if err != nil {
		return apis.NewBadRequestError("split_entries.expense must reference an existing expense", nil)
	}
	if oldExpense.GetString("group") != newExpense.GetString("group") {
		return apis.NewBadRequestError("group re-parenting is not allowed", nil)
	}
	return nil
}

func validateExpense(app core.App, record *core.Record) error {
	if int64(record.GetInt("amount_cents")) <= 0 {
		return apis.NewBadRequestError("expense amount_cents must be positive", nil)
	}

	payer, err := app.FindRecordById("group_members", record.GetString("payer"))
	if err != nil {
		return apis.NewBadRequestError("expense payer must be a valid group member", nil)
	}
	if payer.GetString("group") != record.GetString("group") {
		return apis.NewBadRequestError("expense payer must belong to the expense's group", nil)
	}
	return nil
}

func validateSplitEntry(app core.App, record *core.Record) error {
	if int64(record.GetInt("amount_cents")) < 0 {
		return apis.NewBadRequestError("split amount_cents must not be negative", nil)
	}

	expense, err := app.FindRecordById("expenses", record.GetString("expense"))
	if err != nil {
		return apis.NewBadRequestError("split_entries.expense must reference an existing expense", nil)
	}

	member, err := app.FindRecordById("group_members", record.GetString("member"))
	if err != nil {
		return apis.NewBadRequestError("split_entries.member must be a valid group member", nil)
	}
	if member.GetString("group") != expense.GetString("group") {
		return apis.NewBadRequestError("split entry member must belong to the expense's group", nil)
	}
	return nil
}

func validateSettlement(app core.App, record *core.Record) error {
	if int64(record.GetInt("amount_cents")) <= 0 {
		return apis.NewBadRequestError("settlement amount_cents must be positive", nil)
	}

	fromID := record.GetString("from_member")
	toID := record.GetString("to_member")
	if fromID == toID {
		return apis.NewBadRequestError("settlement from_member and to_member must differ", nil)
	}

	groupID := record.GetString("group")

	from, err := app.FindRecordById("group_members", fromID)
	if err != nil || from.GetString("group") != groupID {
		return apis.NewBadRequestError("settlement from_member must belong to the settlement's group", nil)
	}

	to, err := app.FindRecordById("group_members", toID)
	if err != nil || to.GetString("group") != groupID {
		return apis.NewBadRequestError("settlement to_member must belong to the settlement's group", nil)
	}
	return nil
}
