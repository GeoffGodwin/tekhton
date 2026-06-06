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

// TestCompletionGate_NoBaselineFirstFailsRetryPasses is the m45 happy-path
// flake test: TEST_CMD returns exit=1 then exit=0 on the no-baseline path.
// Expect nil error, RecordPass called, and a completion_gate_flake causal
// event emitted with the documented fields.
func TestCompletionGate_NoBaselineFirstFailsRetryPasses(t *testing.T) {
	dir := t.TempDir()
	dedup := &fakeDedup{}
	causal := &fakeCausalEmitter{}
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "test-cmd-flake",
		TestEnabled:       true,
		RetryOnNoBaseline: true,
		RetryDelay:        0,
		Runner:            &sequenceRunner{outs: []string{"FAIL: t.Foo\n", "OK\n"}, exits: []int{1, 0}},
		Dedup:             dedup,
		Causal:            causal,
		Logger:            func(string, ...interface{}) {},
		Milestone:         "m45",
	}
	if err := g.Run(context.Background()); err != nil {
		t.Fatalf("Run() = %v, want nil (retry passes)", err)
	}
	if !dedup.recorded {
		t.Error("Dedup.RecordPass not called after successful retry")
	}
	if len(causal.events) != 1 {
		t.Fatalf("Causal.Emit called %d times, want 1", len(causal.events))
	}
	ev := causal.events[0]
	if ev.eventType != "completion_gate_flake" {
		t.Errorf("event type = %q, want completion_gate_flake", ev.eventType)
	}
	if ev.fields["first_exit"] != "1" {
		t.Errorf("first_exit = %q, want 1", ev.fields["first_exit"])
	}
	if ev.fields["retry_exit"] != "0" {
		t.Errorf("retry_exit = %q, want 0", ev.fields["retry_exit"])
	}
	if ev.fields["test_cmd"] != "test-cmd-flake" {
		t.Errorf("test_cmd = %q, want test-cmd-flake", ev.fields["test_cmd"])
	}
	if ev.fields["milestone"] != "m45" {
		t.Errorf("milestone = %q, want m45", ev.fields["milestone"])
	}
}

// TestCompletionGate_NoBaselineBothFail is the m45 genuine-breakage path:
// both attempts return exit=1, no baseline. Expect ErrCompletionTestFailed
// and no causal event.
func TestCompletionGate_NoBaselineBothFail(t *testing.T) {
	dir := t.TempDir()
	causal := &fakeCausalEmitter{}
	rr := &sequenceRunner{outs: []string{"FAIL 1\n", "FAIL 2\n"}, exits: []int{1, 1}}
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "test-cmd-broken",
		TestEnabled:       true,
		RetryOnNoBaseline: true,
		RetryDelay:        0,
		Runner:            rr,
		Causal:            causal,
		Logger:            func(string, ...interface{}) {},
	}
	err := g.Run(context.Background())
	if !errors.Is(err, ErrCompletionTestFailed) {
		t.Errorf("Run() = %v, want ErrCompletionTestFailed", err)
	}
	if rr.calls != 2 {
		t.Errorf("runner calls = %d, want 2 (one initial + one retry)", rr.calls)
	}
	if len(causal.events) != 0 {
		t.Errorf("Causal.Emit called %d times on both-fail, want 0", len(causal.events))
	}
}

// TestCompletionGate_GracePeriodRespectsContextCancel asserts that an
// in-flight grace-window sleep aborts promptly on ctx cancellation rather
// than waiting out the full window — and that no TEST_CMD invocation
// happens after the cancel.
func TestCompletionGate_GracePeriodRespectsContextCancel(t *testing.T) {
	dir := t.TempDir()
	called := &callCounter{}
	g := &CompletionGate{
		SummaryFile: writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:     "never-runs",
		TestEnabled: true,
		GraceSecs:   10 * time.Second,
		Runner:      called,
		Logger:      func(string, ...interface{}) {},
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	err := g.Run(ctx)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("Run() = %v, want context.Canceled", err)
	}
	if elapsed > 5*time.Second {
		t.Errorf("Run took %v, want prompt cancel (< 5s) within the 10s grace window", elapsed)
	}
	if called.runs != 0 {
		t.Errorf("runner invoked %d times during a cancelled grace window, want 0", called.runs)
	}
}

