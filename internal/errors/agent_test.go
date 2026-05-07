package errors_test

import (
	"strings"
	"testing"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

func TestClassifyAgent_Upstream(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name             string
		opts             terr.AgentClassifyOptions
		wantCat, wantSub string
		wantTransient    bool
	}{
		{
			name:          "rate_limit json",
			opts:          terr.AgentClassifyOptions{ExitCode: 1, Stderr: `{"type":"error","error":{"type":"rate_limit_error"}}`},
			wantCat:       "UPSTREAM",
			wantSub:       "api_rate_limit",
			wantTransient: true,
		},
		{
			name:          "overloaded json",
			opts:          terr.AgentClassifyOptions{ExitCode: 1, Stderr: `{"type":"error","error":{"type":"overloaded"}}`},
			wantCat:       "UPSTREAM",
			wantSub:       "api_overloaded",
			wantTransient: true,
		},
		{
			name:          "auth permanent",
			opts:          terr.AgentClassifyOptions{ExitCode: 1, Stderr: `{"type":"authentication_error"}`},
			wantCat:       "UPSTREAM",
			wantSub:       "api_auth",
			wantTransient: false,
		},
		{
			name:          "timeout transient",
			opts:          terr.AgentClassifyOptions{ExitCode: 1, Stderr: "ETIMEDOUT"},
			wantCat:       "UPSTREAM",
			wantSub:       "api_timeout",
			wantTransient: true,
		},
		{
			name:          "rate_limit text",
			opts:          terr.AgentClassifyOptions{ExitCode: 1, Stderr: "Got rate.limit response"},
			wantCat:       "UPSTREAM",
			wantSub:       "api_rate_limit",
			wantTransient: true,
		},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			got := terr.ClassifyAgent(tc.opts)
			if got.Category != tc.wantCat || got.Subcategory != tc.wantSub || got.Transient != tc.wantTransient {
				t.Fatalf("want %s|%s|%v, got %+v", tc.wantCat, tc.wantSub, tc.wantTransient, got)
			}
		})
	}
}

func TestClassifyAgent_Environment(t *testing.T) {
	t.Parallel()
	if got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 137}); got.Subcategory != "oom" {
		t.Errorf("oom: %+v", got)
	}
	if got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: "ENOSPC"}); got.Subcategory != "disk_full" {
		t.Errorf("disk_full: %+v", got)
	}
	if got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: "ENOTFOUND api.example.com"}); got.Subcategory != "network" {
		t.Errorf("network: %+v", got)
	}
	if got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: "command not found"}); got.Subcategory != "missing_dep" {
		t.Errorf("missing_dep: %+v", got)
	}
	if got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: "Permission denied"}); got.Subcategory != "permissions" {
		t.Errorf("permissions: %+v", got)
	}
}

func TestClassifyAgent_AgentScope(t *testing.T) {
	t.Parallel()
	// Activity timeout: turns=0 → null_activity_timeout
	got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 124, Turns: 0})
	if got.Subcategory != "null_activity_timeout" {
		t.Errorf("null_activity_timeout: %+v", got)
	}
	// Activity timeout: turns>0 → activity_timeout
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 124, Turns: 5})
	if got.Subcategory != "activity_timeout" {
		t.Errorf("activity_timeout: %+v", got)
	}
	// Null run
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Turns: 0, FileChanges: 0})
	if got.Subcategory != "null_run" {
		t.Errorf("null_run: %+v", got)
	}
	// Max turns
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Turns: 10, FileChanges: 5})
	if got.Subcategory != "max_turns" {
		t.Errorf("max_turns: %+v", got)
	}
	// No summary on success
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 0, Turns: 5, HasSummary: false})
	if got.Subcategory != "no_summary" {
		t.Errorf("no_summary: %+v", got)
	}
	// Scope unknown on clean success
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 0, Turns: 5, HasSummary: true})
	if got.Subcategory != "scope_unknown" {
		t.Errorf("scope_unknown: %+v", got)
	}
}

func TestClassifyAgent_Pipeline(t *testing.T) {
	t.Parallel()
	cases := []struct {
		stderr string
		want   string
	}{
		{"PIPELINE_STATE corrupt", "state_corrupt"},
		{"pipeline.conf REJECTED", "config_error"},
		{"render_prompt failure", "template_error"},
		{"Expected output file not found", "missing_file"},
	}
	for _, tc := range cases {
		got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: tc.stderr})
		if got.Subcategory != tc.want {
			t.Errorf("input=%q want=%s got=%+v", tc.stderr, tc.want, got)
		}
	}
}

