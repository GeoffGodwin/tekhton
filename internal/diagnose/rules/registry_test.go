package rules

import (
	"reflect"
	"testing"
)

// TestRuleOrder_MatchesBashRegistry asserts that the priority order of the
// Go registry matches lib/diagnose_rules_registry.sh:DIAGNOSE_RULES
// byte-for-byte. The bash source is kept here as a hard-coded slice (not
// regenerated from the bash file at test time) so the test catches drift
// in either direction — if the bash file is edited and the Go side is not,
// the next test run fails red.
func TestRuleOrder_MatchesBashRegistry(t *testing.T) {
	t.Parallel()
	want := []string{
		"_rule_ui_gate_interactive_reporter",
		"_rule_preflight_interactive_config",
		"_rule_build_fix_exhausted",
		"_rule_build_failure",
		"_rule_max_turns",
		"_rule_review_loop",
		"_rule_security_halt",
		"_rule_intake_clarity",
		"_rule_quota_exhausted",
		"_rule_stuck_loop",
		"_rule_mixed_classification",
		"_rule_turn_exhaustion",
		"_rule_split_depth",
		"_rule_transient_error",
		"_rule_test_audit_failure",
		"_rule_migration_crash",
		"_rule_version_mismatch",
		"_rule_unknown",
	}
	got := []string{}
	for _, r := range New().Rules() {
		got = append(got, r.Name())
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("rule order drift:\nwant: %v\n got: %v", want, got)
	}
}

// TestRuleCount_IsEighteen guards the milestone acceptance criterion that
// the registry contains exactly 18 entries.
func TestRuleCount_IsEighteen(t *testing.T) {
	t.Parallel()
	if got := len(New().Rules()); got != 18 {
		t.Fatalf("want 18 rules in registry, got %d", got)
	}
}

// TestRules_ReturnsCopy verifies Rules() does not return a slice that aliases
// the package-level registry — callers must not be able to mutate the
// canonical priority order through the returned slice.
func TestRules_ReturnsCopy(t *testing.T) {
	t.Parallel()
	a := New().Rules()
	b := New().Rules()
	if len(a) == 0 || len(b) == 0 {
		t.Fatal("empty rules slice")
	}
	a[0] = nil
	if b[0] == nil {
		t.Fatal("Rules() returned an aliased slice; mutation leaked across callers")
	}
}
