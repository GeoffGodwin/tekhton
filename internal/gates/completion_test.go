package gates

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func writeSummary(t *testing.T, dir, body string) string {
	t.Helper()
	p := filepath.Join(dir, "CODER_SUMMARY.md")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write summary: %v", err)
	}
	return p
}

// TestCompletionGate_InProgressBranch.
func TestCompletionGate_InProgressBranch(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: IN PROGRESS\n"),
		Logger:      func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionInProgress) {
		t.Errorf("Run() = %v, want ErrCompletionInProgress", err)
	}
}

// TestCompletionGate_CompleteWithDisabledTestPasses.
func TestCompletionGate_CompleteWithDisabledTestPasses(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestEnabled: false,
		Logger:      func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); err != nil {
		t.Errorf("Run() = %v, want nil", err)
	}
}

// TestCompletionGate_CompleteWithTestPass.
func TestCompletionGate_CompleteWithTestPass(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "true",
		TestEnabled: true,
		Logger:      func(string, ...interface{}) {},
	}
	// TestCmd is literal "true" → bash guard treats as skip.
	if err := g.Run(context.Background()); err != nil {
		t.Errorf("Run() = %v, want nil for literal true TEST_CMD", err)
	}
}

// TestCompletionGate_CompleteWithTestFail.
func TestCompletionGate_CompleteWithTestFail(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "test-cmd-fail",
		TestEnabled: true,
		Runner:      fakeRunner{exit: 1, out: "FAIL: t.Foo\n"},
		Logger:      func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionTestFailed) {
		t.Errorf("Run() = %v, want ErrCompletionTestFailed", err)
	}
}

// TestCompletionGate_PreExistingFailureAccepted: baseline says
// pre-existing + PassOnPreexisting=true → Pass.
func TestCompletionGate_PreExistingFailureAccepted(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "test-cmd-fail",
		TestEnabled:       true,
		PassOnPreexisting: true,
		Runner:            fakeRunner{exit: 1, out: "FAIL: t.Foo\n"},
		Baseline:          fakeBaseline{has: true, preexisting: true},
		Logger:            func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); err != nil {
		t.Errorf("Run() = %v, want nil (pre-existing accepted)", err)
	}
}

// TestCompletionGate_PreExistingFailureRejectedByDefault: baseline says
// pre-existing + PassOnPreexisting=false (M92 default) → ErrCompletionPreExisting.
func TestCompletionGate_PreExistingFailureRejectedByDefault(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "test-cmd-fail",
		TestEnabled:       true,
		PassOnPreexisting: false,
		Runner:            fakeRunner{exit: 1, out: "FAIL: t.Foo\n"},
		Baseline:          fakeBaseline{has: true, preexisting: true},
		Logger:            func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionPreExisting) {
		t.Errorf("Run() = %v, want ErrCompletionPreExisting", err)
	}
}

// TestCompletionGate_NoStatusFallsToErr.
func TestCompletionGate_NoStatusFallsToErr(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\nNo status field here.\n"),
		Logger:      func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionNoStatus) {
		t.Errorf("Run() = %v, want ErrCompletionNoStatus", err)
	}
}

// TestCompletionGate_SubstantiveNoStatusFallsToInProgress.
func TestCompletionGate_SubstantiveNoStatusFallsToInProgress(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\nNo status field here.\n"),
		Substantive: fakeSubstantive{true},
		Logger:      func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionSubstantiveNoStatus) {
		t.Errorf("Run() = %v, want ErrCompletionSubstantiveNoStatus", err)
	}
}

// TestCompletionGate_StatusNextLineShape covers the "## Status\nVALUE" form.
func TestCompletionGate_StatusNextLineShape(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status\nCOMPLETE\n"),
		TestEnabled: false,
		Logger:      func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); err != nil {
		t.Errorf("Run() = %v, want nil", err)
	}
}

// TestCompletionGate_DedupSkipsTestCmd.
func TestCompletionGate_DedupSkipsTestCmd(t *testing.T) {
	dir := t.TempDir()
	dedup := &fakeDedup{canSkip: true}
	called := &callCounter{}
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "would-run",
		TestEnabled: true,
		Runner:      called,
		Dedup:       dedup,
		Logger:      func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); err != nil {
		t.Fatalf("Run() = %v, want nil", err)
	}
	if called.runs != 0 {
		t.Errorf("dedup skip should suppress TEST_CMD; runs = %d", called.runs)
	}
}

