package gates

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// CompletionGate ports lib/gates_completion.sh::run_completion_gate. Five
// branches preserved:
//
//  1. Coder status "IN PROGRESS" → ErrInProgress.
//  2. Coder status "COMPLETE" + TEST_CMD passes → nil.
//  3. Coder status "COMPLETE" + TEST_CMD fails new failures → ErrTestFailed.
//  4. Coder status "COMPLETE" + TEST_CMD fails only pre-existing failures
//     and TEST_BASELINE_PASS_ON_PREEXISTING=true → nil.
//  5. No clear status field → ErrNoStatus (or ErrSubstantiveNoStatus when
//     the substantive-work probe reports IN PROGRESS).
type CompletionGate struct {
	// SummaryFile is the CODER_SUMMARY_FILE path. Required — empty means
	// the gate cannot parse the status field and will return ErrNoStatus.
	SummaryFile string

	// TestCmd is the TEST_CMD env value. Empty (or literal "true") means
	// skip the TEST_CMD invocation entirely (parity with the bash guard).
	TestCmd string

	// TestEnabled mirrors COMPLETION_GATE_TEST_ENABLED. false skips TEST_CMD.
	TestEnabled bool

	// PassOnPreexisting mirrors TEST_BASELINE_PASS_ON_PREEXISTING. When
	// true, a TEST_CMD failure whose every failure was already in the
	// baseline counts as Pass.
	PassOnPreexisting bool

	// Baseline is the pluggable baseline-comparison hook. nil means no
	// baseline available; any TEST_CMD failure routes to ErrTestFailed.
	Baseline BaselineComparator

	// Substantive is the pluggable substantive-work probe used to decide
	// whether a missing/ambiguous status field should be treated as IN
	// PROGRESS (substantive work seen) vs no-status fail.
	Substantive SubstantiveProbe

	// Dedup is the pluggable test-dedup fingerprint. nil disables the M63
	// fast-path; non-nil + a positive CanSkip return signals the gate to
	// skip the TEST_CMD invocation entirely.
	Dedup TestDedup

	// SummaryDrift is the pluggable drift-detector — when set, runs after
	// status==COMPLETE and may auto-append a "## Files Modified
	// (auto-detected)" section to the summary file.
	SummaryDrift SummaryDriftHook

	// Timeout caps a single TEST_CMD run. Zero disables the timeout
	// (TEST_CMD never blocks the gate beyond its own runtime).
	Timeout time.Duration

	// Runner abstracts subprocess exec. Defaults to ExecRunner.
	Runner CommandRunner

	// Logger receives a one-line warning per failure branch. Defaults to
	// os.Stderr.
	Logger func(format string, args ...interface{})

	// Dump captures TEST_CMD output to a per-failure log when set. The
	// production path writes ${TEKHTON_DIR}/COMPLETION_GATE_LAST_FAILURE.log
	// (see lib/gates_completion.sh:101-114).
	DumpPath string

	// Milestone / Cwd are ambient context the dump-file header inherits.
	Milestone string
	Cwd       string

	// GraceSecs is the m45 grace window before the first TEST_CMD
	// invocation. Default 3s via env COMPLETION_GATE_GRACE_SECS. After a
	// large coder refactor, TEST_CMD fires within milliseconds of the
	// coder's last syscall — the sleep + sync narrows the file-system
	// flush / dedup-fingerprint race that has caused observed false halts.
	// Zero disables the window (used by unit tests).
	GraceSecs time.Duration

	// RetryOnNoBaseline is the m45 one-retry policy. When true, a non-zero
	// TEST_CMD exit on the no-baseline path triggers a single retry after
	// RetryDelay. If the retry passes, the gate proceeds and emits a
	// completion_gate_flake causal event. If both attempts fail, halts as
	// before. Default true via env COMPLETION_GATE_RETRY_NO_BASELINE.
	RetryOnNoBaseline bool

	// RetryDelay is the m45 sleep between the first failed TEST_CMD and the
	// retry. Default 5s via env COMPLETION_GATE_RETRY_DELAY_SECS.
	RetryDelay time.Duration

	// Causal is the optional pluggable causal-log emitter. Used by the m45
	// one-retry policy to record completion_gate_flake events. nil is a
	// no-op — the gate works correctly without it, only loses the
	// observability signal.
	Causal CausalEmitter
}

