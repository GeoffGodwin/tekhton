package finalize

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeHook is a test double for Hook that records every Run invocation.
type fakeHook struct {
	name     string
	runCount int
	err      error
}

func (f *fakeHook) Name() string { return f.name }
func (f *fakeHook) Run(_ context.Context, _ *Input) error {
	f.runCount++
	return f.err
}

// TestHookOrder_MatchesBashRegistration is the order-mismatch guard the
// milestone requires. m21 made the Go hookOrder list (orchestrator.go) the
// canonical source — lib/finalize.sh is now a thin shim with no
// registration list of its own. Adding a hook requires updating the Go
// slice plus the corresponding case in lib/finalize_shim.sh; this test
// fails red if those drift.
func TestHookOrder_MatchesBashRegistration(t *testing.T) {
	// Canonical registration order as of m25. Update this list whenever
	// hookOrder in orchestrator.go changes — the test exists to catch
	// silent reorderings, not to mirror an external source.
	//
	// m25 added _hook_clarify_finalize between _hook_resolve_notes and
	// _hook_archive_reports so the stale CLARIFICATIONS.md is gone
	// before the archive sweep runs.
	expected := []string{
		"_hook_baseline_cleanup",
		"_hook_note_acceptance",
		"_hook_final_checks",
		"_hook_drift_artifacts",
		"_hook_record_metrics",
		"_hook_causal_log_finalize",
		"_hook_resolve_addressed_nonblocking",
		"_hook_resolve_addressed_drift",
		"_hook_cleanup_resolved",
		"_hook_resolve_notes",
		"_hook_clarify_finalize",
		"_hook_archive_reports",
		"_hook_health_reassess",
		"_hook_emit_run_summary",
		"_hook_emit_run_memory",
		"_hook_emit_timing_report",
		"_hook_failure_context",
		"_hook_express_persist",
		"_hook_project_version_bump",
		"_hook_changelog_append",
		"_hook_commit",
		// Completion bookkeeping hooks — moved AFTER _hook_commit so
		// they only fire when the commit-decision sentinel says
		// "committed." See lib/finalize_commit.sh comment and
		// shouldRunOnCompletion in clear_state.go.
		"_hook_mark_done",
		"_hook_cleanup_milestone",
		"_hook_clear_state",
		"_hook_project_version_tag",
		"_hook_update_check",
		"_hook_final_dashboard_status",
		"_hook_tui_complete",
		"_hook_failure_context_reset",
	}
	got := HookOrder()
	if len(got) != 29 {
		t.Fatalf("expected 29 hooks in registry, got %d", len(got))
	}
	if len(got) != len(expected) {
		t.Fatalf("expected %d hooks, got %d", len(expected), len(got))
	}
	for i := range expected {
		if got[i] != expected[i] {
			t.Errorf("hook[%d]: expected %q, got %q (order drift — update bash and Go together)", i, expected[i], got[i])
		}
	}
}

// TestOrchestratorRun_RunsEveryHookInOrder verifies the orchestrator
// invokes each registered hook exactly once and reports per-hook results.
func TestOrchestratorRun_RunsEveryHookInOrder(t *testing.T) {
	var calls []string
	hookA := &fakeHook{name: "_hook_a"}
	hookB := &fakeHook{name: "_hook_b"}
	hookC := &fakeHook{name: "_hook_c"}
	hooks := []Hook{hookA, hookB, hookC}

	o := &Orchestrator{log: &bytes.Buffer{}, now: time.Now}
	// Wrap each hook so we can record execution order without modifying
	// the Hook interface for production code.
	for _, h := range hooks {
		h := h
		o.hooks = append(o.hooks, &recordingHook{Hook: h, calls: &calls})
	}

	sum := o.Run(context.Background(), &Input{})
	if len(sum.Hooks) != 3 {
		t.Fatalf("expected 3 HookResults, got %d", len(sum.Hooks))
	}
	if hookA.runCount != 1 || hookB.runCount != 1 || hookC.runCount != 1 {
		t.Errorf("each hook should run exactly once: a=%d b=%d c=%d", hookA.runCount, hookB.runCount, hookC.runCount)
	}
	wantOrder := []string{"_hook_a", "_hook_b", "_hook_c"}
	for i := range wantOrder {
		if calls[i] != wantOrder[i] {
			t.Errorf("call[%d]: expected %q, got %q", i, wantOrder[i], calls[i])
		}
	}
}

