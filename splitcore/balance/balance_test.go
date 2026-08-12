package balance

import (
	"errors"
	"math"
	"testing"

	"github.com/abdulroufsidhu/splitcore/splitcore/money"
	"github.com/abdulroufsidhu/splitcore/splitcore/settle"
)

func TestComputeBalances(t *testing.T) {
	tests := []struct {
		name        string
		expenses    []Expense
		settlements []Settlement
		want        []settle.Balance
		wantErr     error
	}{
		{
			name: "single expense, payer included in split",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 3000,
					Splits: []money.Split{
						{MemberID: "a", AmountCents: 1000},
						{MemberID: "b", AmountCents: 1000},
						{MemberID: "c", AmountCents: 1000},
					},
				},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 2000},
				{MemberID: "b", NetCents: -1000},
				{MemberID: "c", NetCents: -1000},
			},
		},
		{
			name: "settlement reduces debt",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 2000,
					Splits: []money.Split{
						{MemberID: "a", AmountCents: 1000},
						{MemberID: "b", AmountCents: 1000},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 600},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 400},
				{MemberID: "b", NetCents: -400},
			},
		},
		{
			name: "full settlement zeroes group",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 1000,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 1000},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 1000},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: 0},
				{MemberID: "b", NetCents: 0},
			},
		},
		{
			name: "overpayment flips direction",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 500,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 500},
					},
				},
			},
			settlements: []Settlement{
				{FromMemberID: "b", ToMemberID: "a", AmountCents: 800},
			},
			want: []settle.Balance{
				{MemberID: "a", NetCents: -300},
				{MemberID: "b", NetCents: 300},
			},
		},
		{
			name:        "empty log yields empty balances",
			expenses:    nil,
			settlements: nil,
			want:        []settle.Balance{},
		},
		{
			name: "split sum mismatch rejected",
			expenses: []Expense{
				{
					PayerID:     "a",
					AmountCents: 1000,
					Splits: []money.Split{
						{MemberID: "b", AmountCents: 999},
					},
				},
			},
			wantErr: ErrSplitSumMismatch,
		},
		{
			name: "non-positive expense rejected",
			expenses: []Expense{
				{PayerID: "a", AmountCents: 0, Splits: nil},
			},
			wantErr: ErrNonPositiveAmount,
		},
		{
			name: "non-positive settlement rejected",
			settlements: []Settlement{
				{FromMemberID: "a", ToMemberID: "b", AmountCents: 0},
			},
			wantErr: ErrNonPositiveAmount,
		},
		{
			name: "self settlement rejected",
			settlements: []Settlement{
				{FromMemberID: "a", ToMemberID: "a", AmountCents: 100},
			},
			wantErr: ErrSelfSettlement,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := ComputeBalances(tt.expenses, tt.settlements)
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
				t.Fatalf("want %d balances, got %d: %+v", len(tt.want), len(got), got)
			}
			var sum int64
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("balance[%d]: want %+v, got %+v", i, tt.want[i], got[i])
				}
				sum += got[i].NetCents
			}
			if sum != 0 {
				t.Errorf("balances sum to %d, want 0", sum)
			}
		})
	}
}

// TestComputeBalancesOverflow guards against F3: a split-sum wraparound
// must be rejected as ErrOverflow rather than slipping past
// ErrSplitSumMismatch by coincidentally wrapping back to the expense
// amount.
func TestComputeBalancesOverflow(t *testing.T) {
	expenses := []Expense{
		{
			PayerID:     "a",
			AmountCents: 100,
			Splits: []money.Split{
				{MemberID: "a", AmountCents: math.MaxInt64},
				{MemberID: "b", AmountCents: math.MaxInt64},
				{MemberID: "c", AmountCents: 102},
			},
		},
	}
	_, err := ComputeBalances(expenses, nil)
	if !errors.Is(err, ErrOverflow) {
		t.Fatalf("want ErrOverflow, got %v", err)
	}
}

func TestComputeBalancesDeterministicOrder(t *testing.T) {
	expenses := []Expense{
		{
			PayerID:     "zed",
			AmountCents: 300,
			Splits: []money.Split{
				{MemberID: "mia", AmountCents: 100},
				{MemberID: "abe", AmountCents: 100},
				{MemberID: "zed", AmountCents: 100},
			},
		},
	}
	got, err := ComputeBalances(expenses, nil)
	if err != nil {
		t.Fatal(err)
	}
	wantOrder := []string{"abe", "mia", "zed"}
	for i, id := range wantOrder {
		if got[i].MemberID != id {
			t.Errorf("balance[%d]: want member %s, got %s", i, id, got[i].MemberID)
		}
	}
}