// Sentinel errors callers match with errors.Is.
var (
	// ErrCompletionInProgress means the coder self-reported IN PROGRESS.
	ErrCompletionInProgress = errors.New("completion gate: coder in progress")

	// ErrCompletionTestFailed means TEST_CMD reported new failures.
	ErrCompletionTestFailed = errors.New("completion gate: test failures")

	// ErrCompletionPreExisting means TEST_CMD failed but every failure was
	// already in the baseline and TEST_BASELINE_PASS_ON_PREEXISTING was
	// false (the M92 default).
	ErrCompletionPreExisting = errors.New("completion gate: pre-existing test failures (set TEST_BASELINE_PASS_ON_PREEXISTING=true to accept)")

	// ErrCompletionNoStatus means the coder summary file had no clear
	// Status field and the substantive-work probe did not fire.
	ErrCompletionNoStatus = errors.New("completion gate: no clear Status field in summary")

	// ErrCompletionSubstantiveNoStatus is the IN PROGRESS variant of
	// ErrCompletionNoStatus — substantive work seen but no status reported.
	ErrCompletionSubstantiveNoStatus = errors.New("completion gate: substantive work without status — treat as in progress")
)

// BaselineComparator is the pluggable test-baseline comparison hook.
type BaselineComparator interface {
	// HasBaseline returns true when a baseline is available for comparison.
	HasBaseline() bool

	// Compare returns true when every failure in stdout was already in the
	// baseline (i.e. the failure is pre-existing). exitCode is the TEST_CMD
	// exit. Implementations should treat exit 0 as "no failures at all" so
	// CompletionGate.Run never calls Compare with exitCode == 0.
	Compare(stdout []byte, exitCode int) bool
}

// SubstantiveProbe is the M86 "did the coder do real work?" probe.
type SubstantiveProbe interface {
	IsSubstantive() bool
}

// TestDedup is the M105 working-tree fingerprint check. CanSkip returns
// true when the cached fingerprint matches the current working tree,
// signalling the gate to skip the TEST_CMD invocation.
type TestDedup interface {
	CanSkip() bool
	RecordPass()
}

// SummaryDriftHook lets the gate auto-append a "## Files Modified
// (auto-detected)" section when CODER_SUMMARY.md says "no files".
type SummaryDriftHook interface {
	Run(summaryFile string)
}

// CausalEmitter is the m45 hook for completion_gate_flake events. Callers
// pass an implementation that writes to the project's CAUSAL_LOG.jsonl;
// tests pass a fake that records calls in-memory.
type CausalEmitter interface {
	Emit(eventType string, fields map[string]string)
}

// CausalFunc adapts a function to the CausalEmitter interface — the
// standard "FunctionAsInterface" pattern that lets the CLI wire a closure
// without declaring a struct type.
type CausalFunc func(eventType string, fields map[string]string)

// Emit implements CausalEmitter.
func (f CausalFunc) Emit(eventType string, fields map[string]string) {
	if f != nil {
		f(eventType, fields)
	}
}

// Run executes the completion gate. Returns nil on pass; an
// ErrCompletion* sentinel on fail. Infrastructure errors (subprocess
// crash, summary file unreadable) wrap a non-sentinel error so callers
// can distinguish "the gate decided fail" from "the gate could not run".
func (g *CompletionGate) Run(ctx context.Context) error {
	if g == nil {
		return nil
	}
	status := parseSummaryStatus(g.SummaryFile)

	switch {
	case strings.Contains(status, "IN PROGRESS"):
		g.warn("Completion gate FAILED — coder self-reported IN PROGRESS.")
		return ErrCompletionInProgress

	case strings.Contains(status, "COMPLETE"):
		// Run summary-drift detection first (matches bash ordering at
		// gates_completion.sh:69) so the auto-append is visible to
		// downstream consumers even on a TEST_CMD failure.
		if g.SummaryDrift != nil && g.SummaryFile != "" {
			g.SummaryDrift.Run(g.SummaryFile)
		}
		return g.runTestCmd(ctx)
	}

	// Status missing or ambiguous — check for substantive work.
	if g.Substantive != nil && g.Substantive.IsSubstantive() {
		g.warn("Completion gate — Status field missing but substantive work detected.")
		g.warn("Treating as IN PROGRESS. Reviewer will assess actual changes.")
		return ErrCompletionSubstantiveNoStatus
	}
	g.warn("Completion gate FAILED — %s has no clear Status field.", displayFile(g.SummaryFile))
	g.warn("Expected '## Status' line with COMPLETE or IN PROGRESS.")
	return ErrCompletionNoStatus
}

