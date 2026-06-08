package buildfix

import (
	"strings"
	"testing"
)

// TestDefaultConfig pins the bash default values byte-identically.
// Any drift here means the Go port diverged from
// stages/coder_buildfix_helpers.sh + the M128 env contract.
func TestDefaultConfig(t *testing.T) {
	got := DefaultConfig()
	want := Config{
		Enabled:                true,
		MaxAttempts:            3,
		BaseTurnDivisor:        3,
		MaxTurnMultiplier:      100,
		RequireProgress:        true,
		TotalTurnCap:           120,
		ClassificationRequired: false,
		EffectiveCoderMaxTurns: 80,
	}
	if got != want {
		t.Fatalf("DefaultConfig() = %+v, want %+v", got, want)
	}
}

// TestTokenVocabulary_MatchesBash pins every token constant to its bash
// string literal. The m39.3 loop + M132's _collect_build_fix_stats_json
// pattern-match on these exact strings; any drift fails red here.
func TestTokenVocabulary_MatchesBash(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		// Decision (M127 routing tokens).
		{"DecisionCodeDominant", string(DecisionCodeDominant), "code_dominant"},
		{"DecisionNoncodeDominant", string(DecisionNoncodeDominant), "noncode_dominant"},
		{"DecisionMixedUncertain", string(DecisionMixedUncertain), "mixed_uncertain"},
		{"DecisionUnknownOnly", string(DecisionUnknownOnly), "unknown_only"},
		// Signal (M128 progress-signal tokens).
		{"SignalImproved", string(SignalImproved), "improved"},
		{"SignalUnchanged", string(SignalUnchanged), "unchanged"},
		{"SignalWorsened", string(SignalWorsened), "worsened"},
		// Outcome (M132 stats tokens).
		{"OutcomePassed", string(OutcomePassed), "passed"},
		{"OutcomeExhausted", string(OutcomeExhausted), "exhausted"},
		{"OutcomeNoProgress", string(OutcomeNoProgress), "no_progress"},
		{"OutcomeNotRun", string(OutcomeNotRun), "not_run"},
		// Class (per-attempt report terminal class).
		{"ClassSuccess", string(ClassSuccess), "success"},
		{"ClassMaxTurns", string(ClassMaxTurns), "max_turns"},
		{"ClassError", string(ClassError), "error"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %q, want %q", c.name, c.got, c.want)
		}
	}
}

// TestComputeBudget covers the full 14-row adaptive-budget decision tree
// per the m39.2 milestone design table.
func TestComputeBudget(t *testing.T) {
	cases := []struct {
		name       string
		attempt    int
		base       int
		used       int
		multiplier int
		cap        int
		want       int
		reason     string
	}{
		{"01 attempt1 1x base", 1, 27, 0, 100, 120, 27, "1× base"},
		{"02 attempt2 1.5x base", 2, 27, 0, 100, 120, 40, "27*3/2=40"},
		{"03 attempt3 2x base", 3, 27, 0, 100, 120, 54, "2× base"},
		{"04 floor clamp", 1, 4, 0, 100, 120, 8, "floor 8"},
		{"05 mult under no clamp", 1, 27, 0, 50, 120, 27, "upper 80*50/100=40; no clamp"},
		{"06 upper clamps double", 3, 80, 0, 100, 120, 80, "upper=80, clamps 160→80"},
		{"07 remaining clamps", 1, 27, 100, 100, 120, 20, "remaining=20, clamps 27→20"},
		{"08 remaining below floor", 1, 27, 113, 100, 120, 0, "remaining=7 < 8 → halt"},
		{"09 remaining zero", 1, 27, 120, 100, 120, 0, "remaining=0 → halt"},
		{"10 remaining negative", 1, 27, 130, 100, 120, 0, "remaining=-10 → halt"},
		{"11 large multiplier headroom", 2, 100, 0, 200, 240, 150, "upper=160; 100*3/2=150; no clamp"},
		{"12 large multiplier with remaining clamp", 3, 100, 100, 200, 240, 140, "2×=200, upper=160, remaining=140"},
		{"13 multiplier 0 defaults to 100", 1, 27, 0, 0, 120, 27, "multiplier=0 → defaults 100"},
		{"14 cap 0 defaults to 120", 1, 27, 0, 100, 0, 27, "cap=0 → defaults 120"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			cfg := Config{
				EffectiveCoderMaxTurns: 80,
				MaxTurnMultiplier:      c.multiplier,
				TotalTurnCap:           c.cap,
			}
			got := ComputeBudget(c.attempt, c.base, c.used, cfg)
			if got != c.want {
				t.Fatalf("ComputeBudget(attempt=%d, base=%d, used=%d, mult=%d, cap=%d) = %d, want %d (%s)",
					c.attempt, c.base, c.used, c.multiplier, c.cap, got, c.want, c.reason)
			}
		})
	}
}

