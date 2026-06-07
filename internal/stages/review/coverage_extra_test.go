package review

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
	reviewparse "github.com/geoffgodwin/tekhton/internal/review"
)

// TestApprovedSkipResult_BuildsExpectedMetadata exercises the skip-path
// result builder so the skip-shape lands deterministically.
func TestApprovedSkipResult_BuildsExpectedMetadata(t *testing.T) {
	req := &proto.StageRequestV1{Stage: proto.StageReview}
	res := approvedSkipResult(req, "skipped_polish_mode", map[string]string{
		"reviewer_skipped": "true",
	})
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict=%q want pass", res.Verdict)
	}
	if res.NextAction != "approve" {
		t.Errorf("NextAction=%q want approve", res.NextAction)
	}
	if !strings.Contains(res.Error, "verdict=APPROVED_WITH_NOTES") {
		t.Errorf("Error blob missing verdict=APPROVED_WITH_NOTES:\n%s", res.Error)
	}
	if !strings.Contains(res.Error, "reviewer_skipped=true") {
		t.Errorf("Error blob missing reviewer_skipped=true:\n%s", res.Error)
	}
}

// TestReworkFailureResult_StuffsCauseAndCycle exercises the rework failure
// envelope builder directly.
func TestReworkFailureResult_StuffsCauseAndCycle(t *testing.T) {
	req := &proto.StageRequestV1{Stage: proto.StageReview}
	budget := &reviewparse.CycleBudget{Current: 2, Max: 3}
	cause := errors.New("build_failure_after_retry: exit 1")
	res := reworkFailureResult(req, budget, 3, cause)
	if res.Verdict != proto.VerdictFail {
		t.Errorf("Verdict=%q want fail", res.Verdict)
	}
	if res.ExitReason != "build_failure" {
		t.Errorf("ExitReason=%q want build_failure", res.ExitReason)
	}
	if !strings.Contains(res.Error, "rework_error=build_failure_after_retry") {
		t.Errorf("Error blob missing rework_error:\n%s", res.Error)
	}
	if !strings.Contains(res.Error, "cycles_done=2") {
		t.Errorf("Error blob missing cycles_done=2:\n%s", res.Error)
	}
}

// TestMergeMeta_LaterMapsOverride covers the two-arg precedence behavior.
func TestMergeMeta_LaterMapsOverride(t *testing.T) {
	merged := mergeMeta(
		map[string]string{"a": "1", "b": "2"},
		map[string]string{"b": "OVERRIDE", "c": "3"},
	)
	if merged["a"] != "1" {
		t.Errorf("a=%q want 1", merged["a"])
	}
	if merged["b"] != "OVERRIDE" {
		t.Errorf("b=%q want OVERRIDE", merged["b"])
	}
	if merged["c"] != "3" {
		t.Errorf("c=%q want 3", merged["c"])
	}
}

// TestEnvBool_AcceptsAndRejects covers the bool token table.
func TestEnvBool_AcceptsAndRejects(t *testing.T) {
	cases := []struct {
		in       string
		fallback bool
		want     bool
	}{
		{"1", false, true},
		{"true", false, true},
		{"yes", false, true},
		{"YES", false, true},
		{"0", true, false},
		{"false", true, false},
		{"FALSE", true, false},
		{"", true, false},
		{"banana", true, true},
		{"banana", false, false},
	}
	for _, tc := range cases {
		t.Setenv("X_BOOL", tc.in)
		if got := envBool("X_BOOL", tc.fallback); got != tc.want {
			t.Errorf("envBool(%q, fallback=%v)=%v want %v", tc.in, tc.fallback, got, tc.want)
		}
	}
	os.Unsetenv("X_BOOL_NOT_SET")
	if got := envBool("X_BOOL_NOT_SET", true); got != true {
		t.Errorf("unset fallback path failed")
	}
}

// TestEnvOr_FallbackPath covers the "env unset → fallback" path.
func TestEnvOr_FallbackPath(t *testing.T) {
	os.Unsetenv("X_STR")
	if got := envOr("X_STR", "fallback"); got != "fallback" {
		t.Errorf("envOr=%q want fallback", got)
	}
	t.Setenv("X_STR", "set")
	if got := envOr("X_STR", "fallback"); got != "set" {
		t.Errorf("envOr=%q want set", got)
	}
}

