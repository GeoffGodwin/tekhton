package supervisor

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fakeAgentPath returns the absolute path to testdata/fake_agent.sh. Skips
// the calling test on Windows (POSIX shell required) or when bash is not on
// PATH; m09 will add a Windows-equivalent fixture once the JobObject reaper
// lands.
func fakeAgentPath(t *testing.T) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("fake_agent.sh requires a POSIX shell; m09 will add Windows fixtures")
	}
	if _, err := exec.LookPath("bash"); err != nil {
		t.Skipf("bash not on PATH: %v", err)
	}
	root, err := filepath.Abs(filepath.Join("..", "..", "testdata", "fake_agent.sh"))
	if err != nil {
		t.Fatalf("abs testdata: %v", err)
	}
	return root
}

// happyRequest builds a request that targets the fake-agent fixture in the
// given mode. The PromptFile points at the fixture purely so callers can
// see what the script will be — the fixture ignores its argv and reads
// FAKE_AGENT_MODE from EnvOverrides.
func happyRequest(t *testing.T, mode string) *proto.AgentRequestV1 {
	t.Helper()
	script := fakeAgentPath(t)
	return &proto.AgentRequestV1{
		Proto:               proto.AgentRequestProtoV1,
		RunID:               "rid-" + mode,
		Label:               "tester",
		Model:               "fake",
		PromptFile:          script,
		ActivityTimeoutSecs: 5,
		EnvOverrides:        map[string]string{"FAKE_AGENT_MODE": mode},
	}
}

// runWithBashFixture wires a Supervisor at the fixture script and runs the
// request under a fresh background context. The script's shebang launches
// bash directly; we rely on the chmod +x set in source control.
func runWithBashFixture(t *testing.T, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	t.Helper()
	sup := New(nil, nil)
	sup.SetBinary(fakeAgentPath(t))
	return sup.Run(context.Background(), req)
}

// ---------------------------------------------------------------------------
// Happy path — AC: success outcome, exit 0, TurnsUsed populated, StdoutTail
// contains all events.
// ---------------------------------------------------------------------------

func TestRun_HappyPath_EmitsResultEnvelope(t *testing.T) {
	res, err := runWithBashFixture(t, happyRequest(t, "happy"))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q, want success", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("ExitCode: got %d, want 0", res.ExitCode)
	}
	if res.TurnsUsed != 2 {
		t.Errorf("TurnsUsed: got %d, want 2", res.TurnsUsed)
	}
	if res.DurationMs <= 0 {
		t.Errorf("DurationMs: got %d, want > 0", res.DurationMs)
	}
	if len(res.StdoutTail) != 4 {
		t.Errorf("StdoutTail length: got %d, want 4", len(res.StdoutTail))
	}
	if res.RunID != "rid-happy" {
		t.Errorf("RunID echo: got %q, want rid-happy", res.RunID)
	}
}

// ---------------------------------------------------------------------------
// Activity timeout — fixture sleeps longer than ActivityTimeoutSecs; result
// should report activity_timeout outcome and a non-success exit.
// ---------------------------------------------------------------------------

func TestRun_ActivityTimeout_Fires(t *testing.T) {
	req := happyRequest(t, "slow")
	req.ActivityTimeoutSecs = 1
	req.EnvOverrides["FAKE_AGENT_SLEEP"] = "10"
	start := time.Now()
	res, err := runWithBashFixture(t, req)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeActivityTimeout {
		t.Errorf("Outcome: got %q, want activity_timeout (elapsed=%v)", res.Outcome, elapsed)
	}
	// Bound the wall-clock so a regression that fails to fire the timer
	// gets caught — the agent's sleep is 10s, but timer + grace (5s) +
	// a generous buffer should keep us under 12s.
	if elapsed > 12*time.Second {
		t.Errorf("activity timeout took too long: %v", elapsed)
	}
}

// ---------------------------------------------------------------------------
// Caller cancellation — context.Cancel() must terminate the agent within
// the SIGTERM → SIGKILL grace window and still produce a result envelope.
// ---------------------------------------------------------------------------

