package supervisor

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// killGrace is the SIGTERM → SIGKILL grace period. exec.CommandContext on
// Go 1.20+ honors cmd.WaitDelay after the Cancel hook returns. Five seconds
// matches the V3 supervisor's `WAIT_DELAY` and gives an agent that traps
// SIGTERM enough room to flush its final JSON event.
const killGrace = 5 * time.Second

// activityOverrideCap is the m09 safety valve: when the activity timer fires
// and the fsnotify watcher reports recent file activity, the timer is reset
// up to this many times per Run before becoming permanent. Default 3 from
// the milestone design — pathological "writes one file every N minutes"
// loops are exactly what the timer is supposed to catch, so the cap exists
// to bound the override.
const activityOverrideCap = 3

// run is the m06 production path, extended in m09 with cross-platform
// process-tree reaping (Reaper) and fsnotify-driven activity-timer override
// (ActivityWatcher). It launches the agent binary under exec.CommandContext,
// scans stdout for JSON events, tees stderr to the causal log, and bounds
// idle time with an activity timer.
//
// The result is always non-nil for any valid request, even on failure paths;
// errors returned alongside it are reserved for envelope-level problems
// (nil request, validation failure). The supervisor maps process-level
// failures into AgentResultV1.ExitCode + Outcome instead.
func (s *Supervisor) run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	if req == nil {
		return nil, fmt.Errorf("supervisor: nil request")
	}
	if err := req.Validate(); err != nil {
		return nil, err
	}

	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()

	var cancelReason atomic.Value // string

	reaper := newReaper()
	defer func() { _ = reaper.Detach() }()

	cmd := buildCommand(runCtx, s.binary, req)
	cmd.Cancel = makeCancelHook(cmd, reaper)

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return startFailureResult(req, err), nil
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return startFailureResult(req, err), nil
	}

	started := time.Now()
	if err := cmd.Start(); err != nil {
		return startFailureResult(req, err), nil
	}

	if err := reaper.Attach(cmd); err != nil {
		s.emitSupervisorEvent(req.Label, "reaper_attach_failed", err.Error())
	}

	watcher := s.maybeStartWatcher(req)
	defer func() {
		if watcher != nil {
			_ = watcher.Close()
		}
	}()

	rb := newRingBuf(proto.StdoutTailMaxLines)
	activityTO := time.Duration(req.ActivityTimeoutSecs) * time.Second
	var lastActivity atomic.Int64
	lastActivity.Store(started.UnixNano())

	var timer *time.Timer
	var overrideCount atomic.Int32
	if activityTO > 0 {
		timer = time.AfterFunc(activityTO, func() {
			s.handleActivityTimeout(activityTimeoutInputs{
				label:         req.Label,
				watcher:       watcher,
				timer:         &timer,
				timeout:       activityTO,
				lastActivity:  &lastActivity,
				overrideCount: &overrideCount,
				cancel:        cancel,
				cancelReason:  &cancelReason,
			})
		})
		defer timer.Stop()
	}

	eventCh := make(chan event, 64)
	decoderDone := make(chan error, 1)
	go func() {
		var t activityTimer
		if timer != nil {
			t = timer
		}
		err := decode(runCtx, stdout, decoderConfig{
			timer:        t,
			timeout:      activityTO,
			lastActivity: &lastActivity,
			rb:           rb,
			out:          eventCh,
		})
		close(eventCh)
		decoderDone <- err
	}()

	stderrDone := make(chan struct{})
	go func() {
		defer close(stderrDone)
		teeStderr(stderr, s.causal, req.Label)
	}()

	var events []event
	eventsDone := make(chan struct{})
	go func() {
		defer close(eventsDone)
		for ev := range eventCh {
			events = append(events, ev)
		}
	}()

	waitErr := cmd.Wait()
	duration := time.Since(started)

	<-stderrDone
	<-decoderDone
	<-eventsDone

	res := &proto.AgentResultV1{
		Proto:      proto.AgentResultProtoV1,
		RunID:      req.RunID,
		Label:      req.Label,
		ExitCode:   exitCodeFromError(cmd, waitErr),
		TurnsUsed:  finalTurn(events),
		DurationMs: duration.Milliseconds(),
		StdoutTail: rb.snapshot(),
	}
	reason, _ := cancelReason.Load().(string)
	res.Outcome = outcomeFor(waitErr, reason)
	if waitErr != nil && res.Outcome != proto.OutcomeSuccess {
		res.ErrorMessage = waitErr.Error()
	}
	res.TrimStdoutTail()
	return res, nil
}

