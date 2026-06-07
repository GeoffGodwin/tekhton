// continuation.go ports stages/tester_continuation.sh to Go. Lands at
// m38.3. The bash file remains on disk through m38.5; m38.6 rewires the
// dispatch and deletes it.
//
// Load-bearing semantics preserved here:
//
//  1. MaxAttempts defaults to 3. Three attempts is what operators have
//     validated in dogfooding; going higher invites cost overrun on the
//     long-tail tester runs. TestDefaultContinuationOptions_MaxAttemptsIs3
//     is the regression-canary.
//
//  2. UPSTREAM during a continuation iteration is RECOVERABLE — returns
//     nil error with Result.UpstreamErrored=true and SkipFinalChecks=true.
//     This differs from TDD UPSTREAM (m38.2) which returns non-nil error.
//     TDD is a pre-flight that the rest of the pipeline depends on, so
//     its failure halts; continuation is "tester didn't finish in time"
//     recovery, and a mid-recovery API failure means the operator just
//     resumes the run.
//
//  3. Git-diff gate. When the tester wrote zero test files in the
//     primary invocation, the continuation loop is skipped — there's
//     nothing to continue from.
//
//  4. Accumulate-mode timing. ParseTesterTiming is called after each
//     continuation iteration with ParseModeAccumulate so per-continuation
//     counts add onto the running total.

package tester

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	"github.com/geoffgodwin/tekhton/internal/test_audit"
)

// Default values for ContinuationOptions fields.
const (
	// DefaultContinuationMaxAttempts is the regression-canary default.
	// Going higher invites cost overrun on long-tail tester runs.
	DefaultContinuationMaxAttempts = 3
	DefaultContinuationTurnBudget  = 50
	DefaultContinuationModel       = "claude-sonnet-4-6"
	DefaultContinuationAgentTools  = "Read Write Edit Bash Glob Grep"
	defaultContinuationReportFile  = ".tekhton/TESTER_REPORT.md"
)

// ContinuationOptions carries the per-run knobs for RunContinuations.
type ContinuationOptions struct {
	Enabled        bool
	MaxAttempts    int
	NextTurnBudget int
	Model          string
	AgentTools     string
	ReportFile     string
	PromptName     string
	PromptVarsBase map[string]string
}

// DefaultContinuationOptions returns ContinuationOptions populated with
// the regression-canary safety defaults. MaxAttempts=3 is load-bearing.
func DefaultContinuationOptions() ContinuationOptions {
	return ContinuationOptions{
		Enabled:        true,
		MaxAttempts:    DefaultContinuationMaxAttempts,
		NextTurnBudget: DefaultContinuationTurnBudget,
		Model:          DefaultContinuationModel,
		AgentTools:     DefaultContinuationAgentTools,
		ReportFile:     defaultContinuationReportFile,
		PromptName:     "tester_resume",
	}
}

// ContinuationRequest bundles everything RunContinuations needs.
type ContinuationRequest struct {
	ProjectDir       string
	PromptsDir       string
	Task             string
	ResumeFlag       string
	StageStartUnix   int64
	InitialRemaining int
	InitialTurnsUsed int
	RunningTiming    TesterTiming
	HumanMode        bool
	HumanNotesTag    string
	MilestoneMode    bool
	Options          ContinuationOptions
}

// ContinuationResult reports what happened during the continuation loop.
type ContinuationResult struct {
	Continued       bool
	AttemptsUsed    int
	CumulativeTurns int
	RemainingTests  int
	Timing          TesterTiming
	UpstreamErrored bool
	SkipFinalChecks bool
}

// ContinuationContextBuilder is the seam for the continuation-context
// prompt block. The bash implementation is build_continuation_context in
// lib/agent_helpers.sh; the Go-side BuildContinuationContext does not
// exist yet (the milestone design assumed it did). The default
// implementation produces a minimal context string; tests inject a fake.
type ContinuationContextBuilder interface {
	Build(stage string, attempt, maxAttempts, cumulativeTurns, nextBudget int) string
}

