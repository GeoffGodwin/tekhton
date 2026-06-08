// Package prerun implements the M92 pre-coder clean sweep (m39.1 port).
//
// stages/coder_prerun.sh is sourced by stages/coder.sh and runs at the top
// of run_stage_coder(). It checks whether TEST_CMD passes BEFORE the coder
// runs; if failing, spawns a bounded Jr-Coder-class fix agent to restore a
// clean baseline. On success it re-captures the test baseline so downstream
// gates see the clean state. On failure it warns loudly and lets the
// pipeline proceed — the stricter post-run gates will surface the breakage.
//
// m39.1 ports the orchestrator + inner fix loop to Go without deleting the
// bash file. The bash version still serves the bash-coder path until m39.4
// deletes both files together.
package prerun

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Status names the orchestrator's terminal disposition. The m39.4
// orchestrator branches on this to decide its post-prerun log line.
type Status string

const (
	// StatusClean — TEST_CMD passed pre-coder (or dedup cache short-circuited);
	// no fix agent was invoked.
	StatusClean Status = "clean"
	// StatusFixed — TEST_CMD failed pre-coder; the fix agent succeeded and the
	// baseline was re-captured to reflect the post-fix state.
	StatusFixed Status = "fixed"
	// StatusFixFailed — TEST_CMD failed pre-coder; the fix agent exhausted its
	// MaxAttempts budget without restoring a clean state. Non-fatal — the
	// pipeline proceeds with a warning.
	StatusFixFailed Status = "fix_failed"
	// StatusSkipped — PRE_RUN_CLEAN_ENABLED=false or TEST_CMD effectively
	// empty ("" or "true"); the orchestrator returned without invoking the
	// agent or running TEST_CMD.
	StatusSkipped Status = "skipped"
)

// Default knob values. Kept as constants so the orchestrator can apply them
// when callers pass a zero-valued Config (the m39.4 orchestrator threads env
// → Config; tests pass Config{} to assert defaulting behavior).
const (
	DefaultMaxAttempts = 1
	DefaultMaxTurns    = 20
)

// Config holds the resolved knobs for a single Run() invocation. The m39.4
// orchestrator resolves env → Config once at coder-stage entry; tests pass
// Config{} to exercise the defaulting path.
type Config struct {
	// Enabled mirrors PRE_RUN_CLEAN_ENABLED. Default true on the bash side;
	// callers wire the env-resolved value. m39.4 is the canonical wiring
	// path; tests set this explicitly.
	Enabled bool

	// TestCmd mirrors TEST_CMD. An empty value (or the literal "true") is
	// treated as "no test command configured" and short-circuits to
	// StatusSkipped — matches stages/coder_prerun.sh:123.
	TestCmd string

	// MaxAttempts mirrors PRE_RUN_FIX_MAX_ATTEMPTS. Default 1
	// (DefaultMaxAttempts). The pre-run fix is intentionally cheap: one
	// shot, then proceed. Operators reading the pipeline log expect "Fix
	// attempt 1/1...". Do NOT bump the default — it would compound with the
	// M128 build-fix loop's BUILD_FIX_MAX_ATTEMPTS=3.
	MaxAttempts int

	// MaxTurns mirrors PRE_RUN_FIX_MAX_TURNS. Default 20 (DefaultMaxTurns) —
	// enough for a Jr Coder to fix a typical test-baseline regression without
	// spilling into senior-coder budget.
	MaxTurns int

	// Model mirrors PREFLIGHT_FIX_MODEL with CLAUDE_JR_CODER_MODEL fallback.
	// Empty value is acceptable — the caller (or downstream supervisor)
	// supplies the default.
	Model string

	// AgentTools mirrors AGENT_TOOLS_BUILD_FIX. Threaded into the agent
	// invocation verbatim.
	AgentTools string

	// LogFile mirrors LOG_FILE. Best-effort verify-output append; an empty
	// value disables the append.
	LogFile string

	// ProjectDir mirrors PROJECT_DIR. Used by Deps.DeleteBaselineJSON to
	// resolve the .claude/TEST_BASELINE.json path.
	ProjectDir string

	// Milestone is the current milestone id (passed to CaptureTestBaseline
	// on the successful-fix path).
	Milestone string
}

