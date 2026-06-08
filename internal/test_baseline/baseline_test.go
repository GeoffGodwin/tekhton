package test_baseline

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// --- Regression-canary -------------------------------------------------

// TestDefaultStuckPolicy_PassOnPreexistingIsFalse is the m38.5 regression
// canary. M92 flipped this default from true to false; the Go port MUST
// preserve the false default. If this test ever fails, do NOT change the
// expected value — fix DefaultStuckPolicy.
func TestDefaultStuckPolicy_PassOnPreexistingIsFalse(t *testing.T) {
	if DefaultStuckPolicy().PassOnPreexisting {
		t.Fatal("DefaultStuckPolicy().PassOnPreexisting = true, want false " +
			"(regression-canary — M92 flipped this from true to false to " +
			"prevent silent auto-skip of pre-existing failures)")
	}
}

func TestDefaultStuckPolicy_PassOnStuckIsFalse(t *testing.T) {
	if DefaultStuckPolicy().PassOnStuck {
		t.Fatal("DefaultStuckPolicy().PassOnStuck = true, want false")
	}
}

func TestDefaultStuckPolicy_ThresholdIs2(t *testing.T) {
	if got := DefaultStuckPolicy().Threshold; got != 2 {
		t.Fatalf("Threshold = %d, want 2", got)
	}
}

// --- Helper plumbing ---------------------------------------------------

func mkProjectDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	return dir
}

func seedBaseline(t *testing.T, projectDir string, bl *Baseline) {
	t.Helper()
	if err := writeBaselineJSON(bl, baselineJSONPath(projectDir)); err != nil {
		t.Fatal(err)
	}
}

// --- Capture ------------------------------------------------------------

func TestCapture_EmptyTestCmdReturnsNilBaseline(t *testing.T) {
	dir := mkProjectDir(t)
	bl, err := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    "",
	})
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if bl != nil {
		t.Fatalf("got baseline %+v, want nil for empty TestCmd", bl)
	}
}

func TestCapture_TrueTestCmdReturnsNilBaseline(t *testing.T) {
	dir := mkProjectDir(t)
	bl, _ := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    "true",
	})
	if bl != nil {
		t.Errorf("got baseline %+v, want nil for TestCmd=true", bl)
	}
}

func TestCapture_PassingTestCmdWritesCleanBaseline(t *testing.T) {
	dir := mkProjectDir(t)
	bl, err := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    `echo "1 passed" && exit 0`,
		Milestone:  "m38.5",
		RunID:      "20260607",
	})
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if bl == nil {
		t.Fatal("got nil baseline, want clean baseline")
	}
	if bl.ExitCode != 0 {
		t.Errorf("ExitCode = %d, want 0", bl.ExitCode)
	}
	if bl.FailureCount != 0 {
		t.Errorf("FailureCount = %d, want 0", bl.FailureCount)
	}
	if bl.Milestone != "m38.5" {
		t.Errorf("Milestone = %q, want m38.5", bl.Milestone)
	}
	if _, err := os.Stat(baselineJSONPath(dir)); err != nil {
		t.Errorf("TEST_BASELINE.json missing: %v", err)
	}
	if _, err := os.Stat(baselineOutputPath(dir)); err != nil {
		t.Errorf("TEST_BASELINE_OUTPUT.txt missing: %v", err)
	}
}

func TestCapture_FailingTestCmdCapturesFailureCount(t *testing.T) {
	dir := mkProjectDir(t)
	bl, err := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    `printf "FAIL test_a\nFAIL test_b\n" && exit 1`,
		Milestone:  "m38.5",
		RunID:      "20260607",
	})
	if err != nil {
		t.Fatalf("Capture: %v", err)
	}
	if bl == nil {
		t.Fatal("got nil baseline")
	}
	if bl.ExitCode != 1 {
		t.Errorf("ExitCode = %d, want 1", bl.ExitCode)
	}
	if bl.FailureCount < 2 {
		t.Errorf("FailureCount = %d, want >= 2", bl.FailureCount)
	}
	if bl.FailureHash == "" {
		t.Errorf("FailureHash is empty")
	}
}