// TestCompletionGate_DumpsFailureOutput verifies the
// COMPLETION_GATE_LAST_FAILURE.log capture.
func TestCompletionGate_DumpsFailureOutput(t *testing.T) {
	dir := t.TempDir()
	dump := filepath.Join(dir, "fail.log")
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "fail-cmd",
		TestEnabled: true,
		Runner:      fakeRunner{exit: 1, out: "TEST_FAIL_LINE\n"},
		DumpPath:    dump,
		Milestone:   "m31.1",
		Cwd:         dir,
		Logger:      func(string, ...interface{}) {},
	}
	_ = g.Run(context.Background())
	b, err := os.ReadFile(dump)
	if err != nil {
		t.Fatalf("dump file unreadable: %v", err)
	}
	if !strings.Contains(string(b), "TEST_FAIL_LINE") {
		t.Errorf("dump missing captured output: %s", string(b))
	}
	if !strings.Contains(string(b), "# Milestone: m31.1") {
		t.Errorf("dump missing milestone header: %s", string(b))
	}
}

// TestCompletionGate_StdinDevNull asserts the M27.2 hang fix: the gate's
// TEST_CMD must not be able to block on `read < /dev/tty`. We construct
// an ExecRunner explicitly and run TEST_CMD = `bash -c "read -t 1 -r line
// || echo TIMEOUT_OK"`. Without the cmd.Stdin = nil guard, the read would
// hang forever; with the guard, read returns EOF immediately and the
// gate passes.
func TestCompletionGate_StdinDevNull(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("bash-dependent test")
	}
	if _, err := os.Stat("/bin/bash"); err != nil {
		if _, err := os.Stat("/usr/bin/bash"); err != nil {
			t.Skip("bash not available")
		}
	}
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		// read returns non-zero on EOF; we OR with echo so the cmd exits 0.
		TestCmd:     `read -t 1 -r line || echo "TIMEOUT_OK"`,
		TestEnabled: true,
		Timeout:     5 * time.Second,
		Logger:      func(string, ...interface{}) {},
	}
	done := make(chan error, 1)
	go func() { done <- g.Run(context.Background()) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("Run() = %v, want nil (M27.2 stdin /dev/null guard)", err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("Run blocked (M27.2 regression — TEST_CMD inherited a real stdin)")
	}
}

// TestCompletionGate_NilGateIsNoop.
func TestCompletionGate_NilGateIsNoop(t *testing.T) {
	var g *CompletionGate
	if err := g.Run(context.Background()); err != nil {
		t.Errorf("nil gate Run = %v, want nil", err)
	}
}

// TestCompletionGate_SummaryDriftFires.
func TestCompletionGate_SummaryDriftFires(t *testing.T) {
	dir := t.TempDir()
	called := false
	g := &CompletionGate{
		SummaryFile:  writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestEnabled:  false,
		SummaryDrift: driftFn(func(_ string) { called = true }),
		Logger:       func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); err != nil {
		t.Fatalf("Run() = %v", err)
	}
	if !called {
		t.Error("SummaryDrift.Run was not invoked on COMPLETE branch")
	}
}

// TestCompletionGate_RunnerError_WrapsInfrastructureFailure.
func TestCompletionGate_RunnerError_WrapsInfrastructureFailure(t *testing.T) {
	dir := t.TempDir()
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "any",
		TestEnabled: true,
		Runner:      fakeRunner{err: errors.New("subprocess crashed")},
		Logger:      func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if err == nil {
		t.Fatal("expected runner error to surface as gate error")
	}
	if errors.Is(err, ErrCompletionTestFailed) || errors.Is(err, ErrCompletionPreExisting) {
		t.Errorf("runner crash should NOT map to test-failure sentinel; got %v", err)
	}
}

// --- Test doubles --------------------------------------------------------

type fakeBaseline struct {
	has         bool
	preexisting bool
}

func (b fakeBaseline) HasBaseline() bool                    { return b.has }
func (b fakeBaseline) Compare([]byte, int) bool             { return b.preexisting }

type fakeSubstantive struct{ on bool }

func (s fakeSubstantive) IsSubstantive() bool { return s.on }

type fakeDedup struct {
	canSkip  bool
	recorded bool
}

func (d *fakeDedup) CanSkip() bool { return d.canSkip }
func (d *fakeDedup) RecordPass()   { d.recorded = true }

type callCounter struct{ runs int }

func (c *callCounter) Run(_ context.Context, _ string, _ time.Duration) ([]byte, int, bool, error) {
	c.runs++
	return nil, 0, false, nil
}

type driftFn func(string)

func (f driftFn) Run(p string) { f(p) }
