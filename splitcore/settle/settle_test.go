package settle

import (
	"errors"
	"testing"
)

// applyTransfers verifies transfers settle the balances to zero.
func applyTransfers(t *testing.T, balances []Balance, transfers []Transfer) {
	t.Helper()
	net := map[string]int64{}
	for _, b := range balances {
		net[b.MemberID] = b.NetCents
	}
	for _, tr := range transfers {
		if tr.AmountCents <= 0 {
			t.Fatalf("non-positive transfer: %+v", tr)
		}
		net[tr.FromMemberID] += tr.AmountCents
		net[tr.ToMemberID] -= tr.AmountCents
	}
	for id, n := range net {
		if n != 0 {
			t.Fatalf("member %s not settled: %d", id, n)
		}
	}
}

func TestSimplifyDebts(t *testing.T) {
	tests := []struct {
		name         string
		balances     []Balance
		want         []Transfer // nil means: only check invariants
		maxTransfers int
		wantErr      error
	}{
		{
			name: "simple pair",
			balances: []Balance{
				{"a", 500}, {"b", -500},
			},
			want:         []Transfer{{"b", "a", 500}},
			maxTransfers: 1,
		},
		{
			name: "triangle collapses to two transfers",
			balances: []Balance{
				{"a", 1000}, {"b", -400}, {"c", -600},
			},
			want:         []Transfer{{"c", "a", 600}, {"b", "a", 400}},
			maxTransfers: 2,
		},
		{
			name: "zero balances produce no transfers",
			balances: []Balance{
				{"a", 0}, {"b", 0},
			},
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name:         "empty input",
			balances:     nil,
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name: "single member zero",
			balances: []Balance{
				{"solo", 0},
			},
			want:         []Transfer{},
			maxTransfers: 0,
		},
		{
			name: "five members settle in at most four",
			balances: []Balance{
				{"a", 900}, {"b", -300}, {"c", 400}, {"d", -700}, {"e", -300},
			},
			maxTransfers: 4,
		},
		{
			name: "deterministic tie-break by member id",
			balances: []Balance{
				{"b", -250}, {"a", 500}, {"c", -250},
			},
			// b and c owe equally; b < c lexicographically, so b pays first
			want:         []Transfer{{"b", "a", 250}, {"c", "a", 250}},
			maxTransfers: 2,
		},
		{
			name: "unbalanced input rejected",
			balances: []Balance{
				{"a", 100}, {"b", -50},
			},
			wantErr: ErrUnbalanced,
		},
		{
			name: "duplicate member rejected",
			balances: []Balance{
				{"a", 100}, {"a", -100},
			},
			wantErr: ErrDuplicateMember,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := SimplifyDebts(tt.balances)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) > tt.maxTransfers {
				t.Errorf("want ≤%d transfers, got %d: %+v", tt.maxTransfers, len(got), got)
			}
			applyTransfers(t, tt.balances, got)
			if tt.want != nil {
				if len(got) != len(tt.want) {
					t.Fatalf("want %d transfers, got %d: %+v", len(tt.want), len(got), got)
				}
				for i := range got {
					if got[i] != tt.want[i] {
						t.Errorf("transfer[%d]: want %+v, got %+v", i, tt.want[i], got[i])
					}
				}
			}
		})
	}
}

func TestSimplifyDebtsDeterminism(t *testing.T) {
	balances := []Balance{
		{"a", 900}, {"b", -300}, {"c", 400}, {"d", -700}, {"e", -300},
	}
	first, err := SimplifyDebts(balances)
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 10; i++ {
		again, err := SimplifyDebts(balances)
		if err != nil {
			t.Fatal(err)
		}
		if len(again) != len(first) {
			t.Fatalf("run %d: transfer count changed", i)
		}
		for j := range again {
			if again[j] != first[j] {
				t.Fatalf("run %d: transfer[%d] differs: %+v vs %+v", i, j, again[j], first[j])
			}
		}
	}
}