func TestCapture_AtomicWrite_NoTmpRemains(t *testing.T) {
	dir := mkProjectDir(t)
	if _, err := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    "echo ok && exit 0",
		Milestone:  "m38.5",
		RunID:      "r1",
	}); err != nil {
		t.Fatal(err)
	}
	entries, err := os.ReadDir(filepath.Join(dir, ".claude"))
	if err != nil {
		t.Fatal(err)
	}
	for _, e := range entries {
		if strings.Contains(e.Name(), ".tmp") {
			t.Errorf(".tmp file left behind: %s (atomic-write violation)", e.Name())
		}
	}
}

func TestCapture_RequiresProjectDir(t *testing.T) {
	_, err := Capture(context.Background(), CaptureOptions{
		TestCmd: "echo x",
	})
	if err == nil {
		t.Fatal("expected error when ProjectDir is empty")
	}
}

func TestCapture_DefaultsRunIDAndMilestone(t *testing.T) {
	dir := mkProjectDir(t)
	bl, _ := Capture(context.Background(), CaptureOptions{
		ProjectDir: dir,
		TestCmd:    "echo ok",
	})
	if bl == nil {
		t.Fatal("got nil baseline")
	}
	if bl.RunID != "unknown" {
		t.Errorf("RunID = %q, want unknown", bl.RunID)
	}
	if bl.Milestone != "unknown" {
		t.Errorf("Milestone = %q, want unknown", bl.Milestone)
	}
}

// --- Has + ShouldCapture ------------------------------------------------

func TestHas_TrueWhenMilestoneMatches(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m38.5", RunID: "x"})
	if !Has("m38.5", dir) {
		t.Errorf("Has(m38.5) = false, want true")
	}
}

func TestHas_FalseWhenMilestoneDiffers(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m38.4", RunID: "x"})
	if Has("m38.5", dir) {
		t.Errorf("Has(m38.5) with m38.4 baseline = true, want false")
	}
}

func TestHas_FalseWhenNoFile(t *testing.T) {
	dir := mkProjectDir(t)
	if Has("m38.5", dir) {
		t.Errorf("Has(m38.5) with no file = true, want false")
	}
}

func TestShouldCapture_FalseWhenDisabled(t *testing.T) {
	dir := mkProjectDir(t)
	if ShouldCapture("m1", "r1", dir, false, "echo ok") {
		t.Errorf("disabled should return false")
	}
}

func TestShouldCapture_FalseWhenTestCmdEmpty(t *testing.T) {
	dir := mkProjectDir(t)
	if ShouldCapture("m1", "r1", dir, true, "") {
		t.Errorf("empty TestCmd should return false")
	}
	if ShouldCapture("m1", "r1", dir, true, "true") {
		t.Errorf("TestCmd=true should return false")
	}
}

func TestShouldCapture_TrueWhenNoBaseline(t *testing.T) {
	dir := mkProjectDir(t)
	if !ShouldCapture("m1", "r1", dir, true, "echo ok") {
		t.Errorf("no baseline should return true")
	}
}

func TestShouldCapture_FalseWhenSameRunSameMilestone(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m1", RunID: "r1"})
	if ShouldCapture("m1", "r1", dir, true, "echo ok") {
		t.Errorf("same run + same milestone should return false")
	}
}

func TestShouldCapture_TrueWhenDifferentRun(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m1", RunID: "r1"})
	if !ShouldCapture("m1", "r2", dir, true, "echo ok") {
		t.Errorf("different run should return true")
	}
}

func TestShouldCapture_TrueWhenRunIDMissingBackcompat(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m1", RunID: ""})
	if !ShouldCapture("m1", "r1", dir, true, "echo ok") {
		t.Errorf("missing run_id (pre-M63) should treat as stale")
	}
}