// TestOrchestratorRun_ContinueOnError verifies a hook returning an error
// is logged but does not abort the chain.
func TestOrchestratorRun_ContinueOnError(t *testing.T) {
	var log bytes.Buffer
	failing := &fakeHook{name: "_hook_fail", err: errors.New("simulated")}
	after := &fakeHook{name: "_hook_after"}
	o := &Orchestrator{log: &log, now: time.Now, hooks: []Hook{failing, after}}

	sum := o.Run(context.Background(), &Input{Log: &log})
	if after.runCount != 1 {
		t.Errorf("subsequent hook must run after a failure: runCount=%d", after.runCount)
	}
	failed := sum.Failed()
	if len(failed) != 1 || failed[0] != "_hook_fail" {
		t.Errorf("expected one failed hook _hook_fail, got %v", failed)
	}
	if !bytes.Contains(log.Bytes(), []byte("simulated")) {
		t.Errorf("expected log to contain hook error message; got %q", log.String())
	}
}

// TestNewOrchestrator_BuildsAllHooks asserts the production constructor
// registers the canonical hook count — 26 in m21, 27 in m25 when
// _hook_clarify_finalize landed, 28 after the m25-followup added
// _hook_resolve_addressed_nonblocking, 29 after the drift-parity
// followup added _hook_resolve_addressed_drift (mirrors the nonblocking
// hook for drift observations so the drift log carries `[ ]`/`[x]`
// checkbox semantics consistent with the nonblocking log).
func TestNewOrchestrator_BuildsAllHooks(t *testing.T) {
	o := NewOrchestrator("/tmp/tekhton", "/tmp/project")
	if len(o.Hooks()) != 29 {
		t.Errorf("NewOrchestrator must register 29 hooks; got %d", len(o.Hooks()))
	}
	gotNames := make([]string, 0, len(o.Hooks()))
	for _, h := range o.Hooks() {
		gotNames = append(gotNames, h.Name())
	}
	for i, name := range HookOrder() {
		if gotNames[i] != name {
			t.Errorf("hook[%d]: orchestrator built %q, registry says %q", i, gotNames[i], name)
		}
	}
}

// TestOrchestratorRun_FillsLogIfNil verifies the orchestrator wires
// in.Log to its own log writer when the caller did not set one.
func TestOrchestratorRun_FillsLogIfNil(t *testing.T) {
	var orchLog bytes.Buffer
	o := &Orchestrator{log: &orchLog, now: time.Now}
	called := false
	o.hooks = []Hook{&captureLogHook{name: "_hook_capture", onRun: func(in *Input) {
		called = true
		if in.Log == nil {
			t.Errorf("orchestrator should fill in.Log when nil")
		}
	}}}
	_ = o.Run(context.Background(), &Input{Result: &proto.RunResultV1{}})
	if !called {
		t.Fatalf("hook never ran")
	}
}

// TestOrchestrator_SetsAndClearsFinalizeActiveSentinel is the m50
// acceptance test for the .tekhton/.finalize_active sentinel. The
// finalize chain writes the sentinel at the top of Run and must clear
// it on return (via deferred cleanup so a panic mid-finalize doesn't
// leave the sentinel set and silently legitimize a subsequent rogue
// commit). The pre-commit guards in lib/finalize_commit.sh and
// cmd/tekhton/run.go consult this file to distinguish finalize-initiated
// commits from stage-initiated commits.
func TestOrchestrator_SetsAndClearsFinalizeActiveSentinel(t *testing.T) {
	projectDir := t.TempDir()
	sentinelPath := filepath.Join(projectDir, ".tekhton", ".finalize_active")

	// A hook that asserts the sentinel exists at the moment Run is
	// executing it — proves the sentinel was written BEFORE the chain
	// started executing user-visible work.
	var sawSentinelDuringRun bool
	probeHook := &captureLogHook{name: "_hook_probe", onRun: func(in *Input) {
		if _, err := os.Stat(sentinelPath); err == nil {
			sawSentinelDuringRun = true
		}
	}}

	o := &Orchestrator{log: &bytes.Buffer{}, now: time.Now, hooks: []Hook{probeHook}}
	_ = o.Run(context.Background(), &Input{
		ProjectDir: projectDir,
		Timestamp:  "20260608_120000",
	})

	if !sawSentinelDuringRun {
		t.Errorf("expected .tekhton/.finalize_active to exist during hook execution; it did not")
	}
	if _, err := os.Stat(sentinelPath); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("expected .tekhton/.finalize_active to be cleaned up after Run; stat err=%v", err)
	}
}