func TestRun_CallerCancellation_Terminates(t *testing.T) {
	script := fakeAgentPath(t)
	sup := New(nil, nil)
	sup.SetBinary(script)
	req := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		RunID:        "rid-hang",
		Label:        "tester",
		Model:        "fake",
		PromptFile:   script,
		EnvOverrides: map[string]string{"FAKE_AGENT_MODE": "hang"},
	}

	ctx, cancel := context.WithCancel(context.Background())
	go func() {
		time.Sleep(200 * time.Millisecond)
		cancel()
	}()
	start := time.Now()
	res, err := sup.Run(ctx, req)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if elapsed > 8*time.Second {
		t.Errorf("cancellation took too long: %v (SIGTERM grace is %v)", elapsed, killGrace)
	}
	if res.ExitCode == 0 {
		t.Errorf("ExitCode: got 0, want non-zero (process was signalled)")
	}
	// Even a partially-emitted stream should leave at least one line in
	// the ring buffer — the fixture emits a turn_started before sleeping.
	if len(res.StdoutTail) == 0 {
		t.Error("StdoutTail empty; expected at least the turn_started event")
	}
}

// ---------------------------------------------------------------------------
// Ring buffer overflow — fixture emits 100 lines; tail must hold lines 51..100.
// ---------------------------------------------------------------------------

func TestRun_RingBufferOverflow_KeepsLatest50(t *testing.T) {
	req := happyRequest(t, "flood")
	req.EnvOverrides["FAKE_AGENT_LINES"] = "100"
	res, err := runWithBashFixture(t, req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Fatalf("Outcome: got %q, want success", res.Outcome)
	}
	if got, want := len(res.StdoutTail), proto.StdoutTailMaxLines; got != want {
		t.Fatalf("StdoutTail length: got %d, want %d", got, want)
	}
	first := res.StdoutTail[0]
	last := res.StdoutTail[len(res.StdoutTail)-1]
	if !strings.Contains(first, "\"turn\":51") {
		t.Errorf("StdoutTail[0]: got %q, want a line containing turn 51", first)
	}
	if !strings.Contains(last, "\"turn\":100") {
		t.Errorf("StdoutTail[last]: got %q, want a line containing turn 100", last)
	}
	if res.TurnsUsed != 100 {
		t.Errorf("TurnsUsed: got %d, want 100", res.TurnsUsed)
	}
}

// ---------------------------------------------------------------------------
// Malformed JSON — mixed valid + non-JSON lines; success outcome, ring
// buffer captures everything, only typed events count toward TurnsUsed.
// ---------------------------------------------------------------------------

func TestRun_MalformedLines_NotFatal(t *testing.T) {
	res, err := runWithBashFixture(t, happyRequest(t, "mixed"))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q, want success", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("ExitCode: got %d, want 0", res.ExitCode)
	}
	if res.TurnsUsed != 1 {
		t.Errorf("TurnsUsed: got %d, want 1", res.TurnsUsed)
	}
	if len(res.StdoutTail) != 3 {
		t.Errorf("StdoutTail length: got %d, want 3 (every line, valid or not)", len(res.StdoutTail))
	}
}

// ---------------------------------------------------------------------------
// Long line — fixture emits a single ~200 KB line; default bufio.Scanner
// buffer would drop it. The supervisor must keep it in the ring buffer.
// ---------------------------------------------------------------------------

func TestRun_LongLine_NotDropped(t *testing.T) {
	res, err := runWithBashFixture(t, happyRequest(t, "long_line"))
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Fatalf("Outcome: got %q, want success", res.Outcome)
	}
	if len(res.StdoutTail) != 1 {
		t.Fatalf("StdoutTail length: got %d, want 1", len(res.StdoutTail))
	}
	if got := len(res.StdoutTail[0]); got < 200_000 {
		t.Errorf("StdoutTail[0] length: got %d, want >= 200000 (line truncation regression)", got)
	}
}

// ---------------------------------------------------------------------------
// Failure exit — fixture exits non-zero. Outcome must be fatal_error and
// the exit code must propagate.
// ---------------------------------------------------------------------------

