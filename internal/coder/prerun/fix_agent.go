package prerun

import (
	"context"
	"fmt"
	"regexp"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// fixOutcome captures the inner-loop disposition. The orchestrator
// translates this into a Result.
type fixOutcome struct {
	Status           Status // StatusFixed or StatusFixFailed
	AttemptsUsed     int
	InitialFails     int
	FinalFails       int
	LastVerifyOutput string
	AbortReason      string // "" | "introduced_new_failures" | "max_attempts"
}

// failureRegex ports `grep -ciE '(FAIL|ERROR|error|failure)'` to a single
// compiled regex. The case-insensitive class covers the bash version's
// mix of upper and lower spellings (which are redundant under -i but kept
// verbatim in the bash source — preserved here for parity).
var failureRegex = regexp.MustCompile(`(?i)(FAIL|ERROR|failure)`)

// countFailures counts lines matching the failure regex. Mirrors the bash
// pipeline `printf '%s\n' "$out" | grep -ciE '(FAIL|ERROR|error|failure)'`.
// Empty input → 0.
func countFailures(s string) int {
	if s == "" {
		return 0
	}
	n := 0
	for _, line := range strings.Split(s, "\n") {
		if failureRegex.MatchString(line) {
			n++
		}
	}
	return n
}

// shouldAbortNewFailures implements the +2 failure-count threshold from
// _run_prerun_fix_agent (coder_prerun.sh:96). The threshold is
// load-bearing: it lets the loop tolerate noisy "0 errors" framework
// lines while catching real regressions.
//
// Returns true when newCount > initialCount + 2.
func shouldAbortNewFailures(initialCount, newCount int) bool {
	return newCount > initialCount+2
}

// tailLines returns the last n lines of s. Mirrors `tail -120` in
// coder_prerun.sh:50. n <= 0 returns the empty string; n >= len(lines)
// returns s.
func tailLines(s string, n int) string {
	if n <= 0 {
		return ""
	}
	lines := strings.Split(s, "\n")
	// Strip trailing empty element produced by a trailing newline so we
	// match `tail` semantics (trailing newline does not count as a line).
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) <= n {
		return strings.Join(lines, "\n")
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// runFixAgent is the inner loop. Mirrors stages/coder_prerun.sh:23-110
// (_run_prerun_fix_agent) byte-for-byte:
//
//   - Compute the initial failure count from the pre-fix output.
//   - Loop up to cfg.MaxAttempts times.
//     ↳ Render the preflight_fix prompt with PREFLIGHT_TEST_OUTPUT
//     (last 120 lines) and PREFLIGHT_CHANGED_FILES ("" by design — see
//     coder_prerun.sh:33-35).
//     ↳ Invoke the agent.
//     ↳ Run TEST_CMD ourselves (the agent never sees its own test output).
//     ↳ If exit 0: success, record dedup, return StatusFixed.
//     ↳ If the new failure count > initial + 2: abort with
//     AbortReason="introduced_new_failures".
//     ↳ Otherwise: rotate the buffer and try again.
//   - Emit the prerun_fix_end "exhausted N attempts" event on exhaustion.
//
// The returned error is always nil today — the bash version is non-fatal
// on every path inside the loop. Keeping the (outcome, error) signature
// lets a future arc thread real errors out without re-shaping callers.
func runFixAgent(ctx context.Context, cfg *Config, deps *Deps, initialOutput string, initialExit int) (*fixOutcome, error) {
	_ = initialExit // documented in the signature; not used in the loop body, mirrors the bash version where _pr_exit is captured but unread.

	initialCount := countFailures(initialOutput)
	out := &fixOutcome{
		InitialFails: initialCount,
		FinalFails:   initialCount,
	}

	currentOutput := initialOutput
	for attempt := 1; attempt <= cfg.MaxAttempts; attempt++ {
		out.AttemptsUsed = attempt
		warnf(deps, "[coder/prerun] Fix attempt %d/%d...", attempt, cfg.MaxAttempts)
		emit(deps, "prerun_fix_start", "prerun_fix",
			fmt.Sprintf("attempt %d/%d", attempt, cfg.MaxAttempts))

		if err := invokeFixAgent(ctx, cfg, deps, attempt, currentOutput); err != nil {
			// Agent invocation itself failed (not a content failure).
			// Surface the warning and rotate to the next attempt with the
			// same input — matches the bash behavior, where run_agent
			// failures are logged by the supervisor and the outer loop
			// proceeds.
			warnf(deps, "[coder/prerun] Fix agent invocation error: %v", err)
		}

		verifyOutput, verifyExit, _ := verifyAfterAttempt(ctx, cfg, deps)
		appendLog(deps, cfg.LogFile, verifyOutput)

		if verifyExit == 0 {
			successf(deps, "[coder/prerun] Tests pass after attempt %d.", attempt)
			emit(deps, "prerun_fix_end", "prerun_fix",
				fmt.Sprintf("fixed on attempt %d", attempt))
			out.Status = StatusFixed
			out.FinalFails = 0
			out.LastVerifyOutput = verifyOutput
			return out, nil
		}

		newCount := countFailures(verifyOutput)
		out.FinalFails = newCount
		out.LastVerifyOutput = verifyOutput

		if shouldAbortNewFailures(initialCount, newCount) {
			warnf(deps,
				"[coder/prerun] Attempt %d introduced new failures (%d vs %d). Aborting.",
				attempt, newCount, initialCount)
			out.Status = StatusFixFailed
			out.AbortReason = "introduced_new_failures"
			emit(deps, "prerun_fix_end", "prerun_fix",
				fmt.Sprintf("exhausted %d attempts", cfg.MaxAttempts))
			return out, nil
		}

		currentOutput = verifyOutput
		warnf(deps, "[coder/prerun] Attempt %d did not resolve failures.", attempt)
	}

	out.Status = StatusFixFailed
	if out.AbortReason == "" {
		out.AbortReason = "max_attempts"
	}
	emit(deps, "prerun_fix_end", "prerun_fix",
		fmt.Sprintf("exhausted %d attempts", cfg.MaxAttempts))
	return out, nil
}

// invokeFixAgent renders the preflight_fix prompt and dispatches the
// bounded fix agent via Deps.RunAgent. The Invocation is constructed
// per-attempt with NO env carry-over — matches the milestone Watch For
// note about subprocess isolation.
func invokeFixAgent(ctx context.Context, cfg *Config, deps *Deps, attempt int, output string) error {
	if deps.RunAgent == nil {
		return fmt.Errorf("prerun: Deps.RunAgent is nil")
	}

	vars := map[string]string{
		"PREFLIGHT_TEST_OUTPUT":   tailLines(output, 120),
		"PREFLIGHT_CHANGED_FILES": "", // intentional — see coder_prerun.sh:33-35
	}

	promptBody := ""
	if deps.RenderPrompt != nil {
		body, err := deps.RenderPrompt("preflight_fix", vars)
		if err != nil {
			return fmt.Errorf("prerun: render preflight_fix: %w", err)
		}
		promptBody = body
	}

	req := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        fmt.Sprintf("Pre-Run Fix (attempt %d)", attempt),
		Model:        cfg.Model,
		MaxTurns:     cfg.MaxTurns,
		PromptFile:   promptBody, // see note below
		AllowedTools: cfg.AgentTools,
	}

	// NOTE on PromptFile: production wiring writes the rendered body to a
	// tmpfile and threads the path here (the supervisor expects a file).
	// In m39.1 the orchestrator hands the rendered body straight through —
	// callers that already write tmpfiles (the m39.4 orchestrator will)
	// override RenderPrompt to return the tmpfile path. The pass-through
	// makes the seam testable without a filesystem.
	_, err := deps.RunAgent(ctx, req)
	return err
}

// verifyAfterAttempt mirrors coder_prerun.sh:64-80 — log the verify-cmd
// line, consult the dedup short-circuit, then run TEST_CMD. Returns the
// verify output, exit code, and whether the dedup short-circuit fired
// (the dedup path produces a synthetic "[dedup] Cached pass" line).
func verifyAfterAttempt(ctx context.Context, cfg *Config, deps *Deps) (string, int, bool) {
	logf(deps, "[coder/prerun] Shell verifying with %s...", cfg.TestCmd)

	if deps.TestDedupCanSkip != nil && deps.TestDedupCanSkip() {
		logf(deps, "[dedup] Tests passed with no file changes since last run — skipping")
		emit(deps, "test_dedup_skip", "prerun_fix", "fingerprint_match=true")
		return "[dedup] Cached pass — no files changed since last successful test run", 0, true
	}

	output, exit, err := runTestCmd(ctx, cfg, deps)
	if err != nil {
		// Treat runner-internal errors as failures so the loop rotates.
		warnf(deps, "[coder/prerun] Verify runner error: %v", err)
		if exit == 0 {
			exit = 1
		}
	}
	if exit == 0 {
		recordDedupPass(deps)
	}
	return output, exit, false
}

// appendLog mirrors `printf '%s\n' "$_pr_verify_output" >> "${LOG_FILE:-}"`
// in coder_prerun.sh:81. Best-effort — failures are swallowed.
func appendLog(deps *Deps, path, content string) {
	if path == "" || content == "" || deps == nil || deps.AppendVerifyOutput == nil {
		return
	}
	_ = deps.AppendVerifyOutput(path, content+"\n")
}