// TestComputeBudget_EffectiveMaxTurnsZeroDefault asserts that a zero
// EffectiveCoderMaxTurns falls back to 80 (mirrors bash's
// ${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}} expansion).
func TestComputeBudget_EffectiveMaxTurnsZeroDefault(t *testing.T) {
	cfg := Config{
		EffectiveCoderMaxTurns: 0,
		MaxTurnMultiplier:      100,
		TotalTurnCap:           120,
	}
	if got := ComputeBudget(3, 80, 0, cfg); got != 80 {
		t.Fatalf("ComputeBudget with EffectiveCoderMaxTurns=0 = %d, want 80 (upper=80)", got)
	}
}

// TestProgressSignal covers the 7-row truth table including the
// "equal counts, different tails → improved" branch.
func TestProgressSignal(t *testing.T) {
	cases := []struct {
		name     string
		prev     int
		new      int
		prevTail string
		newTail  string
		want     Signal
	}{
		{"count down → improved", 12, 5, "x", "x", SignalImproved},
		{"count up → worsened", 5, 12, "x", "x", SignalWorsened},
		{"equal counts, equal tails → unchanged", 5, 5, "x", "x", SignalUnchanged},
		{"equal counts, different tails → improved", 5, 5, "x", "y", SignalImproved},
		{"both zero, tails equal → unchanged", 0, 0, "", "", SignalUnchanged},
		{"both zero, tails differ → improved", 0, 0, "a", "b", SignalImproved},
		{"equal counts, one empty tail → improved", 3, 3, "", "x", SignalImproved},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := ProgressSignal(c.prev, c.new, c.prevTail, c.newTail); got != c.want {
				t.Fatalf("ProgressSignal(%d,%d,%q,%q) = %s, want %s",
					c.prev, c.new, c.prevTail, c.newTail, got, c.want)
			}
		})
	}
}

// TestTerminalClass covers the 4-row truth table from the milestone
// acceptance criterion: success / max_turns / error / explicit-zero-exit.
func TestTerminalClass(t *testing.T) {
	cases := []struct {
		name     string
		exitCode int
		turns    int
		max      int
		want     Class
	}{
		{"success (exit 0)", 0, 5, 10, ClassSuccess},
		{"max_turns (exit nonzero, turns>=max)", 1, 10, 10, ClassMaxTurns},
		{"error (exit nonzero, turns<max)", 1, 5, 10, ClassError},
		{"all zeros → success", 0, 0, 0, ClassSuccess},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := TerminalClass(c.exitCode, c.turns, c.max); got != c.want {
				t.Fatalf("TerminalClass(%d,%d,%d) = %s, want %s",
					c.exitCode, c.turns, c.max, got, c.want)
			}
		})
	}
}