func TestRun_NonZeroExit_FatalError(t *testing.T) {
	req := happyRequest(t, "fail")
	req.EnvOverrides["FAKE_AGENT_EXIT"] = "7"
	res, err := runWithBashFixture(t, req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeFatalError {
		t.Errorf("Outcome: got %q, want fatal_error", res.Outcome)
	}
	if res.ExitCode != 7 {
		t.Errorf("ExitCode: got %d, want 7", res.ExitCode)
	}
	if res.ErrorMessage == "" {
		t.Error("ErrorMessage empty; expected wait error to be captured")
	}
}

// ---------------------------------------------------------------------------
// Missing binary — start failure. We point the supervisor at a path that
// does not exist; Run must return a result envelope (not error) with
// fatal_error outcome and -1 exit code.
// ---------------------------------------------------------------------------

func TestRun_MissingBinary_StartFailureResult(t *testing.T) {
	sup := New(nil, nil)
	sup.SetBinary("/nonexistent/path/to/agent")
	req := &proto.AgentRequestV1{
		Proto:      proto.AgentRequestProtoV1,
		RunID:      "rid-missing",
		Label:      "scout",
		Model:      "fake",
		PromptFile: "/tmp/p",
	}
	res, err := sup.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run returned error (expected nil + result envelope): %v", err)
	}
	if res.Outcome != proto.OutcomeFatalError {
		t.Errorf("Outcome: got %q, want fatal_error", res.Outcome)
	}
	if res.ExitCode != -1 {
		t.Errorf("ExitCode: got %d, want -1", res.ExitCode)
	}
	if res.ErrorMessage == "" {
		t.Error("ErrorMessage empty; expected start failure to be captured")
	}
}

// ---------------------------------------------------------------------------
// buildArgs — pure unit tests that don't require a fixture.
// ---------------------------------------------------------------------------

func TestBuildArgs_MinimalRequest(t *testing.T) {
	req := &proto.AgentRequestV1{
		Proto:      proto.AgentRequestProtoV1,
		Label:      "coder",
		Model:      "claude-opus-4-7",
		PromptFile: "/tmp/p.prompt",
	}
	got := buildArgs(req)
	want := []string{"-p", "--model", "claude-opus-4-7", "--output-format", "stream-json", "--prompt-file", "/tmp/p.prompt"}
	if strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("buildArgs: got %v, want %v", got, want)
	}
}

func TestBuildArgs_WithMaxTurns(t *testing.T) {
	req := &proto.AgentRequestV1{
		Proto:      proto.AgentRequestProtoV1,
		Label:      "coder",
		Model:      "M",
		PromptFile: "/p",
		MaxTurns:   25,
	}
	got := buildArgs(req)
	joined := strings.Join(got, " ")
	if !strings.Contains(joined, "--max-turns "+strconv.Itoa(25)) {
		t.Errorf("buildArgs missing --max-turns: %v", got)
	}
}

// ---------------------------------------------------------------------------
// mergeEnv — ensure overrides win, parent env is preserved otherwise.
// ---------------------------------------------------------------------------

func TestMergeEnv_OverrideAndAppend(t *testing.T) {
	base := []string{"PATH=/usr/bin", "HOME=/home/x", "MALFORMED"}
	overrides := map[string]string{
		"PATH": "/custom/bin:/usr/bin",
		"NEW":  "yes",
	}
	got := mergeEnv(base, overrides)
	joined := strings.Join(got, ";")
	if !strings.Contains(joined, "PATH=/custom/bin:/usr/bin") {
		t.Errorf("PATH not overridden: %v", got)
	}
	if !strings.Contains(joined, "HOME=/home/x") {
		t.Errorf("HOME unexpectedly removed: %v", got)
	}
	if !strings.Contains(joined, "NEW=yes") {
		t.Errorf("NEW not appended: %v", got)
	}
	if !strings.Contains(joined, "MALFORMED") {
		t.Errorf("malformed entry stripped: %v", got)
	}
}

