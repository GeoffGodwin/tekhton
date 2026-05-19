// Package runner owns `tekhton run` — the run-level entry point that drives
// either a single pipeline attempt (--task non-complete mode) or the outer
// retry loop (--complete mode), bridging to bash for pre-flight, finalize, and
// the TUI sidecar.
//
// m19 ports the outer retry loop (run_complete_loop in
// lib/orchestrate_main.sh) and the run-flag CLI surface from tekhton.sh into
// this package. The per-attempt scheduler (m18 internal/pipeline.Runner) is
// still the workhorse — runner glues it together with PIPELINE_STATE, the
// finalize chain, and the TUI sidecar.
//
// What is NOT ported here (still bash, see DESIGN_v4.md Phase 5):
//   - lib/preflight.sh (invoked via Preflight subprocess)
//   - lib/finalize.sh hook chain (invoked via Finalize subprocess)
//   - mid-run TUI status writers in lib/tui_ops.sh (sidecar reads them)
//   - milestone-acceptance check (shell-out from RunCompleteLoop)
//   - HUMAN_NOTES.md parsing (handled inside intake/coder stages)
//   - auto-advance prompt + smart-resume escalation (lib/orchestrate_aux.sh)
package runner

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/finalize"
	"github.com/geoffgodwin/tekhton/internal/preflight"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// Sentinel errors callers match with errors.Is.
var (
	// ErrInvalidRequest is returned by RunSingle/RunCompleteLoop when the
	// run request fails Validate.
	ErrInvalidRequest = errors.New("runner: invalid run request")

	// ErrPreflightBlocked is returned when the bash pre-flight script reports
	// blocking issues that the runner cannot continue past.
	ErrPreflightBlocked = errors.New("runner: preflight blocked")

	// ErrSafetyBound is returned by RunCompleteLoop when one of the three
	// safety bounds (max_attempts / timeout / agent_cap) trips.
	ErrSafetyBound = errors.New("runner: safety bound reached")

	// ErrStuck is returned by RunCompleteLoop when the no-progress detector
	// trips two iterations in a row.
	ErrStuck = errors.New("runner: pipeline stuck")
)

// Pipeline is the per-attempt scheduler interface RunSingle/RunCompleteLoop
// use to drive one pass through the stage order. The default implementation
// is *pipeline.Runner from m18; tests substitute a fake.
type Pipeline interface {
	RunAttempt(ctx context.Context, req *proto.PipelineAttemptRequestV1) (*proto.PipelineAttemptResultV1, error)
}

// HookRunner abstracts the bash bridge for pre-flight and finalize. The
// default implementation execs `bash <script>` with the env passed through;
// tests substitute a fake to assert what would have been invoked.
type HookRunner interface {
	Preflight(ctx context.Context, req *proto.RunRequestV1) error
	Finalize(ctx context.Context, req *proto.RunRequestV1, res *proto.RunResultV1) error
}

// TUI is the optional Python sidecar lifecycle interface. Nil disables it.
type TUI interface {
	Start(ctx context.Context) error
	Stop(ctx context.Context, holdEnter bool) error
}

// AcceptanceChecker abstracts the bash milestone-acceptance shell-out.
// Returns true if acceptance passed; false otherwise. The default
// implementation execs `bash -c "source lib/milestone_acceptance.sh; ..."`.
type AcceptanceChecker interface {
	Check(ctx context.Context, milestone string) (bool, error)
}

// Runner glues pipeline.Runner, the bash hook bridges, the optional TUI
// sidecar, and PIPELINE_STATE persistence into the run-level entry point.
type Runner struct {
	Pipeline   Pipeline
	State      *state.Store
	Hooks      HookRunner
	TUI        TUI
	Acceptance AcceptanceChecker

	// Env composes the bash subprocess env (m26 StageEnvV1 contract) from
	// pipeline.conf + run-request flags + per-stage overrides. Nil falls
	// back to a defaults-only builder built lazily at first use, which
	// keeps existing tests that wire the Runner directly working — the
	// production path in cmd/tekhton/run.go always assigns this field.
	Env *EnvBuilder

	// ProjectDir / TekhtonHome are the ambient context the CLI layer captures
	// at flag-parse time. Resume() uses them to refill the rebuilt
	// RunRequestV1 because the on-disk state envelope does not carry them
	// (the bash state writer never put them in the snapshot — by Phase 5 they
	// will live in snap.Extra and these fields become redundant).
	ProjectDir  string
	TekhtonHome string

	// Stdout / Stderr the runner uses for status messages. Defaults to
	// os.Stdout / os.Stderr.
	Stdout *os.File
	Stderr *os.File

	// Now overrides time for tests. Defaults to time.Now.
	Now func() time.Time

	// Defaults applied when a RunRequestV1 leaves a bound at zero.
	DefaultMaxPipelineAttempts     int
	DefaultAutonomousTimeoutSecs   int
	DefaultMaxAutonomousAgentCalls int

	// Result file path the finalize bridge reads via TEKHTON_RUN_RESULT_FILE.
	// Defaults to "<project_dir>/.tekhton/RUN_RESULT.json".
	RunResultFile string
}

