package preflight

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCheckOrder_MatchesRegistration is the order-mismatch guard the m22
// milestone requires (acceptance criterion #1). Adding or reordering
// checks requires updating both the canonical list here and the
// checkOrder slice in orchestrator.go; this test fails red if they drift.
func TestCheckOrder_MatchesRegistration(t *testing.T) {
	expected := []string{
		"foundation",
		"ui_audit",
		"env",
		"services_infer",
		"services",
	}
	got := CheckOrder()
	if len(got) != len(expected) {
		t.Fatalf("expected %d checks; got %d", len(expected), len(got))
	}
	for i := range expected {
		if got[i] != expected[i] {
			t.Errorf("checkOrder[%d]: expected %q, got %q (order drift)", i, expected[i], got[i])
		}
	}
}

// TestNewOrchestrator_BuildsAllFiveChecks asserts the production
// constructor registers exactly five checks in checkOrder.
func TestNewOrchestrator_BuildsAllFiveChecks(t *testing.T) {
	o := NewOrchestrator("/tmp/tekhton", "/tmp/project")
	if len(o.Checks) != 5 {
		t.Errorf("NewOrchestrator must register 5 checks; got %d", len(o.Checks))
	}
	for i, name := range CheckOrder() {
		if o.Checks[i].Name() != name {
			t.Errorf("checks[%d]: orchestrator built %q, registry says %q",
				i, o.Checks[i].Name(), name)
		}
	}
}

// TestOrchestratorRun_NoApplicableChecks_NoReport verifies the bash
// behavior: when no check produces a finding, the orchestrator skips the
// report entirely and returns ("", nil).
func TestOrchestratorRun_NoApplicableChecks_NoReport(t *testing.T) {
	proj := t.TempDir()
	// Clear pipeline-config envs that could leak from the dev shell.
	for _, k := range []string{"ANALYZE_CMD", "BUILD_CHECK_CMD", "TEST_CMD", "UI_TEST_CMD"} {
		t.Setenv(k, "")
	}
	o := NewOrchestrator("/tmp/tekhton", proj)
	o.Now = fixedTime
	path, err := o.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if path != "" {
		t.Errorf("expected empty path when no checks applicable; got %q", path)
	}
}

// TestOrchestratorRun_WritesReport_WithFindings checks the happy path:
// at least one check returns a finding → report is written under
// .tekhton/PREFLIGHT_REPORT.md with the expected header lines.
func TestOrchestratorRun_WritesReport_WithFindings(t *testing.T) {
	proj := t.TempDir()
	// Trigger Foundation (Go deps) → one pass finding.
	if err := os.WriteFile(filepath.Join(proj, "go.mod"), []byte("module x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, "go.sum"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	o := NewOrchestrator("/tmp/tekhton", proj)
	o.Now = fixedTime
	path, err := o.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if path == "" {
		t.Fatal("expected report path; got empty")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read report: %v", err)
	}
	report := string(body)
	for _, want := range []string{
		"# Pre-flight Report — 2026-05-18 12:34:56",
		"## Summary",
		"## Checks",
		"### ✓ Dependencies (Go)",
		"go.sum exists.",
	} {
		if !strings.Contains(report, want) {
			t.Errorf("report missing %q\n---\n%s", want, report)
		}
	}
}

// TestOrchestratorHasBlockers verifies the gate the runner relies on.
// A fail finding flips HasBlockers; a warn alone does not unless
// PREFLIGHT_FAIL_ON_WARN is set.
func TestOrchestratorHasBlockers(t *testing.T) {
	cases := []struct {
		name        string
		findings    []Finding
		failOnWarn  bool
		wantBlocker bool
	}{
		{"only pass", []Finding{pass("x", "ok")}, false, false},
		{"warn alone", []Finding{warn("x", "soft")}, false, false},
		{"warn with fail-on-warn", []Finding{warn("x", "soft")}, true, true},
		{"fail", []Finding{failF("x", "hard")}, false, true},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if tc.failOnWarn {
				t.Setenv("PREFLIGHT_FAIL_ON_WARN", "true")
			} else {
				t.Setenv("PREFLIGHT_FAIL_ON_WARN", "")
			}
			o := NewOrchestrator("/tmp/home", t.TempDir())
			for _, f := range tc.findings {
				o.recordResult(Result{Findings: []Finding{f}})
			}
			if got := o.HasBlockers(); got != tc.wantBlocker {
				t.Errorf("HasBlockers() = %v, want %v", got, tc.wantBlocker)
			}
		})
	}
}

// TestOrchestratorRun_RespectsDisabled verifies the PREFLIGHT_ENABLED
// gate — when false, Run is a no-op.
func TestOrchestratorRun_RespectsDisabled(t *testing.T) {
	t.Setenv("PREFLIGHT_ENABLED", "false")
	o := NewOrchestrator("/tmp/home", t.TempDir())
	path, err := o.Run(context.Background())
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if path != "" {
		t.Errorf("expected empty path when disabled; got %q", path)
	}
}

func fixedTime() time.Time {
	return time.Date(2026, 5, 18, 12, 34, 56, 0, time.UTC)
}