// TestExtraContextFor covers the four decision branches.
func TestExtraContextFor(t *testing.T) {
	// code_dominant → empty
	if got := ExtraContextFor(DecisionCodeDominant, ""); got != "" {
		t.Errorf("code_dominant should return empty, got %q", got)
	}
	// noncode_dominant → empty (defensive; never reached by the loop)
	if got := ExtraContextFor(DecisionNoncodeDominant, ""); got != "" {
		t.Errorf("noncode_dominant should return empty, got %q", got)
	}
	// mixed_uncertain → non-empty, ends with the diagnosis-path reference
	got := ExtraContextFor(DecisionMixedUncertain, ".tekhton/BUILD_ROUTING_DIAGNOSIS.md")
	if got == "" {
		t.Fatalf("mixed_uncertain should be non-empty")
	}
	if !strings.Contains(got, ".tekhton/BUILD_ROUTING_DIAGNOSIS.md") {
		t.Errorf("mixed_uncertain should reference the diagnosis path; got %q", got)
	}
	if !strings.HasPrefix(got, "## Routing Context (mixed_uncertain)") {
		t.Errorf("mixed_uncertain should open with the section header; got %q", got)
	}
	// unknown_only → non-empty low-confidence block
	got2 := ExtraContextFor(DecisionUnknownOnly, "")
	if got2 == "" {
		t.Fatalf("unknown_only should be non-empty")
	}
	if !strings.HasPrefix(got2, "## Routing Context (unknown_only)") {
		t.Errorf("unknown_only should open with the section header; got %q", got2)
	}
}

// TestExtraContextFor_MixedUncertainDefaultsPath confirms the
// empty-string diagnosisPath fallback to .tekhton/BUILD_ROUTING_DIAGNOSIS.md.
func TestExtraContextFor_MixedUncertainDefaultsPath(t *testing.T) {
	got := ExtraContextFor(DecisionMixedUncertain, "")
	if !strings.Contains(got, ".tekhton/BUILD_ROUTING_DIAGNOSIS.md") {
		t.Fatalf("empty diagnosisPath should default; got %q", got)
	}
}

// TestExportStats_KnownAndUnknownOutcomes covers the sanitization
// branch: unrecognized outcomes collapse to OutcomeNotRun.
func TestExportStats_KnownAndUnknownOutcomes(t *testing.T) {
	cases := []struct {
		in   Outcome
		want Outcome
	}{
		{OutcomePassed, OutcomePassed},
		{OutcomeExhausted, OutcomeExhausted},
		{OutcomeNoProgress, OutcomeNoProgress},
		{OutcomeNotRun, OutcomeNotRun},
		{"bogus", OutcomeNotRun},
		{"", OutcomeNotRun},
		{"PASSED", OutcomeNotRun}, // case-sensitive — bash compat
	}
	for _, c := range cases {
		s := Stats{Attempts: 7, TurnBudgetUsed: 99, ProgressGateFailures: 1}
		ExportStats(&s, c.in)
		if s.Outcome != c.want {
			t.Errorf("ExportStats(%q) outcome = %s, want %s", c.in, s.Outcome, c.want)
		}
		// Other fields preserved verbatim.
		if s.Attempts != 7 || s.TurnBudgetUsed != 99 || s.ProgressGateFailures != 1 {
			t.Errorf("ExportStats should not touch Attempts/TurnBudgetUsed/ProgressGateFailures; got %+v", s)
		}
	}
}

// TestExportStats_NilSafe defensive — the m39.3 loop might pass nil
// during partial-init paths and we don't want a panic.
func TestExportStats_NilSafe(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("ExportStats(nil, …) panicked: %v", r)
		}
	}()
	ExportStats(nil, OutcomePassed)
}

// TestSetSecondaryCause pins the four exact strings the bash helper
// exports. The m39.4 orchestrator reads these to populate the
// SECONDARY_ERROR_* env vars at the child-process boundary.
func TestSetSecondaryCause(t *testing.T) {
	var sc SecondaryCause
	SetSecondaryCause(&sc)
	want := SecondaryCause{
		Category:    "AGENT_SCOPE",
		Subcategory: "max_turns",
		Signal:      "build_fix_budget_exhausted",
		Source:      "coder_build_fix",
	}
	if sc != want {
		t.Fatalf("SetSecondaryCause produced %+v, want %+v", sc, want)
	}
}

// TestSetSecondaryCause_NilSafe defensive nil-check.
func TestSetSecondaryCause_NilSafe(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("SetSecondaryCause(nil) panicked: %v", r)
		}
	}()
	SetSecondaryCause(nil)
}