// GitDiffReporter is the seam used to detect whether substantive test
// files were created. Production uses os/exec to invoke git; tests
// inject a fake to drive the gate deterministically.
type GitDiffReporter interface {
	FilesChanged(projectDir string) int
}

// RemainingReader is the seam for parsing REMAINING from the tester
// report. The bash version greps `^- \[ \]` lines.
type RemainingReader interface {
	Read(reportPath string) int
}

// TestAuditRunner is the seam for run_test_audit (m38.4 will replace
// the bash shim with a Go implementation). Returns the duration in
// seconds and the turns used.
type TestAuditRunner interface {
	Run(ctx context.Context, projectDir string) (durationS, turns int, err error)
}

// StateHaltWriter is the seam for write_pipeline_state. The default
// reuses the bash shim convention; the tdd package has its own seam
// (StateWriter) so they don't conflict.
type StateHaltWriter interface {
	Write(ctx context.Context, stage, exitReason, resumeFlag, task, notes string) error
}

// ContinuationAgentRunner is the seam between RunContinuations and the
// supervisor. Mirrors FixAgentRunner.
type ContinuationAgentRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// ContinuationPromptRenderer is the seam for tester_resume prompt rendering.
type ContinuationPromptRenderer interface {
	Render(promptsDir, name string, vars map[string]string) (string, error)
}

// ContinuationLogger is the optional log/event emitter; nil is a no-op.
type ContinuationLogger interface {
	Logf(format string, args ...any)
}

// Package-level seams.
var (
	contextBuilder   ContinuationContextBuilder = defaultContextBuilder{}
	gitDiff          GitDiffReporter            = execGitDiffReporter{}
	remainingReader  RemainingReader            = fileRemainingReader{}
	testAuditRunner  TestAuditRunner            = nativeTestAuditRunner{}
	stateHaltWriter  StateHaltWriter            = noopStateHaltWriter{}
	contAgentRunner  ContinuationAgentRunner    = noopContinuationAgent{}
	contPromptRender ContinuationPromptRenderer = noopContinuationRenderer{}
	contLogger       ContinuationLogger         = noopContinuationLogger{}
)

// SetContinuationContextBuilder overrides the context-builder seam.
func SetContinuationContextBuilder(b ContinuationContextBuilder) ContinuationContextBuilder {
	prev := contextBuilder
	if b != nil {
		contextBuilder = b
	}
	return prev
}

// SetContinuationGitDiff overrides the git-diff seam.
func SetContinuationGitDiff(g GitDiffReporter) GitDiffReporter {
	prev := gitDiff
	if g != nil {
		gitDiff = g
	}
	return prev
}

// SetContinuationRemainingReader overrides the remaining-reader seam.
func SetContinuationRemainingReader(r RemainingReader) RemainingReader {
	prev := remainingReader
	if r != nil {
		remainingReader = r
	}
	return prev
}

// SetContinuationTestAuditRunner overrides the test-audit seam.
func SetContinuationTestAuditRunner(r TestAuditRunner) TestAuditRunner {
	prev := testAuditRunner
	if r != nil {
		testAuditRunner = r
	}
	return prev
}

// SetContinuationStateHaltWriter overrides the state-writer seam.
func SetContinuationStateHaltWriter(w StateHaltWriter) StateHaltWriter {
	prev := stateHaltWriter
	if w != nil {
		stateHaltWriter = w
	}
	return prev
}

// SetContinuationAgentRunner overrides the supervisor seam.
func SetContinuationAgentRunner(r ContinuationAgentRunner) ContinuationAgentRunner {
	prev := contAgentRunner
	if r != nil {
		contAgentRunner = r
	}
	return prev
}

// SetContinuationPromptRenderer overrides the prompt-render seam.
func SetContinuationPromptRenderer(r ContinuationPromptRenderer) ContinuationPromptRenderer {
	prev := contPromptRender
	if r != nil {
		contPromptRender = r
	}
	return prev
}

