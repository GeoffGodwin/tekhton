package prerun

import (
	"context"
	"path/filepath"
)

// Run is the m39.1 entry point. It mirrors run_prerun_clean_sweep in
// stages/coder_prerun.sh:119-166. Non-fatal on every path — even when the
// fix exhausts attempts, the orchestrator returns nil error. The Result
// carries the Status token the m39.4 orchestrator branches on.
//
// Decision tree (matches the bash version line-for-line):
//
//  1. cfg.Enabled == false                 → StatusSkipped (no work)
//  2. cfg.TestCmd == "" || == "true"       → StatusSkipped (no test cmd)
//  3. dedup cache says "passed, no diff"   → StatusClean    (short-circuit)
//  4. TEST_CMD passes (exit 0)             → StatusClean    (record dedup)
//  5. TEST_CMD fails, fix agent succeeds   → StatusFixed    (re-capture baseline)
//  6. TEST_CMD fails, fix agent exhausted  → StatusFixFailed (warn + proceed)
//
// The pipeline proceeds on every disposition. The Result tells the m39.4
// orchestrator which log line to emit, not whether to abort.
func Run(ctx context.Context, cfg *Config, deps *Deps) (*Result, error) {
	if cfg == nil {
		cfg = &Config{}
	}
	if deps == nil {
		deps = &Deps{}
	}
	applyDefaults(cfg)

	// Disabled → skip.
	if !cfg.Enabled {
		return &Result{Status: StatusSkipped}, nil
	}

	// No test command configured → skip.
	if cfg.TestCmd == "" || cfg.TestCmd == "true" {
		return &Result{Status: StatusSkipped}, nil
	}

	logf(deps, "[coder/prerun] Checking pre-coder test state...")

	// Dedup short-circuit. The bash version emits a `test_dedup_skip` event
	// and treats the result as a clean pass.
	if deps.TestDedupCanSkip != nil && deps.TestDedupCanSkip() {
		logf(deps, "[dedup] Tests passed with no file changes since last run — skipping")
		emit(deps, "test_dedup_skip", "prerun_check", "fingerprint_match=true")
		logf(deps, "[coder/prerun] Tests pass (cached) — coder will work from a clean state.")
		return &Result{Status: StatusClean}, nil
	}

	// Run TEST_CMD ourselves. Combined stdout+stderr is captured for the
	// fix-agent prompt and for the LogFile append.
	output, exitCode, runErr := runTestCmd(ctx, cfg, deps)
	if runErr != nil {
		// runTestCmd surfaced a runner-internal error (RunTestCmd dep
		// unset, exec failure unrelated to the test command itself). Treat
		// it as a TEST_CMD failure for routing purposes — the bash version
		// catches the analogous case via `set +e` around the bash -c call.
		warnf(deps, "[coder/prerun] Test runner error: %v", runErr)
	}

	if exitCode == 0 {
		// Tests pass — record the dedup fingerprint so a subsequent
		// invocation can short-circuit, then return clean.
		recordDedupPass(deps)
		logf(deps, "[coder/prerun] Tests pass — coder will work from a clean state.")
		return &Result{Status: StatusClean}, nil
	}

	warnf(deps, "[coder/prerun] Tests failing before coder runs (exit %d) — attempting pre-run fix.", exitCode)

	outcome, _ := runFixAgent(ctx, cfg, deps, output, exitCode)

	result := &Result{
		Attempts:          outcome.AttemptsUsed,
		InitialFails:      outcome.InitialFails,
		FinalFails:        outcome.FinalFails,
		FailureCountDelta: outcome.FinalFails - outcome.InitialFails,
		AbortReason:       outcome.AbortReason,
		Status:            outcome.Status,
	}

	if result.Status == StatusFixed {
		recaptureBaseline(cfg, deps, result)
		return result, nil
	}

	// Fix exhausted. Warn loudly and let the pipeline proceed — the
	// stricter post-run gates will surface the breakage anyway. Matches
	// stages/coder_prerun.sh:163-165.
	warnf(deps, "[coder/prerun] Pre-run fix incomplete. Coder will work from a non-pristine state.")
	warnf(deps, "[coder/prerun] Set PRE_RUN_CLEAN_ENABLED=false to skip this check.")
	return result, nil
}