func TestShouldCapture_TrueWhenMilestoneDiffers(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{Milestone: "m1", RunID: "r1"})
	if !ShouldCapture("m2", "r1", dir, true, "echo ok") {
		t.Errorf("different milestone should return true")
	}
}

// --- Compare verdict table ---------------------------------------------

func TestCompare_NoBaselineReturnsInconclusive(t *testing.T) {
	dir := mkProjectDir(t)
	v, err := Compare("FAIL t1", 1, dir)
	if err != nil {
		t.Fatal(err)
	}
	if v != VerdictInconclusive {
		t.Errorf("got %s, want inconclusive", v)
	}
}

func TestCompare_CleanBaselineReturnsNewFailures(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{ExitCode: 0, FailureCount: 0})
	v, _ := Compare("FAIL t1\nFAIL t2", 1, dir)
	if v != VerdictNewFailures {
		t.Errorf("got %s, want new_failures (clean baseline → all failures new)", v)
	}
}

func TestCompare_MatchingHashReturnsPreExisting(t *testing.T) {
	dir := mkProjectDir(t)
	output := "FAIL test_a\nFAIL test_b\n"
	bl := &Baseline{
		ExitCode:     1,
		FailureCount: 2,
		FailureHash:  failureSignatureHash(output),
	}
	seedBaseline(t, dir, bl)
	v, _ := Compare(output, 1, dir)
	if v != VerdictPreExisting {
		t.Errorf("got %s, want pre_existing (hash match)", v)
	}
}

func TestCompare_MoreFailuresReturnsNewFailures(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{
		ExitCode:     1,
		FailureCount: 1,
		FailureHash:  "deadbeef",
	})
	v, _ := Compare("FAIL a\nFAIL b\nFAIL c", 1, dir)
	if v != VerdictNewFailures {
		t.Errorf("got %s, want new_failures (count grew)", v)
	}
}

func TestCompare_DifferentHashSameCountReturnsInconclusive(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{
		ExitCode:     1,
		FailureCount: 2,
		FailureHash:  "deadbeef",
	})
	v, _ := Compare("FAIL a\nFAIL b", 1, dir)
	if v != VerdictInconclusive {
		t.Errorf("got %s, want inconclusive (different hash, same count)", v)
	}
}

// --- Normalization ------------------------------------------------------

func TestNormalizeTestOutput_StripsAllPatterns(t *testing.T) {
	in := "\x1b[31mError\x1b[0m at 2026-06-07T14:23:45Z " +
		"in 5 seconds (took 3.14s, 42ms, 0.5 seconds) " +
		"pid 12345 addr=0xDEADBEEF"
	got := NormalizeTestOutput(in)
	for _, want := range []string{"TIMESTAMP", "N.NNs", "in N seconds", "Nms", "N.NN seconds", "pid NNN", "0xADDR"} {
		if !strings.Contains(got, want) {
			t.Errorf("normalized output missing %q; got %q", want, got)
		}
	}
	if strings.Contains(got, "\x1b[") {
		t.Errorf("ANSI not stripped; got %q", got)
	}
	if strings.Contains(got, "0xDEADBEEF") {
		t.Errorf("hex address not normalized; got %q", got)
	}
}

func TestNormalizeTestOutput_PreservesTestNames(t *testing.T) {
	in := "FAIL test_billing_total in 1.5s"
	got := NormalizeTestOutput(in)
	if !strings.Contains(got, "test_billing_total") {
		t.Errorf("test name lost: %q", got)
	}
}

func TestExtractFailureLines_Pytest(t *testing.T) {
	in := "===== FAILURES =====\nFAILED test_a\nFAILED test_b\nok"
	got := ExtractFailureLines(in)
	if len(got) < 2 {
		t.Errorf("expected at least 2 failure lines, got %v", got)
	}
}