// activityTimeoutInputs bundles the seven values the timer callback needs.
// Splitting them out keeps the goroutine literal in run() short and makes
// handleActivityTimeout independently unit-testable.
type activityTimeoutInputs struct {
	label         string
	watcher       *ActivityWatcher
	timer         **time.Timer
	timeout       time.Duration
	lastActivity  *atomic.Int64
	overrideCount *atomic.Int32
	cancel        context.CancelFunc
	cancelReason  *atomic.Value
}

// handleActivityTimeout is the activity-timer callback. When fsnotify reports
// fresh writes since the last activity stamp AND the override cap is not yet
// exhausted, the timer is reset and the kill is suppressed. Otherwise the
// activity timeout fires and the run is cancelled.
func (s *Supervisor) handleActivityTimeout(in activityTimeoutInputs) {
	if in.watcher != nil && in.overrideCount.Load() < activityOverrideCap {
		lastResetTime := time.Unix(0, in.lastActivity.Load())
		if in.watcher.HadActivitySince(lastResetTime) {
			n := in.overrideCount.Add(1)
			in.lastActivity.Store(time.Now().UnixNano())
			if t := *in.timer; t != nil {
				t.Reset(in.timeout)
			}
			s.emitSupervisorEvent(in.label, "activity_timer_overridden",
				fmt.Sprintf("override=%d/%d", n, activityOverrideCap))
			return
		}
	}
	s.emitSupervisorEvent(in.label, "activity_timeout_fired",
		"no stdout or fs activity within window")
	in.cancelReason.Store("activity_timeout")
	in.cancel()
}

// maybeStartWatcher constructs an ActivityWatcher rooted at req.WorkingDir.
// Returns nil when WorkingDir is empty or initialization fails outright —
// the watcher is best-effort, the run continues either way. A causal event
// flags fallback (mtime-walk) mode so operators can investigate fsnotify
// init failures.
func (s *Supervisor) maybeStartWatcher(req *proto.AgentRequestV1) *ActivityWatcher {
	if req.WorkingDir == "" {
		return nil
	}
	w, err := NewActivityWatcher(req.WorkingDir)
	if err != nil {
		s.emitSupervisorEvent(req.Label, "activity_watcher_init_failed", err.Error())
		return nil
	}
	if w.IsFallback() {
		s.emitSupervisorEvent(req.Label, "activity_watcher_fallback",
			"fsnotify init failed; using mtime walk")
	}
	return w
}

// emitSupervisorEvent writes a `<label>\t<detail>` causal event on the
// `supervisor` stage. nil-causal-safe so tests using New(nil, nil) don't
// have to set up a log just to exercise the timer override path.
func (s *Supervisor) emitSupervisorEvent(label, evType, detail string) {
	if s.causal == nil {
		return
	}
	_, _ = s.causal.Emit(causal.EmitInput{
		Stage:  "supervisor",
		Type:   evType,
		Detail: fmt.Sprintf("%s\t%s", label, detail),
	})
}

// makeCancelHook returns the cmd.Cancel closure that drives reaper-based
// process-tree termination. Falls back to leader-only kill if the reaper
// can't terminate (e.g. Attach failed), so the cancel pathway always reaps
// at least the parent process. exec.CommandContext escalates to SIGKILL
// after WaitDelay regardless, which acts as a final backstop.
func makeCancelHook(cmd *exec.Cmd, reaper Reaper) func() error {
	return func() error {
		if err := reaper.Kill(); err == nil {
			return nil
		}
		if cmd.Process != nil {
			return cmd.Process.Kill()
		}
		return nil
	}
}

// buildCommand assembles the *exec.Cmd. Split out so tests can construct one
// without spawning a process and so build args are reviewable in one place.
// applyProcAttr is build-tagged: it sets Setpgid on POSIX (group reaping)
// and is a no-op on Windows (JobObject substitutes).
func buildCommand(ctx context.Context, bin string, req *proto.AgentRequestV1) *exec.Cmd {
	cmd := exec.CommandContext(ctx, bin, buildArgs(req)...)
	if req.WorkingDir != "" {
		cmd.Dir = req.WorkingDir
	}
	cmd.Env = mergeEnv(os.Environ(), req.EnvOverrides)
	applyProcAttr(cmd)
	cmd.WaitDelay = killGrace
	return cmd
}