// TestSynthesizeMinimalReport_BodyByteParity asserts the synthesize-template
// matches the bash heredoc byte-for-byte.
func TestSynthesizeMinimalReport_BodyByteParity(t *testing.T) {
	dir := t.TempDir()
	reportPath := filepath.Join(dir, ".tekhton", "REVIEWER_REPORT.md")
	if err := os.MkdirAll(filepath.Dir(reportPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := synthesizeMinimalReport(reportPath, ".tekhton/REVIEWER_REPORT.md"); err != nil {
		t.Fatalf("synthesizeMinimalReport: %v", err)
	}
	got, err := os.ReadFile(reportPath)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	want := "## Verdict\nAPPROVED_WITH_NOTES\n\n" +
		"## Summary\n" +
		".tekhton/REVIEWER_REPORT.md was synthesized by the pipeline after the reviewer agent\n" +
		"failed to produce it. The reviewer may have encountered issues reading or\n" +
		"writing the report file. The tester should validate all changes thoroughly.\n\n" +
		"## Complex Blockers\n- None (reviewer did not report)\n\n" +
		"## Simple Blockers\n- None (reviewer did not report)\n\n" +
		"## Non-Blocking Notes\n- Reviewer agent did not produce a report — extra tester scrutiny recommended.\n"
	if string(got) != want {
		t.Errorf("synthesized body byte diff:\nwant:\n%s\ngot:\n%s", want, string(got))
	}
}

// TestTripCommitGate_WritesSentinel asserts the .final_check_result is
// written with the first reason intact.
func TestTripCommitGate_WritesSentinel(t *testing.T) {
	dir := t.TempDir()
	cfg := &config{ProjectDir: dir, TekhtonDir: ".tekhton"}
	if err := tripCommitGate(cfg, "reviewer_did_not_produce_report"); err != nil {
		t.Fatalf("trip: %v", err)
	}
	body, err := os.ReadFile(filepath.Join(dir, ".tekhton", ".final_check_result"))
	if err != nil {
		t.Fatalf("read sentinel: %v", err)
	}
	if !strings.Contains(string(body), "reviewer_did_not_produce_report") {
		t.Errorf("sentinel missing reason:\n%s", string(body))
	}

	// Second call must be idempotent — first reason wins.
	if err := tripCommitGate(cfg, "other_reason"); err != nil {
		t.Fatalf("second trip: %v", err)
	}
	body2, _ := os.ReadFile(filepath.Join(dir, ".tekhton", ".final_check_result"))
	if !strings.Contains(string(body2), "reviewer_did_not_produce_report") {
		t.Errorf("second trip overwrote first reason: %s", string(body2))
	}
	if strings.Contains(string(body2), "other_reason") {
		t.Errorf("second trip leaked second reason: %s", string(body2))
	}
}

// TestAbortReplan_DefaultReturnsAborted asserts the default replan stub.
func TestAbortReplan_DefaultReturnsAborted(t *testing.T) {
	d, err := abortReplan{}.Run(context.Background(), "/tmp", "/tmp/REVIEWER_REPORT.md")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if d != replanUserAborted {
		t.Errorf("decision=%v want replanUserAborted", d)
	}
}

// TestNoSpecialist_DefaultReturnsNoBlockers asserts the default specialist stub.
func TestNoSpecialist_DefaultReturnsNoBlockers(t *testing.T) {
	s, err := noSpecialist{}.Run(context.Background(), "/tmp")
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if s != "" {
		t.Errorf("blockers=%q want empty", s)
	}
}

// TestResolveTekhtonBin_NoMatch covers the "no binary found" path.
func TestResolveTekhtonBin_NoMatch(t *testing.T) {
	// Drop TEKHTON_BIN, TEKHTON_HOME, and PATH so the search fails.
	t.Setenv("TEKHTON_BIN", "/nonexistent/tekhton")
	t.Setenv("TEKHTON_HOME", "/nonexistent")
	t.Setenv("PATH", "/nonexistent")
	if got := resolveTekhtonBin(); got != "" {
		t.Errorf("resolveTekhtonBin=%q want empty", got)
	}
}
