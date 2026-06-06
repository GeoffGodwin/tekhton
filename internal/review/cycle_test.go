package review

import "testing"

func TestCycleBudget_Increment(t *testing.T) {
	c := CycleBudget{Current: 0, Max: 3}
	c.Increment()
	if c.Current != 1 {
		t.Errorf("Current = %d, want 1", c.Current)
	}
	c.Increment()
	c.Increment()
	if c.Current != 3 {
		t.Errorf("Current = %d, want 3", c.Current)
	}
	if !c.IsLastCycle() {
		t.Errorf("IsLastCycle() = false, want true (Current == Max)")
	}
	if !c.IsExhausted() {
		t.Errorf("IsExhausted() = false, want true (Current >= Max)")
	}
}

func TestCycleBudget_Remaining(t *testing.T) {
	cases := []struct {
		current, max int
		want         int
	}{
		{0, 3, 3},
		{1, 3, 2},
		{3, 3, 0},
		{4, 3, 0}, // overrun → still 0, never negative
	}
	for _, tc := range cases {
		c := CycleBudget{Current: tc.current, Max: tc.max}
		if got := c.Remaining(); got != tc.want {
			t.Errorf("Remaining(Current=%d, Max=%d) = %d, want %d",
				tc.current, tc.max, got, tc.want)
		}
	}
}

func TestCycleBudget_IsLastCycle(t *testing.T) {
	cases := []struct {
		current, max int
		want         bool
	}{
		{0, 3, false},
		{1, 3, false},
		{2, 3, false},
		{3, 3, true},
		{4, 3, false}, // overrun → not "last", we're already past
		{0, 0, false}, // Max==0 → no cycles defined
	}
	for _, tc := range cases {
		c := CycleBudget{Current: tc.current, Max: tc.max}
		if got := c.IsLastCycle(); got != tc.want {
			t.Errorf("IsLastCycle(Current=%d, Max=%d) = %v, want %v",
				tc.current, tc.max, got, tc.want)
		}
	}
}

func TestCycleBudget_IsExhausted(t *testing.T) {
	cases := []struct {
		current, max int
		want         bool
	}{
		{0, 3, false},
		{2, 3, false},
		{3, 3, true},
		{4, 3, true},  // overrun → exhausted
		{0, 0, false}, // Max==0 → guarded
	}
	for _, tc := range cases {
		c := CycleBudget{Current: tc.current, Max: tc.max}
		if got := c.IsExhausted(); got != tc.want {
			t.Errorf("IsExhausted(Current=%d, Max=%d) = %v, want %v",
				tc.current, tc.max, got, tc.want)
		}
	}
}

func TestCycleBudget_BumpFromUsage(t *testing.T) {
	cases := []struct {
		name             string
		used, limit, cap int
		wantNewLimit     int
		wantBumped       bool
	}{
		{
			name: "used_zero_no_bump",
			used: 0, limit: 20, cap: 60,
			wantNewLimit: 20, wantBumped: false,
		},
		{
			name: "limit_zero_no_bump",
			used: 15, limit: 0, cap: 60,
			wantNewLimit: 0, wantBumped: false,
		},
		{
			name: "under_85pct_no_bump",
			used: 16, limit: 20, cap: 60, // 80%
			wantNewLimit: 20, wantBumped: false,
		},
		{
			name: "at_85pct_bump",
			used: 17, limit: 20, cap: 60, // 85%
			wantNewLimit: 25, wantBumped: true,
		},
		{
			name: "above_85pct_bump",
			used: 19, limit: 20, cap: 60, // 95%
			wantNewLimit: 25, wantBumped: true,
		},
		{
			name: "bump_clamped_to_cap",
			used: 50, limit: 50, cap: 60, // 100% — bump would be 62, clamped to 60
			wantNewLimit: 60, wantBumped: true,
		},
		{
			name: "at_cap_no_bump",
			used: 58, limit: 60, cap: 60, // 96% but already at cap
			wantNewLimit: 60, wantBumped: false,
		},
		{
			name: "cap_defaults_to_60",
			used: 50, limit: 50, cap: 0, // cap==0 defaults to 60; bump 62 → 60
			wantNewLimit: 60, wantBumped: true,
		},
		{
			name: "custom_cap_below_default",
			used: 17, limit: 20, cap: 22, // bump would be 25, clamped to 22
			wantNewLimit: 22, wantBumped: true,
		},
		{
			name: "custom_cap_equal_to_limit",
			used: 17, limit: 20, cap: 20, // bump would be 25, clamped to 20 (== limit) → no bump
			wantNewLimit: 20, wantBumped: false,
		},
	}

	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			c := CycleBudget{Current: 1, Max: 3}
			gotLimit, gotBumped := c.BumpFromUsage(tc.used, tc.limit, tc.cap)
			if gotLimit != tc.wantNewLimit {
				t.Errorf("BumpFromUsage(used=%d, limit=%d, cap=%d) limit = %d, want %d",
					tc.used, tc.limit, tc.cap, gotLimit, tc.wantNewLimit)
			}
			if gotBumped != tc.wantBumped {
				t.Errorf("BumpFromUsage(used=%d, limit=%d, cap=%d) bumped = %v, want %v",
					tc.used, tc.limit, tc.cap, gotBumped, tc.wantBumped)
			}
			// The receiver MUST NOT mutate.
			if c.Current != 1 || c.Max != 3 {
				t.Errorf("BumpFromUsage mutated the receiver: Current=%d Max=%d (want 1, 3)",
					c.Current, c.Max)
			}
		})
	}
}
