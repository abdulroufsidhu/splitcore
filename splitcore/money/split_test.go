package money

import (
	"errors"
	"testing"
)

func sum(splits []Split) int64 {
	var s int64
	for _, sp := range splits {
		s += sp.AmountCents
	}
	return s
}

func TestComputeEqualSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		members []string
		want    []Split
		wantErr error
	}{
		{
			name:    "even division",
			total:   9000,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 3000}, {"b", 3000}, {"c", 3000}},
		},
		{
			name:    "100.00 over 3 — leftover cent to first member",
			total:   10000,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 3334}, {"b", 3333}, {"c", 3333}},
		},
		{
			name:    "0.01 over 3 — only first member pays",
			total:   1,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 1}, {"b", 0}, {"c", 0}},
		},
		{
			name:    "single member gets everything",
			total:   777,
			members: []string{"solo"},
			want:    []Split{{"solo", 777}},
		},
		{
			name:    "two leftover cents to first two members",
			total:   11,
			members: []string{"a", "b", "c"},
			want:    []Split{{"a", 4}, {"b", 4}, {"c", 3}},
		},
		{
			name:    "empty members rejected",
			total:   100,
			members: nil,
			wantErr: ErrNoMembers,
		},
		{
			name:    "zero total rejected",
			total:   0,
			members: []string{"a"},
			wantErr: ErrNonPositiveTotal,
		},
		{
			name:    "negative total rejected",
			total:   -5,
			members: []string{"a"},
			wantErr: ErrNonPositiveTotal,
		},
		{
			name:    "duplicate member rejected",
			total:   100,
			members: []string{"a", "a"},
			wantErr: ErrDuplicateMember,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeEqualSplit(tt.total, tt.members)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if len(got) != len(tt.want) {
				t.Fatalf("want %d splits, got %d", len(tt.want), len(got))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
			if sum(got) != tt.total {
				t.Errorf("splits sum %d != total %d", sum(got), tt.total)
			}
		})
	}
}

func TestComputeEqualSplitConservation(t *testing.T) {
	members := []string{"a", "b", "c", "d", "e", "f", "g"}
	for total := int64(1); total <= 2000; total++ {
		splits, err := ComputeEqualSplit(total, members)
		if err != nil {
			t.Fatalf("total %d: %v", total, err)
		}
		if sum(splits) != total {
			t.Fatalf("total %d: sum %d — cents lost or duplicated", total, sum(splits))
		}
	}
}
