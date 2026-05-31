package gates

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// TestAnalyzePhase_PassWhenNoErrors: a command producing output that
// doesn't match ANALYZE_ERROR_PATTERN passes.
func TestAnalyzePhase_PassWhenNoErrors(t *testing.T) {
	p := &AnalyzePhase{
		Cmd:          "echo clean",
		ErrorPattern: "error",
		Runner:       fakeRunner{out: "this is just informational output\n"},
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass; err=%v", r.Status, r.Err)
	}
}

// TestAnalyzePhase_FailWritesAnalyze: matching errors trip Fail and
// invoke ErrorsWriter.WriteAnalyze with the captured stream + full output.
func TestAnalyzePhase_FailWritesAnalyze(t *testing.T) {
	w := &captureWriter{}
	full := "fine\nerror TS2304: cannot find name 'foo'\nalso fine\n"
	p := &AnalyzePhase{
		Cmd:          "tsc",
		ErrorPattern: "error",
		Runner:       fakeRunner{out: full},
		Errors:       w,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "post-coder", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if w.analyzeStream == "" {
		t.Fatal("expected WriteAnalyze to capture the matching lines")
	}
	if !strings.Contains(w.analyzeStream, "TS2304") {
		t.Errorf("captured stream missing TS2304 line: %q", w.analyzeStream)
	}
	if w.analyzeLabel != "post-coder" {
		t.Errorf("WriteAnalyze label = %q, want %q", w.analyzeLabel, "post-coder")
	}
	if w.analyzeFull != full {
		t.Errorf("WriteAnalyze full output mismatch:\ngot:  %q\nwant: %q", w.analyzeFull, full)
	}
}

// TestAnalyzePhase_SkipEmptyCmd: no ANALYZE_CMD means skip.
func TestAnalyzePhase_SkipEmptyCmd(t *testing.T) {
	p := &AnalyzePhase{Runner: fakeRunner{}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestAnalyzePhase_RemediationRetries: when the remediator returns true,
// the analyze command runs a SECOND time.
func TestAnalyzePhase_RemediationRetries(t *testing.T) {
	calls := []string{"error first run\n", "clean second run\n"}
	rr := &sequenceRunner{outs: calls}
	rem := remediatorFunc(func(_ context.Context, _, _ string) bool { return true })
	p := &AnalyzePhase{
		Cmd:          "tsc",
		ErrorPattern: "error",
		Runner:       rr,
		Remediator:   rem,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass after remediation", r.Status)
	}
	if rr.calls != 2 {
		t.Errorf("runner call count = %d, want 2", rr.calls)
	}
}

// TestAnalyzePhase_RemediationFailureCapped: when remediation runs but
// the second invocation still fails, ONE retry happens (not infinite).
func TestAnalyzePhase_RemediationFailureCapped(t *testing.T) {
	rr := &sequenceRunner{outs: []string{"error 1\n", "error 2\n", "error 3\n"}}
	rem := remediatorFunc(func(_ context.Context, _, _ string) bool { return true })
	w := &captureWriter{}
	p := &AnalyzePhase{
		Cmd:          "tsc",
		ErrorPattern: "error",
		Runner:       rr,
		Remediator:   rem,
		Errors:       w,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if rr.calls != 2 {
		t.Errorf("runner call count = %d, want 2 (one initial + one retry)", rr.calls)
	}
}

// TestAnalyzePhase_TimeoutTreatedAsPass: parity with bash `timeout 124`.
func TestAnalyzePhase_TimeoutTreatedAsPass(t *testing.T) {
	p := &AnalyzePhase{
		Cmd:    "long-running-cmd",
		Runner: fakeRunner{timedOut: true},
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Errorf("Status = %v, want StatusPass (timeout 124 ⇒ pass)", r.Status)
	}
}

// TestCompilePhase_PassWhenNoMatches.
func TestCompilePhase_PassWhenNoMatches(t *testing.T) {
	p := &CompilePhase{
		Cmd:          "go build",
		ErrorPattern: "ERROR",
		Runner:       fakeRunner{out: "build OK\n"},
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Fatalf("Status = %v, want StatusPass", r.Status)
	}
}

// TestCompilePhase_HeadLimits20: matching errors are head-limited to 20.
func TestCompilePhase_HeadLimits20(t *testing.T) {
	var b strings.Builder
	for i := 0; i < 25; i++ {
		b.WriteString("ERROR line ")
		b.WriteString("X\n")
	}
	w := &captureWriter{}
	p := &CompilePhase{
		Cmd:          "go build",
		ErrorPattern: "ERROR",
		Runner:       fakeRunner{out: b.String(), exit: 1},
		Errors:       w,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	gotLines := strings.Count(w.compileStream, "\n") + 1
	if gotLines > 20 {
		t.Errorf("compileStream lines = %d, want ≤ 20", gotLines)
	}
}

// TestCompilePhase_SkipEmptyCmd.
func TestCompilePhase_SkipEmptyCmd(t *testing.T) {
	p := &CompilePhase{Runner: fakeRunner{}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestConstraintsPhase_PassExit0.
func TestConstraintsPhase_PassExit0(t *testing.T) {
	p := &ConstraintsPhase{
		ValidationCmd: "true",
		Runner:        fakeRunner{exit: 0},
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusPass {
		t.Errorf("Status = %v, want StatusPass", r.Status)
	}
}

// TestConstraintsPhase_FailWritesSection.
func TestConstraintsPhase_FailWritesSection(t *testing.T) {
	w := &captureWriter{}
	p := &ConstraintsPhase{
		ValidationCmd: "false",
		Runner:        fakeRunner{exit: 1, out: "layer violation: foo imports bar\n"},
		Errors:        w,
	}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusFail {
		t.Fatalf("Status = %v, want StatusFail", r.Status)
	}
	if w.constraintsBody == "" {
		t.Error("expected WriteConstraints to be called")
	}
}

// TestConstraintsPhase_SkipEmptyCmd.
func TestConstraintsPhase_SkipEmptyCmd(t *testing.T) {
	p := &ConstraintsPhase{Runner: fakeRunner{}}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestUIValidationPhase_SkipsWhenCmdUnset.
func TestUIValidationPhase_SkipsWhenCmdUnset(t *testing.T) {
	p := &UIValidationPhase{}
	r := p.Run(context.Background(), &PhaseInput{StageLabel: "x", Now: time.Now})
	if r.Status != StatusSkip {
		t.Errorf("Status = %v, want StatusSkip", r.Status)
	}
}

// TestEffectiveTimeout covers the min(phase, remaining) helper.
func TestEffectiveTimeout(t *testing.T) {
	tests := []struct {
		phase, remaining, want time.Duration
	}{
		{5 * time.Second, 10 * time.Second, 5 * time.Second},
		{10 * time.Second, 3 * time.Second, 3 * time.Second},
		{0, 5 * time.Second, 5 * time.Second},
		{5 * time.Second, 0, 5 * time.Second},
		{0, 0, 0},
		{5 * time.Second, -1 * time.Second, 5 * time.Second},
	}
	for _, tc := range tests {
		got := effectiveTimeout(tc.phase, tc.remaining)
		if got != tc.want {
			t.Errorf("effectiveTimeout(%v, %v) = %v, want %v", tc.phase, tc.remaining, got, tc.want)
		}
	}
}

// TestHeadLines verifies the head -N helper.
func TestHeadLines(t *testing.T) {
	in := "a\nb\nc\nd\ne\n"
	if got := headLines(in, 3); got != "a\nb\nc" {
		t.Errorf("headLines(3) = %q, want %q", got, "a\nb\nc")
	}
	if got := headLines(in, 100); got != in {
		t.Errorf("headLines(100) = %q, want unchanged", got)
	}
	if got := headLines("", 3); got != "" {
		t.Errorf("headLines(empty) = %q, want empty", got)
	}
}

// TestGrepLinesInvalidPattern returns empty (bash || true semantics).
func TestGrepLinesInvalidPattern(t *testing.T) {
	if got := grepLines("anything", "["); got != "" {
		t.Errorf("grepLines with invalid regex = %q, want empty", got)
	}
}

// TestPhaseError_IsPhaseFailed exercises the errors.Is chain.
func TestPhaseError_IsPhaseFailed(t *testing.T) {
	pe := &PhaseError{Phase: "analyze", Err: errAnalyzeFailed}
	if !errors.Is(pe, ErrPhaseFailed) {
		t.Error("PhaseError.Is(ErrPhaseFailed) = false, want true")
	}
}

// --- Test doubles ---------------------------------------------------------

type fakeRunner struct {
	out      string
	exit     int
	timedOut bool
	err      error
}

func (r fakeRunner) Run(_ context.Context, _ string, _ time.Duration) ([]byte, int, bool, error) {
	return []byte(r.out), r.exit, r.timedOut, r.err
}

// sequenceRunner produces a pre-canned sequence of outputs across calls.
type sequenceRunner struct {
	outs  []string
	exits []int
	calls int
}

func (r *sequenceRunner) Run(_ context.Context, _ string, _ time.Duration) ([]byte, int, bool, error) {
	if r.calls >= len(r.outs) {
		r.calls++
		return nil, 0, false, nil
	}
	out := r.outs[r.calls]
	exit := 0
	if r.calls < len(r.exits) {
		exit = r.exits[r.calls]
	}
	r.calls++
	return []byte(out), exit, false, nil
}

// remediatorFunc adapts a function to the Remediator interface.
type remediatorFunc func(ctx context.Context, errs, phase string) bool

func (f remediatorFunc) TryRemediate(ctx context.Context, errs, phase string) bool {
	return f(ctx, errs, phase)
}