// buildArgs renders an AgentRequestV1 into the agent CLI argv. The shape
// mirrors the V3 bash invocation in lib/agent.sh — `claude -p --model M
// --output-format stream-json` plus the optional knobs. The fake agent
// fixture parses these positionally; if the order changes the fixture must
// follow.
func buildArgs(req *proto.AgentRequestV1) []string {
	args := []string{
		"-p",
		"--model", req.Model,
		"--output-format", "stream-json",
	}
	if req.MaxTurns > 0 {
		args = append(args, "--max-turns", strconv.Itoa(req.MaxTurns))
	}
	if req.PromptFile != "" {
		args = append(args, "--prompt-file", req.PromptFile)
	}
	return args
}

// mergeEnv layers EnvOverrides onto the parent environment. Overrides take
// precedence; keys not already present are appended. Returns base unchanged
// when there are no overrides so the caller doesn't pay for a copy.
func mergeEnv(base []string, overrides map[string]string) []string {
	if len(overrides) == 0 {
		return base
	}
	seen := make(map[string]bool, len(overrides))
	out := make([]string, 0, len(base)+len(overrides))
	for _, e := range base {
		eq := strings.IndexByte(e, '=')
		if eq < 0 {
			out = append(out, e)
			continue
		}
		key := e[:eq]
		if v, ok := overrides[key]; ok {
			out = append(out, key+"="+v)
			seen[key] = true
		} else {
			out = append(out, e)
		}
	}
	for k, v := range overrides {
		if !seen[k] {
			out = append(out, k+"="+v)
		}
	}
	return out
}

// exitCodeFromError returns the agent's exit code from cmd.Wait()'s error.
// nil → 0; *exec.ExitError → its ExitCode (which is -1 if signalled);
// other (start failure, I/O) → -1.
func exitCodeFromError(cmd *exec.Cmd, waitErr error) int {
	if waitErr == nil {
		return 0
	}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		return exitErr.ExitCode()
	}
	if cmd.ProcessState != nil {
		return cmd.ProcessState.ExitCode()
	}
	return -1
}

// outcomeFor maps the (waitErr, cancelReason) tuple to a proto outcome
// string. The categorization is deliberately coarse for m06: success vs.
// activity_timeout vs. fatal_error. m07's retry envelope refines fatal_error
// into transient vs. fatal using the V3 error taxonomy.
func outcomeFor(waitErr error, cancelReason string) string {
	if cancelReason == "activity_timeout" {
		return proto.OutcomeActivityTimeout
	}
	if waitErr == nil {
		return proto.OutcomeSuccess
	}
	return proto.OutcomeFatalError
}

// startFailureResult shapes a result envelope for the rare path where the
// process never started (binary missing, pipe creation failed). The exit
// code is -1 because there is no real exit status; ErrorMessage carries the
// underlying cause so bash callers can diagnose the missing binary.
func startFailureResult(req *proto.AgentRequestV1, cause error) *proto.AgentResultV1 {
	return &proto.AgentResultV1{
		Proto:        proto.AgentResultProtoV1,
		RunID:        req.RunID,
		Label:        req.Label,
		ExitCode:     -1,
		Outcome:      proto.OutcomeFatalError,
		ErrorMessage: cause.Error(),
	}
}

// teeStderr forwards each stderr line as an `agent_stderr` event on the
// causal log. nil log means "discard" — the supervisor still has to drain
// the pipe so a chatty stderr cannot fill its kernel buffer and deadlock
// the agent.
func teeStderr(r io.Reader, log *causal.Log, label string) {
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, scannerInitBuf), scannerMaxBuf)
	for sc.Scan() {
		if log == nil {
			continue
		}
		_, _ = log.Emit(causal.EmitInput{
			Stage:  "supervisor",
			Type:   "agent_stderr",
			Detail: fmt.Sprintf("%s\t%s", label, sc.Text()),
		})
	}
}
