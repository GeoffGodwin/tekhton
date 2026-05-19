// Package finalize is the Go-side orchestrator for the post-pipeline
// finalize chain. Before m21, lib/finalize.sh registered 26 bash hooks and
// the Go runner shelled out to it once per run. m21 ports the registry and
// run loop into Go, ports eight hooks to pure-Go bodies, and routes the
// remaining 18 bash-implemented hooks through lib/finalize_shim.sh
// (one bash process per hook). The eight pure-Go bodies are
// clear_state, archive_reports, mark_done, archive_milestone,
// emit_run_memory, emit_run_summary, emit_timing_report,
// causal_log_finalize. Follow-up milestones (m22..m25) replace the bash
// shim cases one subsystem at a time without changing this orchestrator.
//
// Hook order is load-bearing — see lib/finalize.sh:218-243 for the
// authoritative registration order. orchestrator_test.go's order-mismatch
// guard fails red if the registration drifts.
package finalize

import (
	"context"
	"io"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Hook is the interface every finalize hook implements. The bash side passed
// the pipeline exit code as $1 and discarded the return value (chain never
// aborted). Go widens that contract by returning a typed error — the
// orchestrator logs the error and continues, mirroring the bash semantics,
// but having a typed error lets the parity gate distinguish a hook crash
// from a hook that ran to completion with non-fatal warnings.
type Hook interface {
	// Name returns the canonical hook name (matches the bash function name,
	// e.g. "_hook_emit_run_summary"). Used for logging, parity diffing, and
	// the order-mismatch test.
	Name() string

	// Run executes the hook against the given Input. A non-nil error is
	// logged by the orchestrator but does not abort the chain.
	Run(ctx context.Context, in *Input) error
}

// Input is the bundle every hook receives. Built once per Run by the
// orchestrator. ExitCode mirrors the legacy bash `$1` so existing hook
// bodies still see "pipeline_exit_code" semantics; the rest of the fields
// are Go additions that future hook bodies can read instead of reaching
// back into shell globals.
type Input struct {
	// ExitCode is the pipeline exit code the runner observed. 0 on success.
	ExitCode int

	// Disposition is the run-level disposition the runner emits onto the
	// RunResultV1 envelope. Hooks that previously branched on success vs
	// failure (e.g. _hook_clear_state, _hook_mark_done) can read this as a
	// typed alternative to inferring from ExitCode.
	Disposition string

	// Result is the structured RunResultV1 the runner just wrote to disk
	// (or nil when finalize is invoked without a captured result — the
	// `tekhton finalize` debug subcommand passes a non-nil Result; the
	// runner always passes a non-nil Result).
	Result *proto.RunResultV1

	// ResultPath is the on-disk location of Result. Bash-shim hooks read it
	// via TEKHTON_RUN_RESULT_FILE in the environment.
	ResultPath string

	// TekhtonHome / ProjectDir are the two-directory model anchors. Hooks
	// that exec bash use TekhtonHome to locate the shim dispatcher.
	TekhtonHome string
	ProjectDir  string

	// LogDir is where stage logs live for the current run. Defaults to
	// $PROJECT_DIR/.claude/logs when unset.
	LogDir string

	// Timestamp is the run timestamp used as a suffix on archived files
	// (e.g. RUN_SUMMARY_<timestamp>.json). Format: YYYYMMDD_HHMMSS.
	Timestamp string

	// Env is the environment array passed to bash-shim hooks. Built by the
	// runner before the chain starts so every shim invocation sees the same
	// env (and so test harnesses can substitute it).
	Env []string

	// Log is where hooks (Go or shim) write their own diagnostic output.
	// Defaults to os.Stderr.
	Log io.Writer

	// Milestone is the currently active milestone id (e.g. "m21"), or empty
	// when not running in milestone mode. Hooks that mark/archive milestones
	// read this.
	Milestone string

	// MilestoneMode mirrors the legacy MILESTONE_MODE bash global — true when
	// the run was invoked with --milestone.
	MilestoneMode bool

	// Disposition for the milestone (e.g. COMPLETE_AND_CONTINUE,
	// COMPLETE_AND_WAIT, IN_PROGRESS). The bash _CACHED_DISPOSITION mirror.
	MilestoneDisposition string

	// RunRequest is the run-level request envelope the runner built before
	// dispatching to finalize. m26 adds this so the finalize shim can hand
	// it to the EnvBuilder (the producer of the bash-subprocess env) and
	// every finalize hook sees the same composed env as the stages did.
	// Nil during the `tekhton finalize` debug subcommand; production
	// always supplies a non-nil request.
	RunRequest *proto.RunRequestV1

	// EnvKV is the env contract for finalize hooks, pre-composed by the
	// runner via runner.EnvBuilder.AsKV and handed in here. The shim
	// appends per-hook disposition keys (PIPELINE_EXIT_CODE etc.) before
	// exec; pure-Go hooks ignore the field. When nil, the shim falls back
	// to the legacy hand-rolled env (compatibility shim for callers that
	// haven't been wired through the new builder yet — drops out once
	// every caller assigns this field).
	EnvKV []string
}

// HookResult records one hook's per-run outcome — the orchestrator returns
// these in Summary so callers (parity gate, dashboard, causal log) can
// observe per-hook timing and failure status.
type HookResult struct {
	Name     string
	Duration time.Duration
	Err      error
}

// Summary aggregates per-hook results for a single finalize_run invocation.
// The orchestrator never returns a hook's error to its caller (the chain is
// continue-on-error by contract) — Summary is the structured way to read
// what happened.
type Summary struct {
	Hooks    []HookResult
	Duration time.Duration
}

// Failed returns the names of hooks that returned a non-nil error.
func (s *Summary) Failed() []string {
	var names []string
	for _, h := range s.Hooks {
		if h.Err != nil {
			names = append(names, h.Name)
		}
	}
	return names
}