func TestExtractFailureLines_GoTest(t *testing.T) {
	in := "--- FAIL: TestThing (0.01s)\n    file.go:5: bad\nFAIL\nFAIL\tcmd/x 0.02s"
	got := ExtractFailureLines(in)
	if len(got) < 2 {
		t.Errorf("expected go test failure lines, got %v", got)
	}
}

func TestExtractFailureLines_CleanOutput(t *testing.T) {
	in := "PASS\nok\tcmd/x 0.01s\nAll tests passed"
	got := ExtractFailureLines(in)
	if len(got) != 0 {
		t.Errorf("clean output should have no failure lines; got %v", got)
	}
}

// --- Acceptance output + stuck state machine ---------------------------

func TestSaveAndGetAcceptanceOutputHash_RoundTrips(t *testing.T) {
	dir := mkProjectDir(t)
	if err := SaveAcceptanceOutput("FAIL a\n", 1, dir); err != nil {
		t.Fatal(err)
	}
	hash, err := GetAcceptanceOutputHash(dir)
	if err != nil {
		t.Fatal(err)
	}
	if hash == "" {
		t.Errorf("empty hash after save")
	}
}

func TestGetAcceptanceOutputHash_EmptyWhenMissing(t *testing.T) {
	dir := mkProjectDir(t)
	hash, err := GetAcceptanceOutputHash(dir)
	if err != nil {
		t.Fatal(err)
	}
	if hash != "" {
		t.Errorf("missing file should return empty hash, got %q", hash)
	}
}

func TestCheckAcceptanceStuck_NotStuckOnFirstCall(t *testing.T) {
	dir := mkProjectDir(t)
	_ = SaveAcceptanceOutput("FAIL", 1, dir)
	state := &StuckState{}
	if got := CheckAcceptanceStuck(state, DefaultStuckPolicy(), dir); got != StuckResultNotStuck {
		t.Errorf("got %d, want NotStuck on first call", got)
	}
	if state.IdenticalCount != 1 {
		t.Errorf("IdenticalCount = %d, want 1", state.IdenticalCount)
	}
}

func TestCheckAcceptanceStuck_ExitOnSecondIdenticalWithDefaultPolicy(t *testing.T) {
	dir := mkProjectDir(t)
	_ = SaveAcceptanceOutput("FAIL", 1, dir)
	state := &StuckState{}
	_ = CheckAcceptanceStuck(state, DefaultStuckPolicy(), dir)
	got := CheckAcceptanceStuck(state, DefaultStuckPolicy(), dir)
	if got != StuckResultExit {
		t.Errorf("got %d, want Exit on second identical call", got)
	}
}

func TestCheckAcceptanceStuck_PassOnStuckTrueAndCleanBaseline_SafetyCheck(t *testing.T) {
	dir := mkProjectDir(t)
	_ = SaveAcceptanceOutput("FAIL", 1, dir)
	// Clean baseline — load-bearing safety check: PassOnStuck=true MUST
	// still refuse to auto-pass because clean baseline implies the
	// failures are regressions.
	seedBaseline(t, dir, &Baseline{ExitCode: 0})
	policy := DefaultStuckPolicy()
	policy.PassOnStuck = true
	state := &StuckState{}
	_ = CheckAcceptanceStuck(state, policy, dir)
	got := CheckAcceptanceStuck(state, policy, dir)
	if got != StuckResultNotStuck {
		t.Errorf("got %d, want NotStuck (safety check — clean baseline)", got)
	}
}

func TestCheckAcceptanceStuck_PassOnStuckTrueAndDirtyBaseline_AutoPasses(t *testing.T) {
	dir := mkProjectDir(t)
	_ = SaveAcceptanceOutput("FAIL", 1, dir)
	seedBaseline(t, dir, &Baseline{ExitCode: 1})
	policy := DefaultStuckPolicy()
	policy.PassOnStuck = true
	state := &StuckState{}
	_ = CheckAcceptanceStuck(state, policy, dir)
	got := CheckAcceptanceStuck(state, policy, dir)
	if got != StuckResultAutoPass {
		t.Errorf("got %d, want AutoPass (dirty baseline + PassOnStuck)", got)
	}
}

