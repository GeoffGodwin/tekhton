package preflight

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestIsNoopCommand asserts the canonical no-op recognition set. This is the
// Go-side mirror of bash _is_noop_test_cmd in
// lib/hooks_final_checks_helpers.sh — both must agree byte-for-byte on what
// counts as no-op.
func TestIsNoopCommand(t *testing.T) {
	for _, s := range []string{"", "true", "/bin/true", "/usr/bin/true", ":", "  true  ", "\t:"} {
		if !IsNoopCommand(s) {
			t.Errorf("IsNoopCommand(%q) = false; want true", s)
		}
	}
	for _, s := range []string{"pytest", "npm test", "cargo test", "go test ./...", "bash tests/run_tests.sh", "true && false"} {
		if IsNoopCommand(s) {
			t.Errorf("IsNoopCommand(%q) = true; want false", s)
		}
	}
}

// TestTestCmdCheck_Skipped_OutsideMilestoneMode covers Acceptance Criterion
// scope: the no-op TEST_CMD warning is only emitted when MILESTONE_MODE=true.
// Outside milestone mode the configured value has no acceptance-gate weight,
// so warning would be noise.
func TestTestCmdCheck_Skipped_OutsideMilestoneMode(t *testing.T) {
	// Input.Getenv falls back to os.Getenv when the key isn't in the per-test
	// map. When the parent invocation is itself a tekhton milestone run the
	// dev shell has MILESTONE_MODE=true exported; scrub it so this test
	// observes the empty-mode branch.
	t.Setenv("MILESTONE_MODE", "")
	in := &Input{
		ProjectDir: t.TempDir(),
		Env:        map[string]string{"TEST_CMD": "true"},
	}
	r := (TestCmdCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings outside milestone mode; got %+v", r.Findings)
	}
}

// TestTestCmdCheck_Skipped_RealCommand covers the happy path: a real
// TEST_CMD in milestone mode produces no finding.
func TestTestCmdCheck_Skipped_RealCommand(t *testing.T) {
	in := &Input{
		ProjectDir: t.TempDir(),
		Env: map[string]string{
			"MILESTONE_MODE": "true",
			"TEST_CMD":       "cargo test",
		},
	}
	r := (TestCmdCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 0 {
		t.Errorf("expected no findings for real TEST_CMD; got %+v", r.Findings)
	}
}

// TestTestCmdCheck_Warn_NoopInMilestoneMode is the default-disposition
// acceptance criterion #1: TEST_CMD="true" in MILESTONE_MODE produces a
// preflight warning and a HUMAN_ACTION_REQUIRED entry.
func TestTestCmdCheck_Warn_NoopInMilestoneMode(t *testing.T) {
	proj := t.TempDir()
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"MILESTONE_MODE": "true",
			"TEST_CMD":       "true",
		},
	}
	r := (TestCmdCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 1 {
		t.Fatalf("expected 1 finding; got %d (%+v)", len(r.Findings), r.Findings)
	}
	if r.Findings[0].Status != StatusWarn {
		t.Errorf("expected StatusWarn; got %v", r.Findings[0].Status)
	}
	if !strings.Contains(r.Findings[0].Detail, "no-op") {
		t.Errorf("expected detail to mention no-op; got %q", r.Findings[0].Detail)
	}

	// HUMAN_ACTION_REQUIRED.md should contain the action line.
	haPath := filepath.Join(proj, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	content, err := os.ReadFile(haPath)
	if err != nil {
		t.Fatalf("HUMAN_ACTION_REQUIRED.md not written: %v", err)
	}
	if !strings.Contains(string(content), "TEST_CMD is a no-op") {
		t.Errorf("HUMAN_ACTION_REQUIRED.md missing TEST_CMD no-op line; got: %s", content)
	}
	if !strings.Contains(string(content), "Source: preflight") {
		t.Errorf("HUMAN_ACTION_REQUIRED.md missing preflight source label; got: %s", content)
	}
}

// TestTestCmdCheck_Fail_RequireRealTestCmd is acceptance criterion #5:
// REQUIRE_REAL_TEST_CMD=true escalates the warning to a hard fail.
func TestTestCmdCheck_Fail_RequireRealTestCmd(t *testing.T) {
	proj := t.TempDir()
	in := &Input{
		ProjectDir: proj,
		Env: map[string]string{
			"MILESTONE_MODE":        "true",
			"TEST_CMD":              ":",
			"REQUIRE_REAL_TEST_CMD": "true",
		},
	}
	r := (TestCmdCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 1 {
		t.Fatalf("expected 1 finding; got %d", len(r.Findings))
	}
	if r.Findings[0].Status != StatusFail {
		t.Errorf("expected StatusFail with REQUIRE_REAL_TEST_CMD=true; got %v", r.Findings[0].Status)
	}
	if !strings.Contains(r.Findings[0].Detail, "REQUIRE_REAL_TEST_CMD") {
		t.Errorf("expected detail to name REQUIRE_REAL_TEST_CMD; got %q", r.Findings[0].Detail)
	}
}

// TestTestCmdCheck_Warn_UnsetCounts asserts that an entirely-unset TEST_CMD
// counts as a no-op (because `${TEST_CMD:-true}` runs `true` at the gate).
func TestTestCmdCheck_Warn_UnsetCounts(t *testing.T) {
	// Scrub any TEST_CMD leak from the parent shell so the in.Getenv
	// fallback returns the empty string, mirroring the unset-in-pipeline.conf
	// scenario the milestone is guarding against.
	t.Setenv("TEST_CMD", "")
	proj := t.TempDir()
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"MILESTONE_MODE": "true"}, // no TEST_CMD
	}
	r := (TestCmdCheck{}).Run(context.Background(), in)
	if len(r.Findings) != 1 {
		t.Fatalf("expected 1 finding for unset TEST_CMD; got %d", len(r.Findings))
	}
	if !strings.Contains(r.Findings[0].Detail, "<unset>") {
		t.Errorf("expected detail to show <unset> placeholder; got %q", r.Findings[0].Detail)
	}
}

// TestResolveHumanActionPath_Defaults exercises the path fallback.
func TestResolveHumanActionPath_Defaults(t *testing.T) {
	proj := t.TempDir()
	in := &Input{ProjectDir: proj}
	got := resolveHumanActionPath(in)
	want := filepath.Join(proj, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	if got != want {
		t.Errorf("default path: want %q, got %q", want, got)
	}
}

// TestResolveHumanActionPath_HonorsOverride asserts HUMAN_ACTION_FILE wins.
func TestResolveHumanActionPath_HonorsOverride(t *testing.T) {
	proj := t.TempDir()
	in := &Input{
		ProjectDir: proj,
		Env:        map[string]string{"HUMAN_ACTION_FILE": "custom/dir/ACTION.md"},
	}
	got := resolveHumanActionPath(in)
	want := filepath.Join(proj, "custom", "dir", "ACTION.md")
	if got != want {
		t.Errorf("override path: want %q, got %q", want, got)
	}
}
