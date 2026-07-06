package testfix

import "testing"

func TestFixtureConstructs(t *testing.T) {
	f := New(t)
	if f.Group.GetString("currency") != "USD" {
		t.Errorf("want USD, got %s", f.Group.GetString("currency"))
	}
	if f.Version(t) != 0 {
		t.Errorf("fresh group version = %d, want 0", f.Version(t))
	}
}