// New constructs a Runner with defaults filled in.
func New(p Pipeline) *Runner {
	return &Runner{
		Pipeline:                       p,
		Stdout:                         os.Stdout,
		Stderr:                         os.Stderr,
		Now:                            time.Now,
		DefaultMaxPipelineAttempts:     5,
		DefaultAutonomousTimeoutSecs:   7200,
		DefaultMaxAutonomousAgentCalls: 200,
	}
}

// effectiveBounds returns the loop bounds after request overrides + runner
// defaults. Zero in the request means use the default.
func (r *Runner) effectiveBounds(req *proto.RunRequestV1) (maxAttempts, timeoutSecs, maxCalls int) {
	maxAttempts = req.MaxPipelineAttempts
	if maxAttempts == 0 {
		maxAttempts = r.DefaultMaxPipelineAttempts
	}
	timeoutSecs = req.AutonomousTimeoutSecs
	if timeoutSecs == 0 {
		timeoutSecs = r.DefaultAutonomousTimeoutSecs
	}
	maxCalls = req.MaxAutonomousAgentCalls
	if maxCalls == 0 {
		maxCalls = r.DefaultMaxAutonomousAgentCalls
	}
	return
}

// resultPath returns the configured RunResultFile or the default under the
// project directory.
func (r *Runner) resultPath(req *proto.RunRequestV1) string {
	if r.RunResultFile != "" {
		return r.RunResultFile
	}
	return filepath.Join(req.ProjectDir, ".tekhton", "RUN_RESULT.json")
}

// writeResult atomically writes the run result to disk so the finalize bridge
// can pick it up via TEKHTON_RUN_RESULT_FILE. tmpfile + rename mirrors the
// m03 state-write pattern.
func (r *Runner) writeResult(path string, res *proto.RunResultV1) error {
	if path == "" {
		return nil
	}
	res.EnsureProto()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("runner: mkdir result dir: %w", err)
	}
	b, err := res.MarshalIndented()
	if err != nil {
		return fmt.Errorf("runner: marshal result: %w", err)
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return fmt.Errorf("runner: write result tmp: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("runner: rename result: %w", err)
	}
	return nil
}

// validateAndDefault stamps proto, validates the request, and is the gate
// every entry point goes through.
func (r *Runner) validateAndDefault(req *proto.RunRequestV1) error {
	if req == nil {
		return fmt.Errorf("%w: nil request", ErrInvalidRequest)
	}
	req.EnsureProto()
	if err := req.Validate(); err != nil {
		return fmt.Errorf("%w: %v", ErrInvalidRequest, err)
	}
	return nil
}

// BashHookRunner is the default HookRunner — execs `bash <script>` with the
// disposition env vars threaded through.
type BashHookRunner struct {
	TekhtonHome string

	// Stdout / Stderr inherited by the bash subprocess. Defaults to
	// os.Stdout / os.Stderr when nil.
	Stdout *os.File
	Stderr *os.File

	// Env is the m26 builder that produces the bash subprocess env for
	// finalize hooks. Populated by cmd/tekhton/run.go alongside the
	// runner's Env. Nil ⇒ finalize falls back to the legacy hand-rolled
	// env (compatibility path; logs a one-line warning).
	Env *EnvBuilder
}

