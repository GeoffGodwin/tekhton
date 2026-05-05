package supervisor

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
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