func TestClassifyAgent_Fallback(t *testing.T) {
	t.Parallel()
	// SIGSEGV — needs turns/file_changes set so null_run does not fire first.
	got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 139, Turns: 1, FileChanges: 1})
	if got.Subcategory != "env_unknown" {
		t.Errorf("SIGSEGV: %+v", got)
	}
	// Anthropic hint with random exit and partial work — bypasses null_run/max_turns
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 7, Turns: 1, FileChanges: 1, Stderr: "claude binary failed"})
	if got.Subcategory != "api_unknown" {
		t.Errorf("anthropic hint: %+v", got)
	}
	// Generic — same precondition as anthropic hint case.
	got = terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 7, Turns: 1, FileChanges: 1, Stderr: "something unexpected"})
	if got.Subcategory != "internal" {
		t.Errorf("internal: %+v", got)
	}
}

func TestClassifyAgent_FormatLegacy(t *testing.T) {
	t.Parallel()
	got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 137})
	line := got.FormatLegacy()
	parts := strings.Split(line, "|")
	if len(parts) != 4 {
		t.Fatalf("legacy format expected 4 fields, got %d (%q)", len(parts), line)
	}
	if parts[2] != "true" {
		t.Errorf("transient field: %s", parts[2])
	}
}

func TestIsKnownAgentSubcategory(t *testing.T) {
	t.Parallel()
	known := []struct{ cat, sub string }{
		{"UPSTREAM", "api_rate_limit"},
		{"UPSTREAM", "api_overloaded"},
		{"UPSTREAM", "api_auth"},
		{"UPSTREAM", "api_500"},
		{"UPSTREAM", "api_timeout"},
		{"UPSTREAM", "api_unknown"},
		{"ENVIRONMENT", "disk_full"},
		{"ENVIRONMENT", "network"},
		{"ENVIRONMENT", "missing_dep"},
		{"ENVIRONMENT", "permissions"},
		{"ENVIRONMENT", "oom"},
		{"ENVIRONMENT", "env_unknown"},
		{"ENVIRONMENT", "env_setup"},
		{"ENVIRONMENT", "service_dep"},
		{"ENVIRONMENT", "toolchain"},
		{"ENVIRONMENT", "resource"},
		{"ENVIRONMENT", "test_infra"},
		{"AGENT_SCOPE", "null_run"},
		{"AGENT_SCOPE", "max_turns"},
		{"AGENT_SCOPE", "activity_timeout"},
		{"AGENT_SCOPE", "null_activity_timeout"},
		{"AGENT_SCOPE", "no_summary"},
		{"AGENT_SCOPE", "scope_unknown"},
		{"PIPELINE", "state_corrupt"},
		{"PIPELINE", "config_error"},
		{"PIPELINE", "missing_file"},
		{"PIPELINE", "template_error"},
		{"PIPELINE", "internal"},
	}
	for _, tc := range known {
		if !terr.IsKnownAgentSubcategory(tc.cat, tc.sub) {
			t.Errorf("IsKnownAgentSubcategory(%q, %q) = false, want true", tc.cat, tc.sub)
		}
	}
	unknown := []struct{ cat, sub string }{
		{"UPSTREAM", "bogus"},
		{"ENVIRONMENT", "nonexistent"},
		{"WHATEVER", "anything"},
		{"PIPELINE", ""},
	}
	for _, tc := range unknown {
		if terr.IsKnownAgentSubcategory(tc.cat, tc.sub) {
			t.Errorf("IsKnownAgentSubcategory(%q, %q) = true, want false", tc.cat, tc.sub)
		}
	}
}

func TestClassifyAgent_CapHeadTruncation(t *testing.T) {
	t.Parallel()
	// capHead caps at 65536 bytes. Provide 70000-byte stderr with a rate-limit
	// signal at byte 0 — truncation must not destroy the signal.
	longPrefix := "{"
	rate := `"type":"error"` + `,"error":{"type":"rate_limit_error"}}`
	// The signal is at the front, so capHead keeps it.
	big := longPrefix + rate + strings.Repeat("x", 70000)
	got := terr.ClassifyAgent(terr.AgentClassifyOptions{ExitCode: 1, Stderr: big})
	if got.Subcategory != "api_rate_limit" {
		t.Errorf("capHead truncation: rate-limit at front must survive, got %+v", got)
	}
}

func TestIsTransient(t *testing.T) {
	t.Parallel()
	cases := []struct {
		cat, sub string
		want     bool
	}{
		{"UPSTREAM", "api_rate_limit", true},
		{"UPSTREAM", "api_500", true},
		{"UPSTREAM", "api_auth", false},
		{"ENVIRONMENT", "network", true},
		{"ENVIRONMENT", "oom", true},
		{"ENVIRONMENT", "disk_full", false},
		{"ENVIRONMENT", "service_dep", false},
		{"AGENT_SCOPE", "null_run", false},
		{"PIPELINE", "state_corrupt", false},
		{"WHATEVER", "unknown", false},
	}
	for _, tc := range cases {
		if got := terr.IsTransient(tc.cat, tc.sub); got != tc.want {
			t.Errorf("%s/%s: want %v got %v", tc.cat, tc.sub, tc.want, got)
		}
	}
}