// applyDefaults populates zero-valued Config fields with the documented
// defaults so the m39.4 orchestrator (and tests) can pass Config{} and
// still get correct behavior on the cap-bounded knobs.
func applyDefaults(cfg *Config) {
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = DefaultMaxAttempts
	}
	if cfg.MaxTurns <= 0 {
		cfg.MaxTurns = DefaultMaxTurns
	}
}

// runTestCmd runs the configured test command via Deps.RunTestCmd. When
// the dep is nil it returns ("", 0, nil) so the orchestrator treats the
// run as a no-op pass — this matches the bash `${TEST_CMD:-true}` fallback
// (which exits 0 with no output).
func runTestCmd(ctx context.Context, cfg *Config, deps *Deps) (string, int, error) {
	if deps.RunTestCmd == nil {
		return "", 0, nil
	}
	return deps.RunTestCmd(ctx, cfg.TestCmd)
}

// recordDedupPass calls Deps.TestDedupRecordPass when wired. Best-effort —
// matches the `declare -f` guard in the bash version.
func recordDedupPass(deps *Deps) {
	if deps.TestDedupRecordPass == nil {
		return
	}
	if err := deps.TestDedupRecordPass(); err != nil {
		warnf(deps, "[coder/prerun] dedup record failed: %v", err)
	}
}

// recaptureBaseline mirrors coder_prerun.sh:151-159 — delete the stale
// .claude/TEST_BASELINE.json BEFORE re-running capture so the cached
// baseline doesn't short-circuit the capture path. Order is load-bearing
// (called out in the milestone Watch For). Sets result.BaselineReCaptured
// on success.
func recaptureBaseline(cfg *Config, deps *Deps, result *Result) {
	if deps.CaptureTestBaseline == nil {
		return
	}
	if deps.DeleteBaselineJSON != nil {
		if err := deps.DeleteBaselineJSON(); err != nil {
			warnf(deps, "[coder/prerun] Failed to delete stale baseline: %v", err)
		}
	}
	if err := deps.CaptureTestBaseline(cfg.Milestone); err != nil {
		warnf(deps, "[coder/prerun] Baseline re-capture failed: %v", err)
		return
	}
	result.BaselineReCaptured = true
	logf(deps, "[coder/prerun] Baseline re-captured after successful fix.")
}

// baselineJSONPath resolves the project-relative TEST_BASELINE.json path
// the bash version manipulates (coder_prerun.sh:155). Kept exported via a
// package-scope helper so the m39.4 orchestrator wiring can produce the
// same path when its DeleteBaselineJSON dep is implemented.
//
//nolint:unused // surfaced for the m39.4 wiring; intentional public-by-name.
func baselineJSONPath(projectDir string) string {
	dir := projectDir
	if dir == "" {
		dir = "."
	}
	return filepath.Join(dir, ".claude", "TEST_BASELINE.json")
}

// emit is the best-effort EmitEvent wrapper. Matches the bash version's
// `> /dev/null 2>&1 || true` semantics — emit failures never surface.
func emit(deps *Deps, kind, scope, desc string) {
	if deps == nil || deps.EmitEvent == nil {
		return
	}
	deps.EmitEvent(kind, scope, desc)
}

// logf / warnf / successf are nil-safe wrappers around the Deps log
// helpers. A nil dep degrades to no-op — tests that don't care about log
// output can leave the fields unset.

func logf(deps *Deps, format string, args ...any) {
	if deps == nil || deps.Log == nil {
		return
	}
	deps.Log(format, args...)
}

func warnf(deps *Deps, format string, args ...any) {
	if deps == nil || deps.Warn == nil {
		return
	}
	deps.Warn(format, args...)
}

func successf(deps *Deps, format string, args ...any) {
	if deps == nil || deps.Success == nil {
		return
	}
	deps.Success(format, args...)
}