func TestCheckAcceptanceStuck_NilStateReturnsNotStuck(t *testing.T) {
	dir := mkProjectDir(t)
	_ = SaveAcceptanceOutput("FAIL", 1, dir)
	if got := CheckAcceptanceStuck(nil, DefaultStuckPolicy(), dir); got != StuckResultNotStuck {
		t.Errorf("nil state should return NotStuck, got %d", got)
	}
}

func TestCheckAcceptanceStuck_NoOutputReturnsNotStuck(t *testing.T) {
	dir := mkProjectDir(t)
	state := &StuckState{}
	if got := CheckAcceptanceStuck(state, DefaultStuckPolicy(), dir); got != StuckResultNotStuck {
		t.Errorf("no saved output should return NotStuck, got %d", got)
	}
}

func TestCheckAcceptanceStuck_DifferentOutputResetsCount(t *testing.T) {
	dir := mkProjectDir(t)
	state := &StuckState{LastHash: "x", IdenticalCount: 5}
	_ = SaveAcceptanceOutput("FAIL a", 1, dir)
	_ = CheckAcceptanceStuck(state, DefaultStuckPolicy(), dir)
	if state.IdenticalCount != 1 {
		t.Errorf("count should reset to 1 on different hash; got %d", state.IdenticalCount)
	}
}

// --- GetBaselineExitCode ------------------------------------------------

func TestGetBaselineExitCode_EmptyWhenMissing(t *testing.T) {
	dir := mkProjectDir(t)
	if got := GetBaselineExitCode(dir); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

func TestGetBaselineExitCode_ReturnsNumber(t *testing.T) {
	dir := mkProjectDir(t)
	seedBaseline(t, dir, &Baseline{ExitCode: 7})
	if got := GetBaselineExitCode(dir); got != "7" {
		t.Errorf("got %q, want 7", got)
	}
}

// --- Verdict string ----------------------------------------------------

func TestVerdictString(t *testing.T) {
	cases := []struct {
		v    Verdict
		want string
	}{
		{VerdictInconclusive, "inconclusive"},
		{VerdictPreExisting, "pre_existing"},
		{VerdictNewFailures, "new_failures"},
	}
	for _, tc := range cases {
		if got := tc.v.String(); got != tc.want {
			t.Errorf("Verdict(%d).String() = %q, want %q", tc.v, got, tc.want)
		}
	}
}

// --- JSON field order parity -------------------------------------------

// TestBaselineJSON_FieldOrder pins the on-disk field order. encoding/json
// honors struct declaration order, so a Baseline field reorder would be
// caught here. The bash printf emitted fields in: run_id, timestamp,
// milestone, exit_code, output_hash, failure_hash, failure_count.
func TestBaselineJSON_FieldOrder(t *testing.T) {
	dir := mkProjectDir(t)
	bl := &Baseline{
		RunID: "r", Milestone: "m", ExitCode: 1,
		OutputHash: "o", FailureHash: "f", FailureCount: 2,
	}
	if err := writeBaselineJSON(bl, baselineJSONPath(dir)); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(baselineJSONPath(dir))
	want := []string{"run_id", "timestamp", "milestone", "exit_code", "output_hash", "failure_hash", "failure_count"}
	pos := -1
	for _, k := range want {
		idx := strings.Index(string(data), `"`+k+`"`)
		if idx < 0 {
			t.Fatalf("field %q missing from JSON: %s", k, data)
		}
		if idx <= pos {
			t.Fatalf("field order broken at %q (idx=%d, prev=%d) — bash compat requires run_id,timestamp,milestone,exit_code,output_hash,failure_hash,failure_count", k, idx, pos)
		}
		pos = idx
	}
}

// --- SetCausalEmitter ---------------------------------------------------

func TestSetCausalEmitter_NilLeavesPriorEmitter(t *testing.T) {
	prev := SetCausalEmitter(nil)
	if prev == nil {
		t.Fatal("expected previous emitter to be non-nil")
	}
	SetCausalEmitter(prev) // restore
}

// --- Fixture-driven parity ---------------------------------------------

func TestNormalizeAndExtract_PytestFailFixture(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "pytest_fail.txt"))
	if err != nil {
		t.Fatal(err)
	}
	in := string(data)
	got := ExtractFailureLines(NormalizeTestOutput(in))
	if len(got) < 3 {
		t.Errorf("pytest fail fixture: got %d failure lines, want >= 3", len(got))
	}
}

