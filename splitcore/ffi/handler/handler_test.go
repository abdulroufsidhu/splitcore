package handler

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestComputeSplitsJSON(t *testing.T) {
	tests := []struct {
		name   string
		req    string
		want   string // exact JSON, or "" when wantErrSub is set
		errSub string
	}{
		{
			name: "equal",
			req:  `{"type":"equal","total_cents":10000,"entries":[{"member_id":"a"},{"member_id":"b"},{"member_id":"c"}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":3334},{"member_id":"b","amount_cents":3333},{"member_id":"c","amount_cents":3333}]}`,
		},
		{
			name: "exact",
			req:  `{"type":"exact","total_cents":500,"entries":[{"member_id":"a","amount_cents":200},{"member_id":"b","amount_cents":300}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":200},{"member_id":"b","amount_cents":300}]}`,
		},
		{
			name: "percent",
			req:  `{"type":"percent","total_cents":10000,"entries":[{"member_id":"a","basis_points":2500},{"member_id":"b","basis_points":7500}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":2500},{"member_id":"b","amount_cents":7500}]}`,
		},
		{
			name: "shares",
			req:  `{"type":"shares","total_cents":6000,"entries":[{"member_id":"a","shares":1},{"member_id":"b","shares":2}]}`,
			want: `{"splits":[{"member_id":"a","amount_cents":2000},{"member_id":"b","amount_cents":4000}]}`,
		},
		{
			name:   "domain error surfaces as json error",
			req:    `{"type":"percent","total_cents":100,"entries":[{"member_id":"a","basis_points":5000}]}`,
			errSub: "basis points",
		},
		{
			name:   "unknown type",
			req:    `{"type":"magic","total_cents":100,"entries":[]}`,
			errSub: "unknown split type",
		},
		{
			name:   "malformed json",
			req:    `{"type":`,
			errSub: "parse",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ComputeSplitsJSON(tt.req)
			if tt.errSub != "" {
				var e struct {
					Error string `json:"error"`
				}
				if err := json.Unmarshal([]byte(got), &e); err != nil || e.Error == "" {
					t.Fatalf("want error json, got %s", got)
				}
				if !strings.Contains(e.Error, tt.errSub) {
					t.Fatalf("want error containing %q, got %q", tt.errSub, e.Error)
				}
				return
			}
			if got != tt.want {
				t.Errorf("want %s\ngot  %s", tt.want, got)
			}
		})
	}
}

func TestSimplifyDebtsJSON(t *testing.T) {
	req := `{"balances":[{"member_id":"a","net_cents":500},{"member_id":"b","net_cents":-500}]}`
	want := `{"transfers":[{"from_member_id":"b","to_member_id":"a","amount_cents":500}]}`
	if got := SimplifyDebtsJSON(req); got != want {
		t.Errorf("want %s\ngot  %s", want, got)
	}

	// error path
	got := SimplifyDebtsJSON(`{"balances":[{"member_id":"a","net_cents":1}]}`)
	if !strings.Contains(got, "sum to zero") {
		t.Errorf("want unbalanced error, got %s", got)
	}

	// empty transfers must encode as [] not null
	got = SimplifyDebtsJSON(`{"balances":[]}`)
	if got != `{"transfers":[]}` {
		t.Errorf("want empty array, got %s", got)
	}
}

func TestComputeBalancesJSON(t *testing.T) {
	req := `{"expenses":[{"payer_id":"a","amount_cents":1000,"splits":[{"member_id":"b","amount_cents":1000}]}],"settlements":[{"from_member_id":"b","to_member_id":"a","amount_cents":400}]}`
	want := `{"balances":[{"member_id":"a","net_cents":600},{"member_id":"b","net_cents":-600}]}`
	if got := ComputeBalancesJSON(req); got != want {
		t.Errorf("want %s\ngot  %s", want, got)
	}

	// empty log must encode as [] not null
	got := ComputeBalancesJSON(`{"expenses":[],"settlements":[]}`)
	if got != `{"balances":[]}` {
		t.Errorf("want empty array, got %s", got)
	}
}