// runTestCmd executes TEST_CMD (when enabled) and applies the M92 baseline
// comparison. The M27.2 hang fix is explicit: ExecRunner sets cmd.Stdin
// to nil so TEST_CMD's `read < /dev/tty` does not block forever.
func (g *CompletionGate) runTestCmd(ctx context.Context) error {
	if !g.TestEnabled || g.TestCmd == "" || g.TestCmd == "true" {
		return nil
	}
	// M105 fast-path: dedup says the working tree is identical to the
	// last successful run.
	if g.Dedup != nil && g.Dedup.CanSkip() {
		return nil
	}
	runner := g.Runner
	if runner == nil {
		runner = ExecRunner{}
	}

	// m45 — Grace window before the first TEST_CMD invocation. After a
	// large coder refactor (200+ turns, hundreds of file writes/deletes),
	// TEST_CMD fires within milliseconds of the coder's last syscall.
	// Observed transient flakes: stale test_dedup fingerprint, write
	// barrier not yet flushed, test runner caching deleted-file metadata.
	// A short sleep + fsync narrows the window enough to eliminate the
	// observed false-halts without slowing successful runs perceptibly.
	if g.GraceSecs > 0 {
		select {
		case <-time.After(g.GraceSecs):
		case <-ctx.Done():
			return ctx.Err()
		}
		bestEffortSync()
	}

	out, exitCode, _, err := runner.Run(ctx, g.TestCmd, g.Timeout)
	if err != nil {
		return fmt.Errorf("completion gate: %w", err)
	}
	if exitCode == 0 {
		if g.Dedup != nil {
			g.Dedup.RecordPass()
		}
		return nil
	}

	// TEST_CMD failed — capture output to the dump file.
	g.dumpFailure(out, exitCode)

	if g.Baseline != nil && g.Baseline.HasBaseline() {
		if g.Baseline.Compare(out, exitCode) {
			if g.PassOnPreexisting {
				return nil
			}
			g.warn("Completion gate FAILED — pre-existing failures no longer auto-pass (M92).")
			g.warn("Set TEST_BASELINE_PASS_ON_PREEXISTING=true to opt out.")
			return ErrCompletionPreExisting
		}
		g.warn("Completion gate FAILED — TEST_CMD exited %d with new failures.", exitCode)
		return ErrCompletionTestFailed
	}

	// m45 — One-retry policy on the no-baseline failure path. Catches the
	// observed transient-flake pattern (file-system flush, port collision,
	// test_dedup stale fingerprint) without weakening the gate: if the work
	// is genuinely broken, the retry fails too. Limited to the no-baseline
	// branch by design — when a baseline exists, the baseline compare
	// already filters pre-existing failures, so a non-zero exit there is
	// novel breakage and should halt immediately.
	if g.RetryOnNoBaseline {
		select {
		case <-time.After(g.RetryDelay):
		case <-ctx.Done():
			return ctx.Err()
		}
		retryOut, retryExitCode, _, retryErr := runner.Run(ctx, g.TestCmd, g.Timeout)
		if retryErr == nil && retryExitCode == 0 {
			if g.Causal != nil {
				g.Causal.Emit("completion_gate_flake", map[string]string{
					"first_exit": strconv.Itoa(exitCode),
					"retry_exit": "0",
					"test_cmd":   g.TestCmd,
					"milestone":  g.Milestone,
				})
			}
			g.warn("Completion gate: first TEST_CMD flaked (exit=%d), retry passed. Proceeding.", exitCode)
			if g.Dedup != nil {
				g.Dedup.RecordPass()
			}
			return nil
		}
		// Retry also failed — overwrite captured output for the dump file
		// so operators see the second attempt's diagnostics, and fall
		// through to the halt path.
		if retryErr == nil {
			out = retryOut
			exitCode = retryExitCode
			g.dumpFailure(out, exitCode)
		}
	}

	g.warn("Completion gate FAILED — TEST_CMD exited %d (no baseline for comparison).", exitCode)
	return ErrCompletionTestFailed
}