// TestCompletionGate_RetryDelayRespectsContextCancel asserts that a ctx
// cancel during the retry-delay sleep aborts promptly.
func TestCompletionGate_RetryDelayRespectsContextCancel(t *testing.T) {
	dir := t.TempDir()
	rr := &sequenceRunner{outs: []string{"FAIL\n"}, exits: []int{1}}
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "any",
		TestEnabled:       true,
		RetryOnNoBaseline: true,
		RetryDelay:        10 * time.Second,
		Runner:            rr,
		Logger:            func(string, ...interface{}) {},
	}
	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	err := g.Run(ctx)
	elapsed := time.Since(start)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("Run() = %v, want context.Canceled", err)
	}
	if elapsed > 5*time.Second {
		t.Errorf("Run took %v, want prompt cancel inside the retry delay", elapsed)
	}
	if rr.calls != 1 {
		t.Errorf("runner calls = %d, want 1 (first invocation only, cancel during delay)", rr.calls)
	}
}

// TestCompletionGate_RetryDisabledHaltsImmediately asserts the
// pre-m45-behavior opt-out: with RetryOnNoBaseline=false, the no-baseline
// branch halts on the first failed TEST_CMD without retrying.
func TestCompletionGate_RetryDisabledHaltsImmediately(t *testing.T) {
	dir := t.TempDir()
	rr := &sequenceRunner{outs: []string{"FAIL\n"}, exits: []int{1}}
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "any",
		TestEnabled:       true,
		RetryOnNoBaseline: false,
		Runner:            rr,
		Logger:            func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); !errors.Is(err, ErrCompletionTestFailed) {
		t.Errorf("Run() = %v, want ErrCompletionTestFailed", err)
	}
	if rr.calls != 1 {
		t.Errorf("runner calls = %d, want 1 (no retry when RetryOnNoBaseline=false)", rr.calls)
	}
}

// TestCompletionGate_RetrySkippedWhenBaselineExists asserts the design
// invariant: the retry policy is intentionally limited to the no-baseline
// branch. When a baseline exists, a non-zero exit with novel failures must
// halt immediately without retrying.
func TestCompletionGate_RetrySkippedWhenBaselineExists(t *testing.T) {
	dir := t.TempDir()
	rr := &sequenceRunner{outs: []string{"FAIL: novel\n"}, exits: []int{1}}
	g := &CompletionGate{
		SummaryFile:       writeSummary(t, dir, "# x\n## Status: COMPLETE\n"),
		TestCmd:           "any",
		TestEnabled:       true,
		RetryOnNoBaseline: true, // configured on, but baseline branch ignores
		Runner:            rr,
		Baseline:          fakeBaseline{has: true, preexisting: false},
		Logger:            func(string, ...interface{}) {},
	}
	if err := g.Run(context.Background()); !errors.Is(err, ErrCompletionTestFailed) {
		t.Errorf("Run() = %v, want ErrCompletionTestFailed", err)
	}
	if rr.calls != 1 {
		t.Errorf("runner calls = %d, want 1 (no retry when baseline exists)", rr.calls)
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

func (b fakeBaseline) HasBaseline() bool        { return b.has }
func (b fakeBaseline) Compare([]byte, int) bool { return b.preexisting }

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

type fakeCausalEvent struct {
	eventType string
	fields    map[string]string
}

type fakeCausalEmitter struct {
	events []fakeCausalEvent
}

func (f *fakeCausalEmitter) Emit(eventType string, fields map[string]string) {
	copied := make(map[string]string, len(fields))
	for k, v := range fields {
		copied[k] = v
	}
	f.events = append(f.events, fakeCausalEvent{eventType: eventType, fields: copied})
}