func TestMergeEnv_NoOverridesReturnsBase(t *testing.T) {
	base := []string{"X=1", "Y=2"}
	got := mergeEnv(base, nil)
	if len(got) != len(base) {
		t.Fatalf("len: got %d, want %d", len(got), len(base))
	}
	for i := range base {
		if got[i] != base[i] {
			t.Errorf("got[%d]=%q, want %q", i, got[i], base[i])
		}
	}
}

// ---------------------------------------------------------------------------
// outcomeFor — pure helper.
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// m09 — activity timer override via fsnotify. Fixture writes files with no
// stdout; supervisor must see fs activity and reset the timer instead of
// killing the agent.
// ---------------------------------------------------------------------------

func TestRun_ActivityOverride_FsWritesPreventKill(t *testing.T) {
	script := fakeAgentPath(t)
	workdir := t.TempDir()
	sup := New(nil, nil)
	sup.SetBinary(script)
	req := &proto.AgentRequestV1{
		Proto:               proto.AgentRequestProtoV1,
		RunID:               "rid-fs-override",
		Label:               "tester",
		Model:               "fake",
		PromptFile:          script,
		WorkingDir:          workdir,
		ActivityTimeoutSecs: 1,
		EnvOverrides: map[string]string{
			"FAKE_AGENT_MODE":        "silent_fs_writer",
			"FAKE_AGENT_WORKDIR":     workdir,
			"FAKE_AGENT_FS_INTERVAL": "0.5",
			// 4 writes × 0.5s = 2s of runtime, which spans past the 1s
			// activity timeout and forces at least one override before the
			// agent finishes. Stays well under the 3-shot cap.
			"FAKE_AGENT_FS_COUNT": "4",
		},
	}

	res, err := sup.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeSuccess {
		t.Errorf("Outcome: got %q, want success — fsnotify override should have prevented activity_timeout", res.Outcome)
	}
	if res.ExitCode != 0 {
		t.Errorf("ExitCode: got %d, want 0", res.ExitCode)
	}
}

// TestRun_ActivityOverride_NoWritesStillTimesOut confirms the reverse — when
// the agent emits no stdout AND no filesystem activity, the timer fires as
// expected (the override path is gated on real activity, not on the watcher
// being instantiated).
func TestRun_ActivityOverride_NoWritesStillTimesOut(t *testing.T) {
	script := fakeAgentPath(t)
	workdir := t.TempDir()
	sup := New(nil, nil)
	sup.SetBinary(script)
	req := &proto.AgentRequestV1{
		Proto:               proto.AgentRequestProtoV1,
		RunID:               "rid-no-fs",
		Label:               "tester",
		Model:               "fake",
		PromptFile:          script,
		WorkingDir:          workdir,
		ActivityTimeoutSecs: 1,
		EnvOverrides: map[string]string{
			"FAKE_AGENT_MODE":  "silent_no_writes",
			"FAKE_AGENT_SLEEP": "10",
		},
	}

	start := time.Now()
	res, err := sup.Run(context.Background(), req)
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Outcome != proto.OutcomeActivityTimeout {
		t.Errorf("Outcome: got %q, want activity_timeout (elapsed=%v)", res.Outcome, elapsed)
	}
	if elapsed > 12*time.Second {
		t.Errorf("activity timeout took too long: %v", elapsed)
	}
}

// ---------------------------------------------------------------------------
// m09 — handleActivityTimeout pure-helper coverage. Drives the override
// counter, cap exhaustion, and no-watcher path without spawning a process.
// ---------------------------------------------------------------------------

// fakeWatcher implements just enough of the *ActivityWatcher contract to
// exercise handleActivityTimeout. We can't substitute it directly because
// the input type is a concrete *ActivityWatcher, but the helper code paths
// that use the watcher are gated on nil. The non-fake branches build a
// real watcher rooted at a temp dir and trigger writes.

// timerStub captures Reset calls to assert the timer was rearmed.
type timerStub struct {
	resets atomic.Int32
}

func (s *timerStub) Reset(time.Duration) bool {
	s.resets.Add(1)
	return true
}

