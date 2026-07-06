package migrations

import (
	"testing"

	"github.com/pocketbase/pocketbase/tests"
)

func TestInitCollections(t *testing.T) {
	app, err := tests.NewTestApp()
	if err != nil {
		t.Fatal(err)
	}
	defer app.Cleanup()

	if err := InitCollections(app); err != nil {
		t.Fatalf("InitCollections: %v", err)
	}

	wantRules := map[string]struct {
		list, view, create, update, del bool // true = rule non-nil (client path exists)
	}{
		"groups":        {true, true, true, true, true},
		"group_members": {true, true, true, true, true},
		"expenses":      {true, true, true, true, true},
		"split_entries": {true, true, true, true, true},
		"settlements":   {true, true, true, true, true},
		"balances":      {true, true, false, false, false},
	}
	for name, want := range wantRules {
		col, err := app.FindCollectionByNameOrId(name)
		if err != nil {
			t.Fatalf("collection %s missing: %v", name, err)
		}
		got := []struct {
			label string
			rule  *string
			want  bool
		}{
			{"list", col.ListRule, want.list},
			{"view", col.ViewRule, want.view},
			{"create", col.CreateRule, want.create},
			{"update", col.UpdateRule, want.update},
			{"delete", col.DeleteRule, want.del},
		}
		for _, g := range got {
			if (g.rule != nil) != g.want {
				t.Errorf("%s.%sRule: non-nil=%v, want %v", name, g.label, g.rule != nil, g.want)
			}
			if g.rule != nil && *g.rule == "" {
				t.Errorf("%s.%sRule: empty string (public!) — must be a real rule", name, g.label)
			}
		}
	}

	// spot-check fields
	expenses, _ := app.FindCollectionByNameOrId("expenses")
	for _, f := range []string{"group", "payer", "description", "amount_cents", "split_type", "date"} {
		if expenses.Fields.GetByName(f) == nil {
			t.Errorf("expenses missing field %s", f)
		}
	}
	se, _ := app.FindCollectionByNameOrId("split_entries")
	if se.Fields.GetByName("receipt") == nil {
		t.Error("split_entries missing receipt file field")
	}

	// idempotent-ish: running again must fail cleanly, not panic
	if err := InitCollections(app); err == nil {
		t.Log("second InitCollections returned nil (collections already exist) — acceptable only if it skipped existing")
	}

	// down migration removes everything
	if err := DropCollections(app); err != nil {
		t.Fatalf("DropCollections: %v", err)
	}
	if _, err := app.FindCollectionByNameOrId("groups"); err == nil {
		t.Error("groups still present after DropCollections")
	}
}