func TestNormalizeAndExtract_PytestPassFixture(t *testing.T) {
	data, _ := os.ReadFile(filepath.Join("testdata", "pytest_pass.txt"))
	got := ExtractFailureLines(NormalizeTestOutput(string(data)))
	if len(got) != 0 {
		t.Errorf("pytest pass fixture should have zero failures; got %v", got)
	}
}

func TestNormalizeAndExtract_JestFailFixture(t *testing.T) {
	data, _ := os.ReadFile(filepath.Join("testdata", "jest_fail.txt"))
	got := ExtractFailureLines(NormalizeTestOutput(string(data)))
	if len(got) == 0 {
		t.Errorf("jest fail fixture should have failure lines")
	}
}

func TestNormalizeAndExtract_HexAddrsFixture(t *testing.T) {
	data, _ := os.ReadFile(filepath.Join("testdata", "hex_addrs.txt"))
	got := NormalizeTestOutput(string(data))
	if strings.Contains(got, "0xDEADBEEF") || strings.Contains(got, "0xFFFFAA00") {
		t.Errorf("hex addresses not normalized; got %q", got)
	}
	if !strings.Contains(got, "0xADDR") {
		t.Errorf("hex address placeholder missing; got %q", got)
	}
	if !strings.Contains(got, "pid NNN") {
		t.Errorf("pid normalization missing; got %q", got)
	}
	if !strings.Contains(got, "TIMESTAMP") {
		t.Errorf("timestamp normalization missing; got %q", got)
	}
}

// --- baseline JSON readability sanity ---------------------------------

func TestReadBaseline_ParsesEmittedFile(t *testing.T) {
	dir := mkProjectDir(t)
	in := &Baseline{
		RunID: "r1", Milestone: "m1", ExitCode: 3,
		OutputHash: "abc", FailureHash: "def", FailureCount: 5,
	}
	if err := writeBaselineJSON(in, baselineJSONPath(dir)); err != nil {
		t.Fatal(err)
	}
	out, err := readBaseline(dir)
	if err != nil {
		t.Fatal(err)
	}
	if out == nil {
		t.Fatal("nil baseline")
	}
	if out.ExitCode != 3 || out.FailureCount != 5 || out.RunID != "r1" {
		t.Errorf("round-trip mismatch: %+v", out)
	}
}

func TestReadBaseline_CorruptJSONReturnsError(t *testing.T) {
	dir := mkProjectDir(t)
	if err := os.WriteFile(baselineJSONPath(dir), []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := readBaseline(dir); err == nil {
		t.Errorf("expected error for corrupt JSON")
	}
}

// --- JSON roundtrip used by emit-event payloads sanity check ----------

func TestJSONEmittedShape_RunIDStringField(t *testing.T) {
	bl := &Baseline{RunID: "20260607", Milestone: "m"}
	var raw map[string]any
	body, err := json.Marshal(bl)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(body, &raw); err != nil {
		t.Fatal(err)
	}
	if _, ok := raw["run_id"].(string); !ok {
		t.Errorf("run_id must be a string; got %T", raw["run_id"])
	}
}
