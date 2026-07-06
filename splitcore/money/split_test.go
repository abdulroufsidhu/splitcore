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

func TestComputeExactSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []ExactEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "valid exact split",
			total: 5000,
			entries: []ExactEntry{
				{"a", 1200}, {"b", 3800},
			},
			want: []Split{{"a", 1200}, {"b", 3800}},
		},
		{
			name:  "zero entry allowed (member owes nothing)",
			total: 100,
			entries: []ExactEntry{
				{"a", 100}, {"b", 0},
			},
			want: []Split{{"a", 100}, {"b", 0}},
		},
		{
			name:    "sum mismatch rejected",
			total:   5000,
			entries: []ExactEntry{{"a", 1200}, {"b", 3700}},
			wantErr: ErrExactSumMismatch,
		},
		{
			name:    "negative entry rejected",
			total:   100,
			entries: []ExactEntry{{"a", 200}, {"b", -100}},
			wantErr: ErrNegativeAmount,
		},
		{
			name:    "duplicate member rejected",
			total:   200,
			entries: []ExactEntry{{"a", 100}, {"a", 100}},
			wantErr: ErrDuplicateMember,
		},
		{
			name:    "empty rejected",
			total:   100,
			entries: nil,
			wantErr: ErrNoMembers,
		},
		{
			name:    "zero total rejected",
			total:   0,
			entries: []ExactEntry{{"a", 0}},
			wantErr: ErrNonPositiveTotal,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeExactSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("split[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
			}
		})
	}
}

func TestComputePercentSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []PercentEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "50/30/20",
			total: 10000,
			entries: []PercentEntry{
				{"a", 5000}, {"b", 3000}, {"c", 2000},
			},
			want: []Split{{"a", 5000}, {"b", 3000}, {"c", 2000}},
		},
		{
			name:  "thirds of 100.00 — largest remainder",
			total: 10000,
			entries: []PercentEntry{
				{"a", 3333}, {"b", 3333}, {"c", 3334},
			},
			// a: 3333.00→3333, b: 3333.00→3333, c: 3334.00→3334
			want: []Split{{"a", 3333}, {"b", 3333}, {"c", 3334}},
		},
		{
			name:  "remainder cent goes to largest fractional remainder",
			total: 101,
			entries: []PercentEntry{
				{"a", 5000}, {"b", 5000},
			},
			// 101*5000/10000 = 50.5 each; floor 50+50=100, leftover 1
			// equal remainders → tie broken by input order → a gets it
			want: []Split{{"a", 51}, {"b", 50}},
		},
		{
			name:    "sum below 10000 rejected",
			total:   100,
			entries: []PercentEntry{{"a", 5000}, {"b", 4999}},
			wantErr: ErrPercentSumInvalid,
		},
		{
			name:    "sum above 10000 rejected",
			total:   100,
			entries: []PercentEntry{{"a", 5000}, {"b", 5001}},
			wantErr: ErrPercentSumInvalid,
		},
		{
			name:    "zero basis points rejected",
			total:   100,
			entries: []PercentEntry{{"a", 10000}, {"b", 0}},
			wantErr: ErrNonPositiveShare,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputePercentSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
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

func TestComputeShareSplit(t *testing.T) {
	tests := []struct {
		name    string
		total   int64
		entries []ShareEntry
		want    []Split
		wantErr error
	}{
		{
			name:  "1:2:3 shares of 60.00",
			total: 6000,
			entries: []ShareEntry{
				{"a", 1}, {"b", 2}, {"c", 3},
			},
			want: []Split{{"a", 1000}, {"b", 2000}, {"c", 3000}},
		},
		{
			name:  "uneven: 2:1 of 0.05",
			total: 5,
			entries: []ShareEntry{
				{"a", 2}, {"b", 1},
			},
			// a: 10/3=3 rem 1, b: 5/3=1 rem 2 → leftover 1 → b (larger remainder)
			want: []Split{{"a", 3}, {"b", 2}},
		},
		{
			name:    "zero share rejected",
			total:   100,
			entries: []ShareEntry{{"a", 1}, {"b", 0}},
			wantErr: ErrNonPositiveShare,
		},
		{
			name:    "negative share rejected",
			total:   100,
			entries: []ShareEntry{{"a", 1}, {"b", -2}},
			wantErr: ErrNonPositiveShare,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeShareSplit(tt.total, tt.entries)
			if tt.wantErr != nil {
				if !errors.Is(err, tt.wantErr) {
					t.Fatalf("want error %v, got %v", tt.wantErr, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
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

func TestShareSplitConservation(t *testing.T) {
	entries := []ShareEntry{{"a", 3}, {"b", 5}, {"c", 7}, {"d", 11}}
	for total := int64(1); total <= 2000; total++ {
		splits, err := ComputeShareSplit(total, entries)
		if err != nil {
			t.Fatalf("total %d: %v", total, err)
		}
		if sum(splits) != total {
			t.Fatalf("total %d: sum %d — cents lost or duplicated", total, sum(splits))
		}
	}
}
