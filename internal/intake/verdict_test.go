package intake

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func newTestVerdict(t *testing.T) *VerdictHandler {
	t.Helper()
	h := newTestHelpers(t)
	pinTimestamp(t, "2026-06-04 12:34:56")
	return &VerdictHandler{
		H:               h,
		SizeGuardMinPct: 50,
		Stdout:          &bytes.Buffer{},
		Stderr:          &bytes.Buffer{},
	}
}

func TestRejectionMessageByteIdentity(t *testing.T) {
	v := newTestVerdict(t)
	v.ConfirmTweaks = true
	v.MilestoneMode = true
	v.CurrentMs = "m99.9"
	v.Task = "original-task"
	v.Stdin = strings.NewReader("n\n")
	v.IsStdinTTY = true

	var captured []string
	v.PipelineState = func(stage, exitReason, args, task, msg, ms string) error {
		captured = append(captured,
			stage, exitReason, args, task, msg, ms)
		return nil
	}

	err := v.HandleTweaked(context.Background(), "testdata/report_tweaked.md")
	if !errors.Is(err, ErrHalt) {
		t.Fatalf("expected ErrHalt, got %v", err)
	}

	stderr := v.Stderr.(*bytes.Buffer).String()
	if !strings.Contains(stderr, "Tweaks rejected by user. Saving state.") {
		t.Fatalf("rejection message missing byte-for-byte; stderr:\n%s", stderr)
	}
	// PipelineState should have been invoked with the exact bash-format
	// exit reason and message — task and milestone propagated through.
	want := []string{
		"intake", "tweaks_rejected", "--milestone --start-at coder",
		"original-task",
		"Intake tweaks rejected — edit milestone and re-run",
		"m99.9",
	}
	if len(captured) != len(want) {
		t.Fatalf("PipelineState fired with %d args, want %d (%v)", len(captured), len(want), captured)
	}
	for i, w := range want {
		if captured[i] != w {
			t.Errorf("PipelineState arg %d = %q, want %q", i, captured[i], w)
		}
	}
}

func TestTweakedAcceptedNonInteractive(t *testing.T) {
	v := newTestVerdict(t)
	v.ConfirmTweaks = false
	if err := v.HandleTweaked(context.Background(), "testdata/report_tweaked.md"); err != nil {
		t.Fatalf("HandleTweaked: %v", err)
	}
	if !strings.Contains(v.Stderr.(*bytes.Buffer).String(), "Intake: tweaks applied. Proceeding.") {
		t.Errorf("missing proceeding message")
	}
}

func TestClarificationsFileFormat(t *testing.T) {
	v := newTestVerdict(t)
	// Configure ClarifyHandle to no-op so the test does not exec.
	v.ClarifyHandle = func(_ context.Context, _, _ string) error { return nil }

	err := v.HandleNeedsClarity(context.Background(), "testdata/report_needs_clarity.md")
	if err != nil {
		t.Fatalf("HandleNeedsClarity: %v", err)
	}

	clarPath := filepath.Join(v.H.ProjectDir, v.H.ClarificationsFile)
	got, err := os.ReadFile(clarPath)
	if err != nil {
		t.Fatalf("CLARIFICATIONS.md not written: %v", err)
	}

	golden, err := os.ReadFile("testdata/clarifications_golden.md")
	if err != nil {
		t.Fatal(err)
	}

	// The golden file uses TIMESTAMP as a placeholder so the
	// pin-timestamp + regex-normalize approach gives a stable
	// byte-for-byte comparison.
	normalized := regexp.MustCompile(`# Intake Clarifications — [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}`).
		ReplaceAllString(string(got), "# Intake Clarifications — TIMESTAMP")
	if normalized != string(golden) {
		t.Errorf("CLARIFICATIONS.md does not match golden;\n--- got ---\n%s\n--- want ---\n%s", normalized, string(golden))
	}
}

func TestNeedsClarityCompleteMode(t *testing.T) {
	v := newTestVerdict(t)
	v.CompleteMode = true
	called := false
	v.ClarifyHandle = func(_ context.Context, _, _ string) error {
		called = true
		return nil
	}
	stateCalls := 0
	var lastReason string
	v.PipelineState = func(_, exitReason, _, _, msg, _ string) error {
		stateCalls++
		_ = exitReason
		lastReason = msg
		return nil
	}

	err := v.HandleNeedsClarity(context.Background(), "testdata/report_needs_clarity.md")
	if !errors.Is(err, ErrHalt) {
		t.Fatalf("expected ErrHalt, got %v", err)
	}
	if called {
		t.Errorf("ClarifyHandle invoked under CompleteMode — must not happen")
	}
	if stateCalls != 1 {
		t.Errorf("PipelineState calls = %d, want 1", stateCalls)
	}
	if !strings.Contains(lastReason, "Intake needs human clarification — answer") {
		t.Errorf("reason format incorrect: %q", lastReason)
	}
	stderr := v.Stderr.(*bytes.Buffer).String()
	if !strings.Contains(stderr, "Cannot collect answers in --complete mode (autonomous). Saving state.") {
		t.Errorf("missing complete-mode halt message; stderr:\n%s", stderr)
	}
}