// Result is the orchestrator's return envelope. The m39.4 orchestrator
// logs Status and forwards Attempts to the run summary. Fields are
// informational once Status is set; do NOT branch on them.
type Result struct {
	// Status names the terminal disposition. See the Status constants.
	Status Status

	// Attempts is the number of fix-agent invocations the inner loop
	// executed. 0 for StatusClean / StatusSkipped; 1..MaxAttempts otherwise.
	Attempts int

	// InitialFails is the failure-line count (grep -ciE
	// '(FAIL|ERROR|error|failure)') from the pre-fix TEST_CMD output. 0 on
	// StatusClean / StatusSkipped.
	InitialFails int

	// FinalFails is the failure-line count from the last post-fix TEST_CMD
	// verification. 0 on StatusFixed (tests now pass). Mirrors InitialFails
	// on StatusClean / StatusSkipped (no fix run).
	FinalFails int

	// BaselineReCaptured is true when the fix-succeeded path successfully
	// deleted the stale baseline JSON and re-captured the baseline.
	BaselineReCaptured bool

	// FailureCountDelta is FinalFails - InitialFails. Informational — the
	// orchestrator's +2 threshold uses the raw values, not the delta.
	FailureCountDelta int

	// AbortReason names the reason runFixAgent broke out of the loop early.
	// Empty when the loop ran the full MaxAttempts budget or when no fix
	// agent ran at all. Set to "introduced_new_failures" when the +2
	// threshold tripped.
	AbortReason string
}

// Deps is the dependency-injection seam. The m39.4 orchestrator constructs
// it once and passes it to every Run() call; tests construct a Deps with
// recording function pointers to assert call order and arguments.
//
// Every field is nullable: an empty Deps is valid and degrades gracefully
// (Log/Warn/Success default to no-op; missing RunAgent panics — that is
// the orchestrator's bug, not a runtime concern). EmitEvent and
// CaptureTestBaseline are best-effort.
type Deps struct {
	// RunAgent invokes the bounded fix agent. The orchestrator constructs a
	// fresh proto.AgentRequestV1 per attempt — no caller state leaks into
	// the agent's environment. Production callers wire this to the
	// in-process supervisor; tests substitute a recording fake.
	RunAgent func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)

	// RenderPrompt renders the "preflight_fix" template with the
	// PREFLIGHT_TEST_OUTPUT and PREFLIGHT_CHANGED_FILES variables resolved
	// by the orchestrator. The string is the agent's prompt body.
	RenderPrompt func(name string, vars map[string]string) (string, error)

	// RunTestCmd runs cfg.TestCmd via bash -c and returns combined output
	// + exit code. The orchestrator never parses stderr/stdout separately
	// — the bash version does the same (`2>&1`).
	RunTestCmd func(ctx context.Context, cmd string) (output string, exitCode int, err error)

	// CaptureTestBaseline re-captures the test baseline after a successful
	// fix. Best-effort — failures log a warning and continue.
	CaptureTestBaseline func(milestone string) error

	// DeleteBaselineJSON removes the stale TEST_BASELINE.json so the
	// re-capture path runs fresh. Best-effort — failures log a warning and
	// continue. Order is load-bearing: this MUST be called before
	// CaptureTestBaseline (the bash version does the same at
	// coder_prerun.sh:156).
	DeleteBaselineJSON func() error

	// EmitEvent writes a causal event. Best-effort — the bash version wraps
	// every emit call in `> /dev/null 2>&1 || true`; the Go port preserves
	// the silent-on-error semantics by typing this as no-return.
	EmitEvent func(kind, scope, desc string)

	// TestDedupCanSkip mirrors lib/test_dedup.sh::test_dedup_can_skip. When
	// true, the orchestrator short-circuits (no agent call, no TEST_CMD run)
	// and returns StatusClean.
	TestDedupCanSkip func() bool

	// TestDedupRecordPass mirrors lib/test_dedup.sh::test_dedup_record_pass.
	// Called after a successful TEST_CMD verify so future runs can
	// short-circuit. Best-effort.
	TestDedupRecordPass func() error

	// AppendVerifyOutput appends the verify-output bytes to LogFile.
	// Best-effort; nil-Deps callers skip the append.
	AppendVerifyOutput func(path, content string) error

	// Log, Warn, Success surface progress to the operator. Default-nil
	// implementations are no-ops; production wires the orchestrator's
	// log helpers.
	Log     func(format string, args ...any)
	Warn    func(format string, args ...any)
	Success func(format string, args ...any)
}