// TestOrchestrator_FinalizeActiveSentinel_NoProjectDir verifies the
// sentinel logic is a no-op when ProjectDir is empty (the debug
// subcommand path). Run must not panic, and no sentinel can be written
// to a relative path inside the working directory.
func TestOrchestrator_FinalizeActiveSentinel_NoProjectDir(t *testing.T) {
	o := &Orchestrator{log: &bytes.Buffer{}, now: time.Now, hooks: nil}
	_ = o.Run(context.Background(), &Input{})
	// No assertion needed — failure is a panic or sentinel file appearing
	// somewhere unexpected. Smoke coverage only.
}

// TestWriteFinalizeActiveSentinel_TimestampPayload verifies the sentinel is
// written with the Timestamp field as its content (plus newline). This pins
// the payload contract so a future change to the payload format can't silently
// pass the orchestrator-level tests, which only check file existence.
func TestWriteFinalizeActiveSentinel_TimestampPayload(t *testing.T) {
	projectDir := t.TempDir()
	in := &Input{
		ProjectDir: projectDir,
		Timestamp:  "20260608_120000",
	}
	cleanup := writeFinalizeActiveSentinel(in)
	if cleanup == nil {
		t.Fatal("expected non-nil cleanup func for valid ProjectDir")
	}
	defer cleanup()

	sentinelPath := filepath.Join(projectDir, ".tekhton", ".finalize_active")
	got, err := os.ReadFile(sentinelPath)
	if err != nil {
		t.Fatalf("sentinel not written: %v", err)
	}
	if string(got) != "20260608_120000\n" {
		t.Errorf("sentinel content: got %q, want %q", string(got), "20260608_120000\n")
	}
}

// TestWriteFinalizeActiveSentinel_ActiveFallback verifies that when Timestamp
// is empty the sentinel payload falls back to the literal "active" string.
func TestWriteFinalizeActiveSentinel_ActiveFallback(t *testing.T) {
	projectDir := t.TempDir()
	in := &Input{ProjectDir: projectDir, Timestamp: ""}
	cleanup := writeFinalizeActiveSentinel(in)
	if cleanup == nil {
		t.Fatal("expected non-nil cleanup func")
	}
	defer cleanup()

	sentinelPath := filepath.Join(projectDir, ".tekhton", ".finalize_active")
	got, err := os.ReadFile(sentinelPath)
	if err != nil {
		t.Fatalf("sentinel not written: %v", err)
	}
	if string(got) != "active\n" {
		t.Errorf("sentinel content: got %q, want %q", string(got), "active\n")
	}
}

// TestWriteFinalizeActiveSentinel_NilInput verifies the function returns nil
// without panicking when called with a nil Input.
func TestWriteFinalizeActiveSentinel_NilInput(t *testing.T) {
	cleanup := writeFinalizeActiveSentinel(nil)
	if cleanup != nil {
		t.Errorf("expected nil cleanup for nil Input; got non-nil")
	}
}

// TestWriteFinalizeActiveSentinel_EmptyProjectDir verifies the function
// returns nil (no-op) when ProjectDir is the empty string, matching the
// debug-subcommand path.
func TestWriteFinalizeActiveSentinel_EmptyProjectDir(t *testing.T) {
	cleanup := writeFinalizeActiveSentinel(&Input{ProjectDir: ""})
	if cleanup != nil {
		t.Errorf("expected nil cleanup for empty ProjectDir; got non-nil")
	}
}

// recordingHook decorates a Hook to record the call order in an external
// slice without mutating the Hook implementation under test.
type recordingHook struct {
	Hook
	calls *[]string
}

func (r *recordingHook) Run(ctx context.Context, in *Input) error {
	*r.calls = append(*r.calls, r.Hook.Name())
	return r.Hook.Run(ctx, in)
}

// captureLogHook lets a test assert on the Input populated by the
// orchestrator without using a fakeHook (which would record calls but not
// give the test access to the Input value).
type captureLogHook struct {
	name  string
	onRun func(in *Input)
}

func (c *captureLogHook) Name() string { return c.name }
func (c *captureLogHook) Run(_ context.Context, in *Input) error {
	c.onRun(in)
	return nil
}
