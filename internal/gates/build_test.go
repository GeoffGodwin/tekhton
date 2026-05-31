package gates

import (
	"context"
	"errors"
	"reflect"
	"testing"
	"time"
)

// TestBuildGate_PhaseOrder is the order-mismatch invariant for m31.1: the
// registered phase order is [analyze, compile, constraints, ui_test,
// ui_validation]. Any reorder fails this test red.
func TestBuildGate_PhaseOrder(t *testing.T) {
	want := []string{"analyze", "compile", "constraints", "ui_test", "ui_validation"}
	got := PhaseOrder()
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("PhaseOrder() = %v, want %v", got, want)
	}

	// Also exercise NewBuildGate so the registration loop actually applies
	// the canonical order to the resulting Phases slice.
	g := NewBuildGate(map[string]func() Phase{
		"analyze":       func() Phase { return &fakePhase{name: "analyze"} },
		"compile":       func() Phase { return &fakePhase{name: "compile"} },
		"constraints":   func() Phase { return &fakePhase{name: "constraints"} },
		"ui_test":       func() Phase { return &fakePhase{name: "ui_test"} },
		"ui_validation": func() Phase { return &fakePhase{name: "ui_validation"} },
	}, BuildGateOptions{})
	names := make([]string, len(g.Phases))
	for i, p := range g.Phases {
		names[i] = p.Name()
	}
	if !reflect.DeepEqual(names, want) {
		t.Fatalf("g.Phases names = %v, want %v", names, want)
	}
}

// TestBuildGate_Run_PassPath: every phase returns Pass → Run returns nil
// and ClearOnPass fires.
func TestBuildGate_Run_PassPath(t *testing.T) {
	w := &captureWriter{}
	g := &BuildGate{
		Phases: []Phase{
			&fakePhase{name: "analyze", status: StatusPass},
			&fakePhase{name: "compile", status: StatusPass},
		},
		Timeout: time.Second,
		Errors:  w,
		Now:     fixedClock("2026-05-31T12:00:00Z"),
	}
	if err := g.Run(context.Background(), "post-coder"); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if !w.clearedOnPass {
		t.Errorf("expected ClearOnPass to fire on success path")
	}
}

// TestBuildGate_Run_FailWrapsPhaseError: phase failure returns
// PhaseError wrapping ErrPhaseFailed; phase name recoverable via errors.As.
func TestBuildGate_Run_FailWrapsPhaseError(t *testing.T) {
	cause := errors.New("analyze errors found")
	g := &BuildGate{
		Phases: []Phase{
			&fakePhase{name: "analyze", status: StatusFail, err: cause},
		},
		Timeout: time.Second,
		Errors:  NoopErrorsWriter{},
		Now:     fixedClock("2026-05-31T12:00:00Z"),
	}
	err := g.Run(context.Background(), "post-coder")
	if err == nil {
		t.Fatal("Run() = nil, want PhaseError")
	}
	if !errors.Is(err, ErrPhaseFailed) {
		t.Errorf("errors.Is(err, ErrPhaseFailed) = false, want true")
	}
	var pe *PhaseError
	if !errors.As(err, &pe) {
		t.Fatalf("errors.As(err, *PhaseError) = false, want true")
	}
	if pe.Phase != "analyze" {
		t.Errorf("PhaseError.Phase = %q, want %q", pe.Phase, "analyze")
	}
	if !errors.Is(pe, cause) {
		t.Errorf("errors.Is(PhaseError, cause) = false, want true")
	}
}

// TestBuildGate_Run_TimeoutWritesSyntheticReport: when the omnibus deadline
// elapses before the next phase fires, Run returns ErrGateTimeout and the
// synthetic ## Gate Timeout BUILD_ERRORS.md is written.
func TestBuildGate_Run_TimeoutWritesSyntheticReport(t *testing.T) {
	w := &captureWriter{}
	clk := newSequenceClock(
		"2026-05-31T12:00:00Z", // call 1: now() → deadline = t0+1s
		"2026-05-31T12:00:00Z", // call 2: iter-0 timeout check (t0 < deadline)
		"2026-05-31T12:00:02Z", // call 3: iter-1 timeout check (t0+2s ≥ deadline)
	)
	g := &BuildGate{
		Phases: []Phase{
			&fakePhase{name: "analyze", status: StatusPass},
			&fakePhase{name: "compile", status: StatusPass},
		},
		Timeout: time.Second,
		Errors:  w,
		Now:     clk.Now,
	}
	err := g.Run(context.Background(), "post-coder")
	if !errors.Is(err, ErrGateTimeout) {
		t.Fatalf("Run() = %v, want ErrGateTimeout", err)
	}
	if !w.timeoutWritten {
		t.Error("expected WriteTimeout to fire")
	}
	if w.lastTimeoutLabel != "post-coder" {
		t.Errorf("WriteTimeout stage label = %q, want %q", w.lastTimeoutLabel, "post-coder")
	}
	if w.lastTimeoutBudget != time.Second {
		t.Errorf("WriteTimeout budget = %v, want %v", w.lastTimeoutBudget, time.Second)
	}
}