func TestSplitRecommendedAutoSplit(t *testing.T) {
	v := newTestVerdict(t)
	v.AutoSplit = true
	v.MilestoneMode = true
	v.CurrentMs = "m99.9"
	splitCalls, switchCalls := 0, 0
	v.Split = func(ms, _ string) error {
		splitCalls++
		if ms != "m99.9" {
			t.Errorf("Split called with %q, want m99.9", ms)
		}
		return nil
	}
	v.Switch = func(ms, _ string) error {
		switchCalls++
		return nil
	}
	if err := v.HandleSplitRecommended(context.Background(), "testdata/report_split.md"); err != nil {
		t.Fatalf("HandleSplitRecommended: %v", err)
	}
	if splitCalls != 1 {
		t.Errorf("Split calls = %d, want 1", splitCalls)
	}
	if switchCalls != 1 {
		t.Errorf("Switch calls = %d, want 1", switchCalls)
	}
}

func TestSplitRecommendedInteractive_S(t *testing.T) {
	v := newTestVerdict(t)
	v.MilestoneMode = true
	v.CurrentMs = "m1"
	v.Stdin = strings.NewReader("s\n")
	v.IsStdinTTY = true
	splitCalls := 0
	v.Split = func(_, _ string) error { splitCalls++; return nil }
	v.Switch = func(_, _ string) error { return nil }
	if err := v.HandleSplitRecommended(context.Background(), "testdata/report_split.md"); err != nil {
		t.Fatalf("HandleSplitRecommended: %v", err)
	}
	if splitCalls != 1 {
		t.Errorf("Split calls = %d, want 1", splitCalls)
	}
}

func TestSplitRecommendedInteractive_C(t *testing.T) {
	v := newTestVerdict(t)
	v.Stdin = strings.NewReader("c\n")
	v.IsStdinTTY = true
	called := false
	v.Split = func(_, _ string) error { called = true; return nil }
	if err := v.HandleSplitRecommended(context.Background(), "testdata/report_split.md"); err != nil {
		t.Fatal(err)
	}
	if called {
		t.Errorf("Split should not fire on 'c'")
	}
	if !strings.Contains(v.Stderr.(*bytes.Buffer).String(), "Continuing without split.") {
		t.Errorf("missing continue message")
	}
}

func TestSplitRecommendedInteractive_Q(t *testing.T) {
	v := newTestVerdict(t)
	v.Stdin = strings.NewReader("q\n")
	v.IsStdinTTY = true
	stateCalls := 0
	var lastExit string
	v.PipelineState = func(_, exitReason, _, _, _, _ string) error {
		stateCalls++
		lastExit = exitReason
		return nil
	}
	err := v.HandleSplitRecommended(context.Background(), "testdata/report_split.md")
	if !errors.Is(err, ErrHalt) {
		t.Fatalf("expected ErrHalt, got %v", err)
	}
	if stateCalls != 1 {
		t.Errorf("PipelineState calls = %d, want 1", stateCalls)
	}
	if lastExit != "split_declined" {
		t.Errorf("exit reason = %q, want split_declined", lastExit)
	}
	if !strings.Contains(v.Stderr.(*bytes.Buffer).String(), "Pipeline paused by user.") {
		t.Errorf("missing paused message")
	}
}

func TestNeedsClarityNoQuestions(t *testing.T) {
	v := newTestVerdict(t)
	// Synthesize a NEEDS_CLARITY report with an empty Questions section.
	tmp := filepath.Join(t.TempDir(), "empty_q.md")
	body := "## Verdict\nNEEDS_CLARITY\n\n## Questions\n   \n   \n"
	_ = os.WriteFile(tmp, []byte(body), 0o644)
	if err := v.HandleNeedsClarity(context.Background(), tmp); err != nil {
		t.Fatalf("HandleNeedsClarity: %v", err)
	}
	if !strings.Contains(v.Stderr.(*bytes.Buffer).String(),
		"NEEDS_CLARITY but no questions found in report. Proceeding cautiously.") {
		t.Errorf("missing no-questions warning")
	}
}