func TestHandleActivityTimeout_NoWatcherFiresTimeout(t *testing.T) {
	sup := New(nil, nil)
	var lastActivity atomic.Int64
	lastActivity.Store(time.Now().UnixNano())
	var overrideCount atomic.Int32
	var cancelReason atomic.Value
	cancelCalled := false

	var dummyTimer *time.Timer
	in := activityTimeoutInputs{
		label:         "tester",
		watcher:       nil,
		timer:         &dummyTimer,
		timeout:       time.Second,
		lastActivity:  &lastActivity,
		overrideCount: &overrideCount,
		cancel:        func() { cancelCalled = true },
		cancelReason:  &cancelReason,
	}
	sup.handleActivityTimeout(in)

	if !cancelCalled {
		t.Errorf("cancel not called — nil watcher should always fire timeout")
	}
	reason, _ := cancelReason.Load().(string)
	if reason != "activity_timeout" {
		t.Errorf("cancelReason: got %q, want activity_timeout", reason)
	}
	if got := overrideCount.Load(); got != 0 {
		t.Errorf("overrideCount: got %d, want 0 (no watcher = no override)", got)
	}
}

func TestHandleActivityTimeout_OverrideCapExhausted(t *testing.T) {
	sup := New(nil, nil)
	var lastActivity atomic.Int64
	lastActivity.Store(time.Now().UnixNano())
	var overrideCount atomic.Int32
	overrideCount.Store(activityOverrideCap) // already at cap
	var cancelReason atomic.Value
	cancelCalled := false

	// Real watcher, real activity. With cap exhausted, the helper must
	// still fire the timeout — that is the safety valve.
	dir := t.TempDir()
	w, err := NewActivityWatcher(dir)
	if err != nil {
		t.Fatalf("watcher: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })
	time.Sleep(50 * time.Millisecond)
	touchFile(t, dir, "force.txt")
	time.Sleep(100 * time.Millisecond)

	var dummyTimer *time.Timer
	in := activityTimeoutInputs{
		label:         "tester",
		watcher:       w,
		timer:         &dummyTimer,
		timeout:       time.Second,
		lastActivity:  &lastActivity,
		overrideCount: &overrideCount,
		cancel:        func() { cancelCalled = true },
		cancelReason:  &cancelReason,
	}
	sup.handleActivityTimeout(in)

	if !cancelCalled {
		t.Errorf("cancel not called — cap-exhausted override should fire timeout")
	}
}

func TestHandleActivityTimeout_OverridesAndResetsTimer(t *testing.T) {
	sup := New(nil, nil)
	dir := t.TempDir()
	w, err := NewActivityWatcher(dir)
	if err != nil {
		t.Fatalf("watcher: %v", err)
	}
	t.Cleanup(func() { _ = w.Close() })

	// Allow watcher to register before we trigger activity.
	time.Sleep(50 * time.Millisecond)

	stamp := time.Now()
	var lastActivity atomic.Int64
	lastActivity.Store(stamp.UnixNano())

	// Touch a file AFTER the lastActivity stamp so HadActivitySince fires.
	touchFile(t, dir, "trigger.txt")
	time.Sleep(150 * time.Millisecond)

	var overrideCount atomic.Int32
	var cancelReason atomic.Value
	cancelCalled := false

	// Use a real-ish timer we can observe via Reset. *time.Timer doesn't
	// directly expose reset count, so we use a stopped one and check that
	// the override path is taken (override count ticks up).
	timer := time.NewTimer(time.Hour)
	defer timer.Stop()

	in := activityTimeoutInputs{
		label:         "tester",
		watcher:       w,
		timer:         &timer,
		timeout:       time.Second,
		lastActivity:  &lastActivity,
		overrideCount: &overrideCount,
		cancel:        func() { cancelCalled = true },
		cancelReason:  &cancelReason,
	}
	sup.handleActivityTimeout(in)

	if cancelCalled {
		t.Errorf("cancel was called — fresh activity should have triggered an override")
	}
	if got := overrideCount.Load(); got != 1 {
		t.Errorf("overrideCount: got %d, want 1", got)
	}
	// lastActivity must be advanced past the original stamp.
	if !time.Unix(0, lastActivity.Load()).After(stamp) {
		t.Errorf("lastActivity not advanced past original stamp")
	}
}

func TestMaybeStartWatcher_EmptyWorkingDirReturnsNil(t *testing.T) {
	sup := New(nil, nil)
	req := &proto.AgentRequestV1{Label: "tester"}
	if w := sup.maybeStartWatcher(req); w != nil {
		t.Errorf("got watcher for empty WorkingDir, want nil")
	}
}

func TestMaybeStartWatcher_BogusWorkingDirReturnsNil(t *testing.T) {
	sup := New(nil, nil)
	req := &proto.AgentRequestV1{
		Label:      "tester",
		WorkingDir: "/nonexistent/path/that/should/not/exist",
	}
	if w := sup.maybeStartWatcher(req); w != nil {
		_ = w.Close()
		t.Errorf("got watcher for bogus WorkingDir, want nil")
	}
}

func TestMaybeStartWatcher_ValidDirReturnsWatcher(t *testing.T) {
	sup := New(nil, nil)
	req := &proto.AgentRequestV1{Label: "tester", WorkingDir: t.TempDir()}
	w := sup.maybeStartWatcher(req)
	if w == nil {
		t.Fatalf("got nil watcher for valid WorkingDir")
	}
	t.Cleanup(func() { _ = w.Close() })
}

// ---------------------------------------------------------------------------
// m09 — reaper unit coverage. POSIX reaper kills the leader; group-level
// reaping is exercised end-to-end via the Run integration tests above.
// ---------------------------------------------------------------------------

func TestReaper_KillBeforeAttachIsNoOp(t *testing.T) {
	r := newReaper()
	if err := r.Kill(); err != nil {
		t.Errorf("Kill before Attach: %v", err)
	}
}

func TestReaper_DetachBeforeAttachIsNoOp(t *testing.T) {
	r := newReaper()
	if err := r.Detach(); err != nil {
		t.Errorf("Detach before Attach: %v", err)
	}
}

func TestReaper_KillIsIdempotent(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("POSIX-only — Windows JobObject path covered by integration test")
	}
	if _, err := exec.LookPath("sleep"); err != nil {
		t.Skipf("sleep not on PATH: %v", err)
	}
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatalf("start: %v", err)
	}
	r := newReaper()
	if err := r.Attach(cmd); err != nil {
		t.Fatalf("Attach: %v", err)
	}
	if err := r.Kill(); err != nil {
		t.Errorf("first Kill: %v", err)
	}
	if err := r.Kill(); err != nil {
		t.Errorf("second Kill: %v", err)
	}
	_ = cmd.Wait()
}

