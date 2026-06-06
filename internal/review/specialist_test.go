package review

import "testing"

func TestHasSpecialistBlockers(t *testing.T) {
	cases := []struct {
		name string
		env  string
		want bool
	}{
		{"empty_string", "", false},
		{"whitespace_only", "   \n\t  \n", false},
		{"literal_None_capital", "None", false},
		{"literal_none_lowercase", "none", false},
		{"dash_None_bullet", "- None", false},
		{"dash_none_lowercase", "- none", false},
		{"single_blocker", "- broken auth on /admin", true},
		{"multiline_with_None_and_real", "- None\n- real blocker", true},
		{"blank_line_then_content", "\n\nactual blocker text\n\n", true},
		{"only_whitespace_None", "\n  None  \n", false},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if got := HasSpecialistBlockers(tc.env); got != tc.want {
				t.Errorf("HasSpecialistBlockers(%q) = %v, want %v", tc.env, got, tc.want)
			}
		})
	}
}

func TestFormatSpecialistSection_BashByteParity(t *testing.T) {
	// Bash review_helpers.sh:11-17 writes:
	//
	//   echo ""                          → "\n"
	//   echo "## Specialist Blockers"    → "## Specialist Blockers\n"
	//   echo "$SPECIALIST_BLOCKERS"      → "<env>\n"
	//
	// Total: "\n## Specialist Blockers\n<env>\n". When env already ends in
	// "\n", we don't double up.
	cases := []struct {
		name string
		env  string
		want string
	}{
		{
			name: "no_trailing_newline",
			env:  "- broken auth",
			want: "\n## Specialist Blockers\n- broken auth\n",
		},
		{
			name: "with_trailing_newline",
			env:  "- broken auth\n",
			want: "\n## Specialist Blockers\n- broken auth\n",
		},
		{
			name: "multiline_env",
			env:  "- one\n- two",
			want: "\n## Specialist Blockers\n- one\n- two\n",
		},
		{
			name: "empty_env",
			env:  "",
			want: "\n## Specialist Blockers\n\n",
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got := FormatSpecialistSection(tc.env)
			if got != tc.want {
				t.Errorf("FormatSpecialistSection(%q):\n  got:  %q\n  want: %q", tc.env, got, tc.want)
			}
		})
	}
}

func TestRouteSpecialistRework(t *testing.T) {
	cases := []struct {
		name   string
		env    string
		budget CycleBudget
		want   SpecialistDecision
	}{
		{
			name:   "no_blockers_passthrough",
			env:    "None",
			budget: CycleBudget{Current: 0, Max: 3},
			want:   SpecialistPassthrough,
		},
		{
			name:   "blockers_with_cycles_remaining",
			env:    "- something",
			budget: CycleBudget{Current: 1, Max: 3},
			want:   SpecialistRework,
		},
		{
			name:   "blockers_exhausted",
			env:    "- something",
			budget: CycleBudget{Current: 3, Max: 3},
			want:   SpecialistExhausted,
		},
		{
			name:   "blockers_overrun",
			env:    "- something",
			budget: CycleBudget{Current: 4, Max: 3},
			want:   SpecialistExhausted,
		},
		{
			name:   "blockers_at_last_cycle_treated_as_exhausted",
			env:    "- something",
			budget: CycleBudget{Current: 3, Max: 3}, // bash review_helpers.sh:21 `[[ "$REVIEW_CYCLE" -ge "${MAX_REVIEW_CYCLES:-3}" ]]` — Current == Max is exhausted at the post-loop check
			want:   SpecialistExhausted,
		},
		{
			name:   "empty_env_passthrough",
			env:    "",
			budget: CycleBudget{Current: 0, Max: 3},
			want:   SpecialistPassthrough,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if got := RouteSpecialistRework(tc.env, tc.budget); got != tc.want {
				t.Errorf("RouteSpecialistRework(%q, %+v) = %d, want %d",
					tc.env, tc.budget, got, tc.want)
			}
		})
	}
}