// SetContinuationLogger overrides the logger seam. A nil logger restores
// the no-op default.
func SetContinuationLogger(l ContinuationLogger) ContinuationLogger {
	prev := contLogger
	if l == nil {
		contLogger = noopContinuationLogger{}
	} else {
		contLogger = l
	}
	return prev
}

// withContinuationDefaults fills ContinuationOptions' empty fields.
func withContinuationDefaults(o ContinuationOptions) ContinuationOptions {
	if o.MaxAttempts <= 0 {
		o.MaxAttempts = DefaultContinuationMaxAttempts
	}
	if o.NextTurnBudget <= 0 {
		o.NextTurnBudget = DefaultContinuationTurnBudget
	}
	if o.Model == "" {
		o.Model = DefaultContinuationModel
	}
	if o.AgentTools == "" {
		o.AgentTools = DefaultContinuationAgentTools
	}
	if o.ReportFile == "" {
		o.ReportFile = defaultContinuationReportFile
	}
	if o.PromptName == "" {
		o.PromptName = "tester_resume"
	}
	return o
}

// RunContinuations executes the tester continuation loop. Gated by
// Options.Enabled and by the git-diff check. Loops up to
// Options.MaxAttempts times until REMAINING==0 or the loop budget is
// exhausted.
func RunContinuations(ctx context.Context, req *ContinuationRequest) (*ContinuationResult, error) {
	if req == nil {
		return nil, fmt.Errorf("tester continuation: nil request")
	}
	opts := withContinuationDefaults(req.Options)
	out := &ContinuationResult{
		Timing:          req.RunningTiming,
		RemainingTests:  req.InitialRemaining,
		CumulativeTurns: req.InitialTurnsUsed,
	}

	if !opts.Enabled {
		return out, nil
	}
	if gitDiff.FilesChanged(req.ProjectDir) < 1 {
		return out, nil
	}

	reportPath := resolveContinuationPath(req.ProjectDir, opts.ReportFile)
	contLogger.Logf(
		"[tester-diag] Entering continuation loop: %d tests remaining, max %d continuations",
		out.RemainingTests, opts.MaxAttempts)

	for attempt := 1; attempt <= opts.MaxAttempts && out.RemainingTests > 0; attempt++ {
		out.AttemptsUsed = attempt

		ctxBlock := contextBuilder.Build("tester", attempt, opts.MaxAttempts,
			out.CumulativeTurns, opts.NextTurnBudget)

		vars := buildContinuationPromptVars(req, opts, ctxBlock)
		body, err := contPromptRender.Render(req.PromptsDir, opts.PromptName, vars)
		if err != nil {
			return out, fmt.Errorf("tester continuation: render prompt: %w", err)
		}
		promptFile, cleanup, err := writeFixPromptTmp(body)
		if err != nil {
			return out, fmt.Errorf("tester continuation: write prompt: %w", err)
		}
		agentReq := &proto.AgentRequestV1{
			Proto:        proto.AgentRequestProtoV1,
			Label:        fmt.Sprintf("Tester (continuation %d)", attempt),
			Model:        opts.Model,
			MaxTurns:     opts.NextTurnBudget,
			PromptFile:   promptFile,
			WorkingDir:   req.ProjectDir,
			AllowedTools: opts.AgentTools,
		}
		agentRes, agentErr := contAgentRunner.Run(ctx, agentReq)
		cleanup()
		if agentErr != nil {
			return out, fmt.Errorf("tester continuation: agent invocation: %w", agentErr)
		}
		turns := 0
		if agentRes != nil {
			turns = agentRes.TurnsUsed
		}
		out.CumulativeTurns += turns

		// Accumulate timing from the just-completed iteration.
		out.Timing = MergeTimingFromFile(out.Timing, reportPath, ParseModeAccumulate)

		// UPSTREAM during continuation is RECOVERABLE (not fatal).
		if agentRes != nil && agentRes.ErrorCategory == supervisor.CategoryUpstream {
			contLogger.Logf("Tester continuation hit API error. Saving state.")
			notes := fmt.Sprintf(
				"API error during tester continuation %d.", attempt)
			_ = stateHaltWriter.Write(ctx, "tester", "upstream_error",
				req.ResumeFlag, req.Task, notes)
			out.UpstreamErrored = true
			out.SkipFinalChecks = true
			return out, nil
		}

		// Re-read REMAINING from the report.
		out.RemainingTests = remainingReader.Read(reportPath)
	}

	if out.RemainingTests == 0 {
		out.Continued = true
		contLogger.Logf(
			"Tester completed after %d continuation(s) — all planned tests written.",
			out.AttemptsUsed)
		if _, _, err := testAuditRunner.Run(ctx, req.ProjectDir); err != nil {
			contLogger.Logf("Test audit failed: %v", err)
		}
		return out, nil
	}
	contLogger.Logf(
		"Tester still has %d test(s) remaining after %d continuation(s).",
		out.RemainingTests, out.AttemptsUsed)
	return out, nil
}