// TestApplyProcAttr_SetsSetpgid verifies the m09 POSIX contract: applyProcAttr
// must set Setpgid = true on cmd.SysProcAttr BEFORE Start. The build-tagged
// Windows no-op is validated by cross-compile in the coder summary; this test
// covers the POSIX path where the process-group signal (`kill -- -pgid`) relies
// on the kernel having created a new group rooted at the child.
func TestApplyProcAttr_SetsSetpgid(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("applyProcAttr is a no-op on Windows; JobObject substitutes process-group semantics")
	}
	cmd := exec.Command("true")
	applyProcAttr(cmd)
	if cmd.SysProcAttr == nil {
		t.Fatal("SysProcAttr is nil after applyProcAttr — Setpgid cannot be set")
	}
	if !cmd.SysProcAttr.Setpgid {
		t.Errorf("SysProcAttr.Setpgid = false, want true")
	}
}

func TestOutcomeFor(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		reason   string
		expected string
	}{
		{"success no err", nil, "", proto.OutcomeSuccess},
		{"activity timeout overrides err", &exec.ExitError{}, "activity_timeout", proto.OutcomeActivityTimeout},
		{"non-nil err is fatal", &exec.ExitError{}, "", proto.OutcomeFatalError},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := outcomeFor(tc.err, tc.reason); got != tc.expected {
				t.Errorf("got %q, want %q", got, tc.expected)
			}
		})
	}
}