// dumpFailure writes the captured TEST_CMD stream + metadata to
// g.DumpPath. Best-effort — failures here are not fatal. Mirrors the
// `_cg_dump` block in lib/gates_completion.sh:101-114.
func (g *CompletionGate) dumpFailure(out []byte, exitCode int) {
	if g.DumpPath == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(g.DumpPath), 0o755); err != nil {
		return
	}
	var b strings.Builder
	fmt.Fprintf(&b, "# Completion gate TEST_CMD failure — %s\n", time.Now().Format("2006-01-02 15:04:05"))
	fmt.Fprintf(&b, "# Exit code: %d\n", exitCode)
	fmt.Fprintf(&b, "# TEST_CMD: %s\n", nonEmpty(g.TestCmd, "(unset)"))
	fmt.Fprintf(&b, "# Milestone: %s\n", nonEmpty(g.Milestone, "(none)"))
	fmt.Fprintf(&b, "# CWD: %s\n\n", nonEmpty(g.Cwd, "(unknown)"))
	b.Write(out)
	b.WriteByte('\n')
	_ = os.WriteFile(g.DumpPath, []byte(b.String()), 0o644)
}

// parseSummaryStatus ports the awk parser in run_completion_gate. Handles
// both single-line "## Status: VALUE" and next-line "## Status\nVALUE"
// shapes. Returns "" when the file is missing or the marker is absent.
func parseSummaryStatus(path string) string {
	if path == "" {
		return ""
	}
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	// Generous buffer — coder summaries can include long lines.
	scanner.Buffer(make([]byte, 64*1024), 1024*1024)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "## Status") {
			continue
		}
		// Trim "## Status" + optional ":" + whitespace.
		v := strings.TrimPrefix(line, "## Status")
		v = strings.TrimPrefix(v, ":")
		v = strings.TrimSpace(v)
		if v != "" {
			return v
		}
		if scanner.Scan() {
			return strings.TrimSpace(scanner.Text())
		}
		return ""
	}
	return ""
}

// warn logs a single-line warning prefixed with the bash side's "Warning:"
// convention. Defaults to os.Stderr.
func (g *CompletionGate) warn(format string, args ...interface{}) {
	if g.Logger != nil {
		g.Logger(format, args...)
		return
	}
	fmt.Fprintln(os.Stderr, "Warning: "+fmt.Sprintf(format, args...))
}

// nonEmpty returns v if non-empty, fallback otherwise.
func nonEmpty(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

// displayFile returns the file path stripped of the project-dir prefix for
// log output. Mirrors the bash `${_cg_dump#"${PROJECT_DIR}"/}` strip.
func displayFile(path string) string {
	if path == "" {
		return "(missing)"
	}
	return path
}

// FailingExitCoder is set by the CLI when CompletionGate.Run returns a
// non-pass sentinel so main.go can map the sentinel to a deterministic
// shell exit code without parsing the error string.
type FailingExitCoder struct {
	Cause error
	Code  int
}

// Error implements error.
func (e *FailingExitCoder) Error() string {
	if e.Cause == nil {
		return ""
	}
	return e.Cause.Error()
}

// Unwrap implements errors.Unwrap.
func (e *FailingExitCoder) Unwrap() error { return e.Cause }

// ExitCode satisfies the exitCoder interface in cmd/tekhton.
func (e *FailingExitCoder) ExitCode() int { return e.Code }