// RunAndRecordTestAudit invokes the test audit and records timing into
// the per-stage duration table. Mirrors
// stages/tester_continuation.sh::_run_and_record_test_audit. Called both
// from RunContinuations (on success) and from RunStage (on clean
// finish; landing at m38.6).
//
// m38.4 rewires the default seam to nativeTestAuditRunner, which calls
// test_audit.Run directly — no bash shim, no subprocess. Tests can
// still override the seam with SetContinuationTestAuditRunner.
func RunAndRecordTestAudit(ctx context.Context, projectDir string) (durationS, turns int, err error) {
	return testAuditRunner.Run(ctx, projectDir)
}

// resolveContinuationPath joins relative report paths under projectDir.
func resolveContinuationPath(projectDir, path string) string {
	if path == "" || filepath.IsAbs(path) {
		return path
	}
	if projectDir == "" {
		return path
	}
	return filepath.Join(projectDir, path)
}

// buildContinuationPromptVars assembles the variable map the
// tester_resume prompt expects.
func buildContinuationPromptVars(req *ContinuationRequest, opts ContinuationOptions, contextBlock string) map[string]string {
	vars := map[string]string{}
	for k, v := range opts.PromptVarsBase {
		vars[k] = v
	}
	vars["CONTINUATION_CONTEXT"] = contextBlock
	vars["TESTER_REPORT_FILE"] = opts.ReportFile
	if _, ok := vars["TASK"]; !ok {
		vars["TASK"] = req.Task
	}
	return vars
}

// defaultContextBuilder produces a minimal continuation context block.
// Mirrors the bash heredoc shape closely enough for the prompt to make
// sense; the bash version reads the prior summary file and a git diff
// stat — that work is left to a future arc that ports
// build_continuation_context into Go.
type defaultContextBuilder struct{}

func (defaultContextBuilder) Build(stage string, attempt, maxAttempts, cumulative, nextBudget int) string {
	label := "Tester"
	if stage == "coder" {
		label = "Coder"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "## Continuation Context (attempt %d/%d)\n", attempt, maxAttempts)
	fmt.Fprintf(&b,
		"You are continuing from a previous %s run that hit the turn limit.\n",
		label)
	fmt.Fprintf(&b,
		"Previous attempts used %d turns total. You have %d turns.\n",
		cumulative, nextBudget)
	b.WriteString("Focus on completing the remaining items efficiently.\n")
	return b.String()
}

// execGitDiffReporter shells out to git for the file-changed count.
type execGitDiffReporter struct{}

func (execGitDiffReporter) FilesChanged(projectDir string) int {
	// Two cheap probes: working tree dirty OR cached dirty? If neither,
	// no files changed. Mirrors `git diff --quiet || git diff --cached --quiet`.
	if !gitWorktreeDirty(projectDir) {
		return 0
	}
	out, err := runGit(projectDir, "diff", "--stat", "HEAD")
	if err != nil {
		return 0
	}
	count := 0
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "|") {
			count++
		}
	}
	return count
}

