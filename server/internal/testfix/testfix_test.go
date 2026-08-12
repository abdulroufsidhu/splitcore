package testfix

import "testing"

func TestFixtureConstructs(t *testing.T) {
	f := New(t)
	if f.Group.GetString("currency") != "USD" {
		t.Errorf("want USD, got %s", f.Group.GetString("currency"))
	}
	// One bump per group_members row the fixture saves (alice, then bob) —
	// membership changes move the version so every member's client learns
	// it has to re-pull the roster.
	if f.Version(t) != 2 {
		t.Errorf("fresh group version = %d, want 2", f.Version(t))
	}
}
