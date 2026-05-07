package errors_test

import (
	"strings"
	"testing"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

func TestSuggestRecovery_KnownPairs(t *testing.T) {
	t.Parallel()
	cases := []struct {
		cat, sub, contains string
	}{
		{"UPSTREAM", "api_500", "Anthropic API server error"},
		{"UPSTREAM", "api_rate_limit", "rate limit"},
		{"UPSTREAM", "api_overloaded", "overloaded"},
		{"UPSTREAM", "api_auth", "ANTHROPIC_API_KEY"},
		{"UPSTREAM", "api_timeout", "network connection"},
		{"ENVIRONMENT", "oom", "OOM"},
		{"ENVIRONMENT", "disk_full", "Free up space"},
		{"ENVIRONMENT", "env_setup", "Missing tool"},
		{"AGENT_SCOPE", "null_run", "Agent died"},
		{"AGENT_SCOPE", "max_turns", "turn budget"},
		{"AGENT_SCOPE", "null_activity_timeout", "quota refresh"},
		{"PIPELINE", "config_error", "pipeline.conf"},
		{"PIPELINE", "template_error", "template"},
	}
	for _, tc := range cases {
		got := terr.SuggestRecovery(tc.cat, tc.sub, "")
		if !strings.Contains(got, tc.contains) {
			t.Errorf("%s/%s: want recovery containing %q, got %q", tc.cat, tc.sub, tc.contains, got)
		}
	}
}

func TestSuggestRecovery_StateCorruptUsesContext(t *testing.T) {
	t.Parallel()
	got := terr.SuggestRecovery("PIPELINE", "state_corrupt", "/tmp/PIPELINE_STATE.md")
	if !strings.Contains(got, "/tmp/PIPELINE_STATE.md") {
		t.Errorf("context not interpolated: %q", got)
	}
	got = terr.SuggestRecovery("PIPELINE", "state_corrupt", "")
	if !strings.Contains(got, ".claude/PIPELINE_STATE.md") {
		t.Errorf("default state path not used: %q", got)
	}
}

func TestSuggestRecovery_Unknown(t *testing.T) {
	t.Parallel()
	got := terr.SuggestRecovery("WHATEVER", "unknown", "")
	if got == "" {
		t.Fatal("recovery for unknown should not be empty")
	}
}

func TestSuggestRecovery_RemainingPairs(t *testing.T) {
	t.Parallel()
	// Covers all pairs not exercised by TestSuggestRecovery_KnownPairs.
	cases := []struct {
		cat, sub, contains string
	}{
		{"UPSTREAM", "api_unknown", "Anthropic status"},
		{"ENVIRONMENT", "network", "internet connection"},
		{"ENVIRONMENT", "missing_dep", "missing dependency"},
		{"ENVIRONMENT", "permissions", "Permission denied"},
		{"ENVIRONMENT", "env_unknown", "environment error"},
		{"ENVIRONMENT", "service_dep", "service"},
		{"ENVIRONMENT", "toolchain", "toolchain"},
		{"ENVIRONMENT", "resource", "resource"},
		{"ENVIRONMENT", "test_infra", "test"},
		{"AGENT_SCOPE", "activity_timeout", "AGENT_ACTIVITY_TIMEOUT"},
		{"AGENT_SCOPE", "no_summary", "Re-run"},
		{"AGENT_SCOPE", "scope_unknown", "run log"},
		{"PIPELINE", "missing_file", "artifact"},
		{"PIPELINE", "internal", "run log"},
	}
	for _, tc := range cases {
		got := terr.SuggestRecovery(tc.cat, tc.sub, "")
		if !strings.Contains(got, tc.contains) {
			t.Errorf("%s/%s: want recovery containing %q, got %q", tc.cat, tc.sub, tc.contains, got)
		}
	}
}