// TestBuildGate_Run_SkipPhasesContinue: a phase returning Skip does not
// stop the gate; downstream phases still run.
func TestBuildGate_Run_SkipPhasesContinue(t *testing.T) {
	last := &fakePhase{name: "ui_validation", status: StatusPass}
	g := &BuildGate{
		Phases: []Phase{
			&fakePhase{name: "analyze", status: StatusSkip},
			&fakePhase{name: "compile", status: StatusSkip},
			last,
		},
		Timeout: time.Second,
		Errors:  NoopErrorsWriter{},
		Now:     fixedClock("2026-05-31T12:00:00Z"),
	}
	if err := g.Run(context.Background(), "post-coder"); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if !last.ran {
		t.Error("expected the final phase to run after Skip phases")
	}
}

// TestBuildGate_Run_NilGateIsNoop: zero-value safety.
func TestBuildGate_Run_NilGateIsNoop(t *testing.T) {
	var g *BuildGate
	if err := g.Run(context.Background(), "post-coder"); err != nil {
		t.Fatalf("nil BuildGate.Run = %v, want nil", err)
	}
}

// TestBuildGate_Run_CtxCancelStopsBeforeNextPhase: a cancelled context
// short-circuits Run between phases.
func TestBuildGate_Run_CtxCancelStopsBeforeNextPhase(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	first := &fakePhase{name: "analyze", status: StatusPass, onRun: func() { cancel() }}
	g := &BuildGate{
		Phases: []Phase{
			first,
			&fakePhase{name: "compile", status: StatusPass},
		},
		Timeout: time.Second,
		Errors:  NoopErrorsWriter{},
		Now:     fixedClock("2026-05-31T12:00:00Z"),
	}
	err := g.Run(ctx, "post-coder")
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("Run() = %v, want context.Canceled", err)
	}
}

// fakePhase is the test double used by the suite.
type fakePhase struct {
	name   string
	status PhaseStatus
	err    error
	ran    bool
	onRun  func()
}

func (p *fakePhase) Name() string { return p.name }
func (p *fakePhase) Run(_ context.Context, _ *PhaseInput) PhaseResult {
	p.ran = true
	if p.onRun != nil {
		p.onRun()
	}
	return PhaseResult{Status: p.status, Err: p.err}
}

// captureWriter records every ErrorsWriter call for assertion.
type captureWriter struct {
	resetCalls        int
	analyzeStream     string
	analyzeFull       string
	analyzeLabel      string
	compileLabel      string
	compileStream     string
	constraintsBody   string
	clearedOnPass     bool
	timeoutWritten    bool
	lastTimeoutLabel  string
	lastTimeoutBudget time.Duration
	uiFailureLabel    string
	uiFailureCmd      string
	uiFailureOutput   string
	uiFailureExit     int
	uiDiagnosisBlock  string
}

func (w *captureWriter) Reset() { w.resetCalls++ }
func (w *captureWriter) WriteAnalyze(s, e, o string, _ time.Time) {
	w.analyzeLabel = s
	w.analyzeStream = e
	w.analyzeFull = o
}
func (w *captureWriter) WriteCompile(s, e string, _ time.Time) {
	w.compileLabel = s
	w.compileStream = e
}
func (w *captureWriter) WriteConstraints(body string) { w.constraintsBody = body }
func (w *captureWriter) WriteTimeout(s string, b time.Duration, _ time.Time) {
	w.timeoutWritten = true
	w.lastTimeoutLabel = s
	w.lastTimeoutBudget = b
}
func (w *captureWriter) WriteUIFailure(label, cmd, output string, exit int, _ time.Time) {
	w.uiFailureLabel = label
	w.uiFailureCmd = cmd
	w.uiFailureOutput = output
	w.uiFailureExit = exit
}
func (w *captureWriter) WriteUIDiagnosis(block string) { w.uiDiagnosisBlock = block }
func (w *captureWriter) ClearOnPass()                  { w.clearedOnPass = true }

// fixedClock returns a clock pinned to t.
func fixedClock(rfc3339 string) func() time.Time {
	t, _ := time.Parse(time.RFC3339, rfc3339)
	return func() time.Time { return t }
}

// sequenceClock returns a fixed sequence of timestamps in order. Extra
// calls past the sequence end return the last timestamp.
type sequenceClock struct {
	stamps []time.Time
	idx    int
}

func newSequenceClock(rfc3339 ...string) *sequenceClock {
	c := &sequenceClock{}
	for _, s := range rfc3339 {
		t, _ := time.Parse(time.RFC3339, s)
		c.stamps = append(c.stamps, t)
	}
	return c
}

func (c *sequenceClock) Now() time.Time {
	if len(c.stamps) == 0 {
		return time.Time{}
	}
	if c.idx >= len(c.stamps) {
		return c.stamps[len(c.stamps)-1]
	}
	t := c.stamps[c.idx]
	c.idx++
	return t
}