// Preflight constructs the Go preflight orchestrator and runs the chain
// in-process. m22 ports the bash subsystem (lib/preflight*.sh, deleted in
// the same milestone) to internal/preflight, so there is no longer any
// bash subprocess on the pre-run boundary — the Go orchestrator writes
// PREFLIGHT_REPORT.md directly and surfaces blockers via HasBlockers.
//
// The receiver's Stdout/Stderr default to os.Stdout/os.Stderr when nil so
// the in-process orchestrator and any future bash-shim hooks share the
// same diagnostic stream the V3 entry point used.
func (b *BashHookRunner) Preflight(ctx context.Context, req *proto.RunRequestV1) error {
	if b.TekhtonHome == "" {
		return nil
	}
	o := preflight.NewOrchestrator(b.TekhtonHome, req.ProjectDir)
	o.Log = stderrOr(b.Stderr)
	if _, err := o.Run(ctx); err != nil {
		return fmt.Errorf("preflight: %w", err)
	}
	fmt.Fprintln(stderrOr(b.Stderr), o.SummaryLine())
	if o.HasBlockers() {
		return fmt.Errorf("%w: see %s", ErrPreflightBlocked,
			filepath.Join(req.ProjectDir, ".tekhton", "PREFLIGHT_REPORT.md"))
	}
	return nil
}

// Finalize builds the Go finalize orchestrator and runs it. m21 moved hook
// registration, sequencing, and per-hook error handling from
// lib/finalize.sh into internal/finalize. Pure-Go hooks (clear_state,
// archive_reports, mark_done, archive_milestone, emit_run_memory,
// emit_run_summary, emit_timing_report, causal_log_finalize) execute
// directly; the remaining hooks are dispatched to bash one at a time via
// lib/finalize_shim.sh.
//
// The chain is continue-on-error by contract — a failing hook is logged
// but does not abort the rest of the finalize sequence (mirrors the bash
// finalize_run loop).
func (b *BashHookRunner) Finalize(ctx context.Context, req *proto.RunRequestV1, res *proto.RunResultV1) error {
	if b.TekhtonHome == "" {
		return nil
	}
	if res == nil {
		return nil
	}
	orch := finalize.NewOrchestrator(b.TekhtonHome, req.ProjectDir)
	exitCode := 0
	if res.Disposition != proto.RunDispositionSuccess {
		exitCode = 1
	}
	// Compute the milestone disposition the bash side used to cache in
	// _CACHED_DISPOSITION. Three Go hooks (clear_state / mark_done /
	// archive_milestone) gate on this — empty string makes them all
	// no-ops, which would silently break milestone close-out for every
	// Go-orchestrated run. RunCompleteLoop already gates success on
	// acceptance passing, so a successful milestone run reliably maps to
	// COMPLETE_AND_CONTINUE here. (COMPLETE_AND_WAIT is only meaningful
	// for the bash auto-advance flow, which stays bash in Phase 5.)
	var milestoneDisposition string
	if req.Mode == proto.RunModeMilestone && res.Disposition == proto.RunDispositionSuccess {
		milestoneDisposition = "COMPLETE_AND_CONTINUE"
	}
	in := &finalize.Input{
		ExitCode:             exitCode,
		Disposition:          res.Disposition,
		Result:               res,
		ResultPath:           filepath.Join(req.ProjectDir, ".tekhton", "RUN_RESULT.json"),
		TekhtonHome:          b.TekhtonHome,
		ProjectDir:           req.ProjectDir,
		Milestone:            req.Milestone,
		MilestoneMode:        req.Mode == proto.RunModeMilestone,
		MilestoneDisposition: milestoneDisposition,
		RunRequest:           req,
		Log:                  stderrOr(b.Stderr),
	}
	in.LogDir = filepath.Join(req.ProjectDir, ".claude", "logs")
	in.Timestamp = time.Now().UTC().Format("20060102_150405")
	// m26: compose the finalize-hook env from the same builder that fed
	// the stage subprocesses. EnvKV is consumed by BashShimHook.buildEnv
	// in place of the legacy hand-rolled env. Pure-Go hooks ignore it.
	if b.Env != nil {
		envProto := b.Env.Compose(req, nil)
		// Force the LOG_FILE the finalize chain sees to match the runner's
		// log timestamp (the builder picks up b.Env.log which was wired at
		// construction time; we override here for the finalize-scoped
		// timestamp, which is fresh per chain).
		if envProto.LogDir != "" {
			envProto.Timestamp = in.Timestamp
			envProto.LogFile = (LogContext{Dir: in.LogDir, Timestamp: in.Timestamp}).LogFile(req)
		}
		in.EnvKV = b.Env.AsKV(envProto)
	}
	sum := orch.Run(ctx, in)
	// Failed hooks already logged inline by orchestrator; surface a summary
	// counter for visibility but never fail the run.
	_ = sum
	return nil
}

func stdoutOr(f *os.File) *os.File {
	if f == nil {
		return os.Stdout
	}
	return f
}

func stderrOr(f *os.File) *os.File {
	if f == nil {
		return os.Stderr
	}
	return f
}