func TestBashShimDoesNotRedefineStrings(t *testing.T) {
	// Post-m36.2 the operator-vocabulary lives ONLY in this Go package.
	// The bash files are thin shims that exec the Go binary — they MUST NOT
	// contain literal operator text, otherwise a divergence could silently
	// land between the two implementations. This guards the inversion.
	bashFiles := []string{
		"../../lib/intake_helpers.sh",
		"../../lib/intake_verdict_handlers.sh",
	}
	mustNotContain := []string{
		MsgTweaksApplied,
		MsgTweaksRejected,
		MsgTweaksRejectedReason,
		MsgSplitRecommended,
		MsgSplitDeclined,
		MsgSplitDeclinedReason,
		MsgClarifyAborted,
		MsgClarifyAbortedReason,
		MsgClarifyCompleteHalt,
	}
	for _, path := range bashFiles {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Skipf("bash shim %s not present: %v", path, err)
			return
		}
		for _, banned := range mustNotContain {
			if strings.Contains(string(data), banned) {
				t.Errorf("%s contains operator string %q — must live only in internal/intake/verdict.go", path, banned)
			}
		}
	}
}

func TestNeedsClarityAborted(t *testing.T) {
	v := newTestVerdict(t)
	v.ClarifyHandle = func(_ context.Context, _, _ string) error {
		return errors.New("user pressed abort")
	}
	stateCalls := 0
	var lastReason string
	v.PipelineState = func(_, _, _, _, msg, _ string) error {
		stateCalls++
		lastReason = msg
		return nil
	}
	err := v.HandleNeedsClarity(context.Background(), "testdata/report_needs_clarity.md")
	if !errors.Is(err, ErrHalt) {
		t.Fatalf("expected ErrHalt, got %v", err)
	}
	if stateCalls != 1 {
		t.Errorf("PipelineState calls = %d, want 1", stateCalls)
	}
	if lastReason != "Intake needs human clarification" {
		t.Errorf("reason = %q, want %q", lastReason, "Intake needs human clarification")
	}
	if !strings.Contains(v.Stderr.(*bytes.Buffer).String(), "Clarification aborted. Saving state.") {
		t.Errorf("missing abort message")
	}
}

func TestNeedsClarityMissingReport(t *testing.T) {
	v := newTestVerdict(t)
	called := false
	v.ClarifyHandle = func(_ context.Context, _, _ string) error { called = true; return nil }
	if err := v.HandleNeedsClarity(context.Background(), "does-not-exist.md"); err != nil {
		t.Fatalf("expected no error on missing report, got %v", err)
	}
	if called {
		t.Errorf("ClarifyHandle invoked despite missing report")
	}
}

func TestHandleTweakedNonMilestone(t *testing.T) {
	v := newTestVerdict(t)
	// Non-milestone mode: the tweak goes to the task string.
	v.MilestoneMode = false
	if err := v.HandleTweaked(context.Background(), "testdata/report_tweaked.md"); err != nil {
		t.Fatalf("HandleTweaked: %v", err)
	}
	if v.Task == "" {
		t.Errorf("Task not updated from tweak content")
	}
}

func TestSplitAutoFailedFallsToInteractive(t *testing.T) {
	v := newTestVerdict(t)
	v.AutoSplit = true
	v.MilestoneMode = true
	v.CurrentMs = "m1"
	v.Stdin = strings.NewReader("c\n")
	v.IsStdinTTY = true
	v.Split = func(_, _ string) error { return errors.New("split crashed") }
	if err := v.HandleSplitRecommended(context.Background(), "testdata/report_split.md"); err != nil {
		t.Fatal(err)
	}
	stderr := v.Stderr.(*bytes.Buffer).String()
	if !strings.Contains(stderr, "Intake: auto-split failed. Escalating to human.") {
		t.Errorf("missing auto-split-failed warning; stderr:\n%s", stderr)
	}
}

func TestReadChoiceFallback(t *testing.T) {
	v := newTestVerdict(t)
	// No stdin, no TTY reader — falls back to the default.
	got := v.readChoice("y")
	if got != "y" {
		t.Errorf("readChoice fallback = %q, want y", got)
	}
}

func TestReadChoiceTTYReader(t *testing.T) {
	v := newTestVerdict(t)
	v.IsStdinTTY = false
	v.TTYReader = strings.NewReader("q\n")
	if got := v.readChoice("c"); got != "q" {
		t.Errorf("TTYReader path = %q, want q", got)
	}
}

func TestStripQuestionTags(t *testing.T) {
	cases := map[string]string{
		"- [BLOCKING] question 1":     "question 1",
		"- [NON_BLOCKING] question 2": "question 2",
		"- plain question":            "plain question",
		"":                            "",
		"   ":                         "",
	}
	for in, want := range cases {
		if got := stripQuestionTags(in); got != want {
			t.Errorf("stripQuestionTags(%q) = %q, want %q", in, got, want)
		}
	}
}

// pinTimestamp overrides the package timestamp source for the duration of t.
func pinTimestamp(t *testing.T, want string) {
	t.Helper()
	orig := timestamp
	timestamp = func() string { return want }
	t.Cleanup(func() { timestamp = orig })
}