func gitWorktreeDirty(projectDir string) bool {
	if _, err := runGit(projectDir, "diff", "--quiet"); err != nil {
		return true
	}
	if _, err := runGit(projectDir, "diff", "--cached", "--quiet"); err != nil {
		return true
	}
	return false
}

func runGit(projectDir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = projectDir
	out, err := cmd.CombinedOutput()
	return string(out), err
}

// fileRemainingReader parses REMAINING by counting `^- [ ]` lines in
// the tester report.
type fileRemainingReader struct{}

func (fileRemainingReader) Read(reportPath string) int {
	if reportPath == "" {
		return 0
	}
	body, err := os.ReadFile(reportPath)
	if err != nil {
		return 0
	}
	count := 0
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, "- [ ]") {
			count++
		}
	}
	return count
}

// no-op seam implementations -------------------------------------------

// nativeTestAuditRunner is the m38.4 default: it calls test_audit.Run
// directly, in-process. No subprocess, no bash, no python — the bash
// `run_test_audit` shim is gone. Returns the wall-clock duration in
// seconds and the agent-call count so callers can record per-stage
// timing in PIPELINE_STATE's StageDurations map.
type nativeTestAuditRunner struct{}

func (nativeTestAuditRunner) Run(ctx context.Context, projectDir string) (int, int, error) {
	if projectDir == "" {
		return 0, 0, nil
	}
	start := time.Now()
	res, err := test_audit.Run(ctx, buildAuditRequestFromEnv(projectDir))
	dur := int(time.Since(start).Seconds())
	if res == nil {
		return dur, 0, err
	}
	return dur, res.AgentCalls, err
}

// buildAuditRequestFromEnv resolves the test_audit.Request from the
// current process env. Keeps the surface compatible with the legacy
// bash callers, which set PROJECT_DIR / TEKHTON_HOME / TESTER_REPORT_FILE
// before invoking the audit. Env keys mirror the bash variable names.
func buildAuditRequestFromEnv(projectDir string) *test_audit.Request {
	envOr := func(key, fallback string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		return fallback
	}
	resolve := func(path string) string {
		if path == "" || filepath.IsAbs(path) {
			return path
		}
		return filepath.Join(projectDir, path)
	}
	home := envOr("TEKHTON_HOME", "")
	promptsDir := envOr("PROMPTS_DIR", "")
	if promptsDir == "" && home != "" {
		promptsDir = filepath.Join(home, "prompts")
	}
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")
	return &test_audit.Request{
		ProjectDir:       projectDir,
		TekhtonHome:      home,
		PromptsDir:       promptsDir,
		TesterReportFile: resolve(envOr("TESTER_REPORT_FILE", filepath.Join(tekhtonDir, "TESTER_REPORT.md"))),
		CoderSummaryFile: resolve(envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))),
		AuditReportFile:  resolve(envOr("TEST_AUDIT_REPORT_FILE", filepath.Join(tekhtonDir, "TEST_AUDIT_REPORT.md"))),
		NonBlockingFile:  resolve(envOr("NON_BLOCKING_LOG_FILE", filepath.Join(tekhtonDir, "NON_BLOCKING_LOG.md"))),
		TestMapFile:      envOr("TEST_SYMBOL_MAP_FILE", ""),
		TagsFile:         envOr("TEST_SYMBOL_TAGS_FILE", ""),
	}
}

type noopStateHaltWriter struct{}

func (noopStateHaltWriter) Write(_ context.Context, _, _, _, _, _ string) error {
	return nil
}

type noopContinuationAgent struct{}

func (noopContinuationAgent) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	return &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess}, nil
}

type noopContinuationRenderer struct{}

func (noopContinuationRenderer) Render(_, _ string, _ map[string]string) (string, error) {
	return "", nil
}

type noopContinuationLogger struct{}

func (noopContinuationLogger) Logf(_ string, _ ...any) {}
