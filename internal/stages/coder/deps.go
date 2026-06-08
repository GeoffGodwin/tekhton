package coder

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/coder/buildfix"
	"github.com/geoffgodwin/tekhton/internal/coder/prerun"
	"github.com/geoffgodwin/tekhton/internal/coder/scout"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Deps is the orchestrator's dependency-injection seam. Every field is
// nullable: nil callers degrade to no-op or sane default. Production wires
// the real sub-package entry points + subprocess shims; tests substitute
// recording fakes per scenario.
//
// The Deps surface is intentionally broad: m39.4 closes the bash port arc
// and the orchestrator integrates with most of the pipeline surface
// (clarify, build/completion gates, indexer, dashboard, commit gate). Tests
// don't have to wire every field — they wire only the ones the exercised
// path touches.
type Deps struct {
	// --- Sub-package entry points (m39.1/3) ---

	// PrerunRun delegates to internal/coder/prerun.Run.
	PrerunRun func(ctx context.Context, cfg *prerun.Config) (*prerun.Result, error)

	// ScoutRun delegates to internal/coder/scout.Run.
	ScoutRun func(ctx context.Context, cfg *scout.Config) (*scout.Result, error)

	// BuildFixRun delegates to internal/coder/buildfix.Run.
	BuildFixRun func(ctx context.Context, cfg *buildfix.LoopConfig, paths *buildfix.Paths) (*buildfix.LoopResult, error)

	// --- Agent + prompt seams ---

	// RunAgent dispatches the senior coder + continuation agents. Production
	// wires the in-process supervisor; tests substitute recording fakes.
	RunAgent func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)

	// RenderPrompt renders the named template against vars. Production wires
	// internal/prompt.Render; tests substitute a recording stub.
	RenderPrompt func(name string, vars map[string]string) (string, error)

	// --- Pipeline plumbing (subprocess shims) ---

	// RunBuildGate execs `tekhton gate build --stage-label <label>`. Returns
	// nil on pass, non-nil on fail. The orchestrator routes failure to
	// BuildFixRun.
	RunBuildGate func(ctx context.Context, label string) error

	// RunCompletionGate execs `tekhton gate completion`. Returns nil on
	// pass, non-nil on fail.
	RunCompletionGate func(ctx context.Context) error

	// PopulateMilestoneBlock writes MILESTONE_BLOCK into the process env
	// (best-effort). Mirrors set_focused_milestone_block in bash.
	PopulateMilestoneBlock func(milestone string) error

	// ClarifyDetect execs `tekhton clarify detect --report <summary>` and
	// returns true when blocking items are present.
	ClarifyDetect func(ctx context.Context, summaryPath string) bool

	// ClarifyHandle execs `tekhton clarify handle --report <summary>
	// --project-dir <dir>`.
	ClarifyHandle func(ctx context.Context, summaryPath, projectDir string) error

	// TripCommitGate wraps trip_commit_gate from lib/finalize.sh. nil-safe.
	TripCommitGate func(reason string)

	// RecordTaskFileAssociation calls record_task_file_association via the
	// indexer subsystem. Best-effort.
	RecordTaskFileAssociation func(ctx context.Context, task, summaryPath string) error

	// --- Probes ---

	// IsSubstantiveWork mirrors lib/agent_helpers.sh::is_substantive_work.
	// Returns true when git state shows substantive tracked/untracked changes.
	IsSubstantiveWork func() bool

	// WasNullRun mirrors lib/agent_helpers.sh::was_null_run. Returns true
	// when the most-recent agent exited without doing meaningful work.
	WasNullRun func() bool

	// --- Escalation ---

	// SwitchToSubMilestone mirrors _switch_to_sub_milestone in bash.
	// Returns the new milestone id (e.g. "39.1") or empty when no split
	// was possible.
	SwitchToSubMilestone func(current string) (string, error)

	// HandleNullRunSplit mirrors handle_null_run_split. Returns true when a
	// split succeeded.
	HandleNullRunSplit func(ctx context.Context, current string) (bool, error)

	// GetSplitDepth returns the current recursive split depth for the
	// milestone id. Capped by Config.MaxSplitDepth.
	GetSplitDepth func(current string) int

	// WritePipelineState wraps lib/state.sh::write_pipeline_state.
	WritePipelineState func(stage, exitReason, resumeFlag, task, notes string) error

	// --- Continuation ---

	// BuildContinuationContext renders the "## Continuation Context" block
	// that gets injected into the prompt vars on attempt N.
	BuildContinuationContext func(stage string, attempt, max, cumulative, budget int) string

	// --- I/O helpers ---

	// GitTrackedNameOnly returns the output of `git diff --name-only HEAD`.
	GitTrackedNameOnly func() (string, error)

	// GitDiffStat returns the output of `git diff --stat HEAD`.
	GitDiffStat func() (string, error)

	// GitUntrackedFiles returns the output of `git ls-files --others
	// --exclude-standard`. The reconstruct synthesizer filters .claude/logs/
	// and the session-dir basename.
	GitUntrackedFiles func() (string, error)

	// SafeReadFile reads a file under a 1MB cap, returning "" on error.
	// Mirrors lib/prompts_io.sh::_safe_read_file.
	SafeReadFile func(path, label string) (string, error)
}

// DefaultDeps returns a no-op Deps suitable for tests that don't exercise
// any sub-paths. Production callers populate the fields they need.
func DefaultDeps() *Deps { return &Deps{} }
