// fix.go ports stages/tester_fix.sh::_run_tester_inline_fix to Go. Lands
// at m38.3 as the third decimal of the m38 tester-family port. The bash
// file remains on disk at m38.3 close — the bash dispatch in
// stages/tester.sh continues to call _run_tester_inline_fix until m38.6
// rewires the dispatch to call tester.RunInlineFix directly and deletes
// the bash.
//
// Load-bearing semantics preserved here:
//
//  1. MaxDepth defaults to 1. Going deeper than 1 was tried in V3 and led
//     to runaway agent invocations that exhausted quota in seconds. The
//     TestDefaultFixOptions_MaxDepthIs1 test is the regression-canary.
//
//  2. Baseline-aware short-circuit. When TEST_BASELINE_ENABLED=true and
//     the failure output matches a pre-existing baseline, the fix loop
//     returns FixResult{BaselineSkipped:true} without invoking the agent.
//
//  3. Test dedup integration. When TestDedup.CanSkip returns true, the
//     re-test invocation is skipped — preserving the M105 optimization
//     across the bash → Go transition. TestDedup stays bash through M38.

package tester

import (
	"bytes"
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// Default values for FixOptions fields. Mirror the bash ${VAR:-DEFAULT}
// pattern in stages/tester_fix.sh.
const (
	// DefaultFixMaxDepth is the regression-canary default. Going deeper
	// was tried and led to runaway agent invocations — see the m38.3
	// milestone "Watch For" notes.
	DefaultFixMaxDepth     = 1
	DefaultFixOutputLimit  = 4000
	DefaultFixMaxTurns     = 26
	DefaultFixCoderModel   = "claude-sonnet-4-6"
	DefaultFixAgentTools   = "Read Glob Grep Write Edit Bash"
	DefaultFixSummaryFile  = ".tekhton/CODER_SUMMARY.md"
	DefaultFixReportFile   = ".tekhton/TESTER_REPORT.md"
	defaultFixAgentLabelFn = "Tester (fix %d)"
)

// FixOptions carries the per-run knobs for RunInlineFix. Empty fields
// fall back to the Default* constants above. Mirrors the env-driven
// contract in stages/tester_fix.sh.
type FixOptions struct {
	MaxDepth       int
	OutputLimit    int
	MaxTurns       int
	Model          string
	AgentTools     string
	BaselineCheck  bool
	SummaryFile    string
	ReportFile     string
	PromptName     string
	PromptVarsBase map[string]string
}

// DefaultFixOptions returns FixOptions populated with the regression-canary
// safety defaults. MaxDepth=1 is load-bearing.
func DefaultFixOptions() FixOptions {
	return FixOptions{
		MaxDepth:      DefaultFixMaxDepth,
		OutputLimit:   DefaultFixOutputLimit,
		MaxTurns:      DefaultFixMaxTurns,
		Model:         DefaultFixCoderModel,
		AgentTools:    DefaultFixAgentTools,
		BaselineCheck: true,
		SummaryFile:   DefaultFixSummaryFile,
		ReportFile:    DefaultFixReportFile,
		PromptName:    "tester_fix",
	}
}

// FixRequest bundles everything RunInlineFix needs from the caller.
type FixRequest struct {
	ProjectDir   string
	PromptsDir   string
	Task         string
	TestCmd      string
	Milestone    string
	FailureLog   string
	Architecture string
	Options      FixOptions
}

// FixResult reports what happened during a RunInlineFix invocation.
type FixResult struct {
	AttemptCount     int
	ResolvedFailures bool
	DedupSkipped     bool
	BaselineSkipped  bool
}

// BaselineVerdict mirrors the bash compare_test_with_baseline string
// vocabulary. PreExisting means "all failures already existed before the
// task started — skip the fix".
type BaselineVerdict string

const (
	BaselinePreExisting BaselineVerdict = "pre_existing"
	BaselineNew         BaselineVerdict = "new"
	BaselineMixed       BaselineVerdict = "mixed"
	BaselineUnknown     BaselineVerdict = ""
)

// BaselineChecker is the seam between RunInlineFix and the baseline
// subsystem. At M38.3 close, the production implementation is a bash
// shim; M38.5 swaps it for the native Go internal/test_baseline package.
type BaselineChecker interface {
	Has(projectDir string) bool
	Compare(failureOutput string, exitCode int, projectDir string) (BaselineVerdict, error)
}

// TestDedup is the seam for the M105 working-tree fingerprint dedup. At
// M38.3 the production implementation is a bash shim into lib/test_dedup.sh.
// A future build-fix-loop port retires the shim and lands a native Go
// implementation.
type TestDedup interface {
	CanSkip() bool
	RecordPass()
}

// FixTestRunner is the seam for the post-fix TEST_CMD execution. Production
// shells out via os/exec; tests inject a fake to count invocations and
// drive deterministic exit codes.
type FixTestRunner interface {
	Run(ctx context.Context, projectDir, testCmd string) (exitCode int, err error)
}

// FixAgentRunner is the seam between RunInlineFix and the supervisor.
type FixAgentRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// FixPromptRenderer is the seam for rendering the tester_fix prompt.
type FixPromptRenderer interface {
	Render(promptsDir, name string, vars map[string]string) (string, error)
}

// FixLogger is the optional log/event emitter. A nil logger is a no-op.
type FixLogger interface {
	Logf(format string, args ...any)
}

// Package-level seams. Set* helpers return the previous value so tests can
// defer-restore. Sequential test execution is safe; future t.Parallel()
// adoption in this file requires sync protection.
var (
	fixAgentRunner     FixAgentRunner    = noopFixAgentRunner{}
	fixPromptRenderer  FixPromptRenderer = noopFixPromptRenderer{}
	fixBaselineChecker BaselineChecker   = noopBaselineChecker{}
	fixTestDedup       TestDedup         = noopTestDedup{}
	fixTestRunner      FixTestRunner     = execFixTestRunner{}
	fixLogger          FixLogger         = noopFixLogger{}
)

// SetFixAgentRunner overrides the supervisor seam.
func SetFixAgentRunner(r FixAgentRunner) FixAgentRunner {
	prev := fixAgentRunner
	if r != nil {
		fixAgentRunner = r
	}
	return prev
}

// SetFixPromptRenderer overrides the prompt-render seam.
func SetFixPromptRenderer(r FixPromptRenderer) FixPromptRenderer {
	prev := fixPromptRenderer
	if r != nil {
		fixPromptRenderer = r
	}
	return prev
}

// SetFixBaselineChecker overrides the baseline-checker seam. Production
// installs a bash shim; tests inject a fake to drive the short-circuit.
func SetFixBaselineChecker(b BaselineChecker) BaselineChecker {
	prev := fixBaselineChecker
	if b != nil {
		fixBaselineChecker = b
	}
	return prev
}

// SetFixTestDedup overrides the test-dedup seam. Production installs a
// bash shim into lib/test_dedup.sh; tests inject a fake to count calls.
func SetFixTestDedup(d TestDedup) TestDedup {
	prev := fixTestDedup
	if d != nil {
		fixTestDedup = d
	}
	return prev
}

// SetFixTestRunner overrides the TEST_CMD runner seam. Production shells
// out via os/exec; tests inject a fake to drive deterministic exit codes.
func SetFixTestRunner(r FixTestRunner) FixTestRunner {
	prev := fixTestRunner
	if r != nil {
		fixTestRunner = r
	}
	return prev
}

// SetFixLogger overrides the logger seam. A nil logger restores the
// no-op default.
func SetFixLogger(l FixLogger) FixLogger {
	prev := fixLogger
	if l == nil {
		fixLogger = noopFixLogger{}
	} else {
		fixLogger = l
	}
	return prev
}

// withFixDefaults fills FixOptions' empty fields from the Default*
// constants.
func withFixDefaults(o FixOptions) FixOptions {
	if o.MaxDepth <= 0 {
		o.MaxDepth = DefaultFixMaxDepth
	}
	if o.OutputLimit <= 0 {
		o.OutputLimit = DefaultFixOutputLimit
	}
	if o.MaxTurns <= 0 {
		o.MaxTurns = DefaultFixMaxTurns
	}
	if o.Model == "" {
		o.Model = DefaultFixCoderModel
	}
	if o.AgentTools == "" {
		o.AgentTools = DefaultFixAgentTools
	}
	if o.SummaryFile == "" {
		o.SummaryFile = DefaultFixSummaryFile
	}
	if o.ReportFile == "" {
		o.ReportFile = DefaultFixReportFile
	}
	if o.PromptName == "" {
		o.PromptName = "tester_fix"
	}
	return o
}

// RunInlineFix executes the inline tester fix loop. Loops up to
// opts.MaxDepth attempts; returns early on baseline pre-existing
// verdict, on agent UPSTREAM error (best-effort: bubbled up as Go error),
// or on first TEST_CMD pass.
//
// The default MaxDepth=1 is load-bearing. Operators tuning this knob
// upwards must do so explicitly via Options.MaxDepth.
func RunInlineFix(ctx context.Context, req *FixRequest) (*FixResult, error) {
	if req == nil {
		return nil, fmt.Errorf("tester fix: nil request")
	}
	opts := withFixDefaults(req.Options)
	out := &FixResult{}

	for attempt := 1; attempt <= opts.MaxDepth; attempt++ {
		out.AttemptCount = attempt

		failureOutput := extractFailureOutput(req.FailureLog, opts.OutputLimit)
		truncated := SmartTruncateTestOutput(failureOutput, opts.OutputLimit)

		if opts.BaselineCheck && fixBaselineChecker.Has(req.ProjectDir) {
			verdict, err := fixBaselineChecker.Compare(truncated, 1, req.ProjectDir)
			if err == nil && verdict == BaselinePreExisting {
				fixLogger.Logf("All test failures are pre-existing — skipping tester fix.")
				out.BaselineSkipped = true
				return out, nil
			}
		}

		vars := buildFixPromptVars(req, opts, truncated)
		body, err := fixPromptRenderer.Render(req.PromptsDir, opts.PromptName, vars)
		if err != nil {
			return out, fmt.Errorf("tester fix: render prompt: %w", err)
		}

		promptFile, cleanup, err := writeFixPromptTmp(body)
		if err != nil {
			return out, fmt.Errorf("tester fix: write prompt: %w", err)
		}

		agentReq := &proto.AgentRequestV1{
			Proto:        proto.AgentRequestProtoV1,
			Label:        fmt.Sprintf(defaultFixAgentLabelFn, attempt),
			Model:        opts.Model,
			MaxTurns:     opts.MaxTurns,
			PromptFile:   promptFile,
			WorkingDir:   req.ProjectDir,
			AllowedTools: opts.AgentTools,
		}
		fixLogger.Logf("[tester-fix] Attempt %d/%d (max %d turns)...",
			attempt, opts.MaxDepth, opts.MaxTurns)
		agentRes, agentErr := fixAgentRunner.Run(ctx, agentReq)
		cleanup()
		if agentErr != nil {
			return out, fmt.Errorf("tester fix: agent invocation: %w", agentErr)
		}
		if agentRes != nil && agentRes.ErrorCategory == supervisor.CategoryUpstream {
			return out, fmt.Errorf("tester fix: upstream error (%s): %s",
				agentRes.ErrorSubcategory, agentRes.ErrorMessage)
		}

		if req.TestCmd == "" {
			break
		}
		if fixTestDedup.CanSkip() {
			fixLogger.Logf("[dedup] Tests passed with no file changes since last run — skipping")
			out.DedupSkipped = true
			out.ResolvedFailures = true
			return out, nil
		}
		fixLogger.Logf("[tester-fix] Re-running %s to verify fix...", req.TestCmd)
		exitCode, runErr := fixTestRunner.Run(ctx, req.ProjectDir, req.TestCmd)
		if runErr != nil {
			return out, fmt.Errorf("tester fix: re-run test cmd: %w", runErr)
		}
		if exitCode == 0 {
			fixTestDedup.RecordPass()
			out.ResolvedFailures = true
			fixLogger.Logf("Tester fix attempt %d resolved all test failures.", attempt)
			return out, nil
		}
		fixLogger.Logf("Tests still failing after fix attempt %d (exit %d).",
			attempt, exitCode)
	}

	fixLogger.Logf("Tester fix exhausted %d attempt(s). Test failures remain.",
		opts.MaxDepth)
	return out, nil
}

// extractFailureOutput pulls the failure-relevant lines out of the log
// file. Mirrors the bash grep -E followed by tail -c. Returns the empty
// string when the log file is empty or unreadable.
func extractFailureOutput(logBody string, outputLimit int) string {
	if logBody == "" {
		return ""
	}
	limit := outputLimit * 2
	matched := failureMarkerExtractRe.FindAllString(logBody, -1)
	if len(matched) > 0 {
		joined := strings.Join(matched, "\n")
		if len(joined) > limit {
			joined = joined[len(joined)-limit:]
		}
		return joined
	}
	// Fallback to tail -100 of input
	lines := strings.Split(logBody, "\n")
	start := 0
	if len(lines) > 100 {
		start = len(lines) - 100
	}
	tail := strings.Join(lines[start:], "\n")
	if len(tail) > limit {
		tail = tail[len(tail)-limit:]
	}
	return tail
}

var failureMarkerExtractRe = regexp.MustCompile(
	`(?m)^.*(FAIL|ERROR|error|failure|assert|expected|unexpected).*$`)

// buildFixPromptVars assembles the variable map the tester_fix prompt
// expects. Mirrors stages/tester_fix.sh:120-137 — TESTER_FIX_OUTPUT plus
// extracted test file paths plus source files from CODER_SUMMARY.
func buildFixPromptVars(req *FixRequest, opts FixOptions, failureOutput string) map[string]string {
	vars := map[string]string{}
	for k, v := range opts.PromptVarsBase {
		vars[k] = v
	}
	vars["TESTER_FIX_OUTPUT"] = failureOutput
	vars["TESTER_FIX_TEST_FILES"] = strings.Join(extractTestFilePaths(failureOutput), "\n")
	vars["TESTER_FIX_SOURCE_FILES"] = ""
	if req.ProjectDir != "" && opts.SummaryFile != "" {
		summaryPath := opts.SummaryFile
		if !filepath.IsAbs(summaryPath) {
			summaryPath = filepath.Join(req.ProjectDir, summaryPath)
		}
		if files, err := readCoderSummaryFiles(summaryPath); err == nil {
			vars["TESTER_FIX_SOURCE_FILES"] = strings.Join(files, "\n")
		}
	}
	vars["TEST_CMD"] = req.TestCmd
	vars["TESTER_REPORT_FILE"] = opts.ReportFile
	vars["CODER_SUMMARY_FILE"] = opts.SummaryFile
	if _, ok := vars["TASK"]; !ok {
		vars["TASK"] = req.Task
	}
	return vars
}

var testFilePathRe = regexp.MustCompile(`[a-zA-Z0-9_./-]+\.(test|spec)\.[a-zA-Z]+`)

// extractTestFilePaths mirrors the bash grep -oE pipeline; dedups and
// returns paths sorted alphabetically.
func extractTestFilePaths(text string) []string {
	matches := testFilePathRe.FindAllString(text, -1)
	if len(matches) == 0 {
		return nil
	}
	seen := map[string]struct{}{}
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		if _, ok := seen[m]; ok {
			continue
		}
		seen[m] = struct{}{}
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

// execFixTestRunner is the production FixTestRunner. Shells out via
// `bash -c "${TEST_CMD}"` to preserve the bash eval-the-TEST_CMD pattern
// — users configure TEST_CMD with pipes, env-var expansion, etc.
type execFixTestRunner struct{}

func (execFixTestRunner) Run(ctx context.Context, projectDir, testCmd string) (int, error) {
	if testCmd == "" {
		return 0, nil
	}
	cmd := exec.CommandContext(ctx, "bash", "-c", testCmd)
	cmd.Dir = projectDir
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if ee, ok := err.(*exec.ExitError); ok {
		return ee.ExitCode(), nil
	}
	if err != nil {
		return -1, err
	}
	return 0, nil
}

// no-op default seam implementations -----------------------------------

type noopFixAgentRunner struct{}

func (noopFixAgentRunner) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	return &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess}, nil
}

type noopFixPromptRenderer struct{}

func (noopFixPromptRenderer) Render(_, _ string, _ map[string]string) (string, error) {
	return "", nil
}

type noopBaselineChecker struct{}

func (noopBaselineChecker) Has(_ string) bool { return false }
func (noopBaselineChecker) Compare(_ string, _ int, _ string) (BaselineVerdict, error) {
	return BaselineUnknown, nil
}

type noopTestDedup struct{}

func (noopTestDedup) CanSkip() bool { return false }
func (noopTestDedup) RecordPass()   {}

type noopFixLogger struct{}

func (noopFixLogger) Logf(_ string, _ ...any) {}
