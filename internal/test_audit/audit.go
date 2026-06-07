package test_audit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/prompt"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// Options carries the per-run configuration for the audit orchestrator.
// Defaults mirror the bash TEST_AUDIT_* env defaults.
type Options struct {
	Enabled            bool
	OrphanDetection    bool
	WeakeningDetection bool
	SymbolMapEnabled   bool
	SerenaActive       bool

	RollingEnabled  bool
	SamplerK        int
	HistoryMax      int
	MaxTurns        int
	MaxReworkCycles int

	ReviewerModel string
	TesterModel   string
	ReviewerTools string
	TesterTools   string
	TesterTurns   int
}

// DefaultOptions returns the regression-canary defaults. MaxReworkCycles=1
// is load-bearing — higher values produced runaway scope expansion in
// earlier dogfooding. Documented in the milestone's Watch For section.
func DefaultOptions() Options {
	return Options{
		Enabled:            true,
		OrphanDetection:    true,
		WeakeningDetection: true,
		SymbolMapEnabled:   true,
		RollingEnabled:     true,
		SamplerK:           3,
		HistoryMax:         500,
		MaxTurns:           8,
		MaxReworkCycles:    1,
		ReviewerModel:      "claude-sonnet-4-6",
		TesterModel:        "claude-sonnet-4-6",
		ReviewerTools:      "Read Glob Grep",
		TesterTools:        "Read Glob Grep Write Edit Bash",
		TesterTurns:        50,
	}
}

// AuditResult is the per-run outcome of Run / RunStandalone.
type AuditResult struct {
	Verdict           Verdict
	OrphanFindings    []string
	WeakeningFindings []string
	SymbolFindings    []string
	ReworkCycles      int
	AgentCalls        int
	Skipped           bool
}

// AgentRunner is the seam between the audit orchestrator and the
// supervisor. Tests inject a fake; production uses the in-process
// supervisor (Set via SetAgentRunner).
type AgentRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// CausalEmitter is the seam for emitting the `test_audit` causal event.
// Production uses a causal.Log instance; tests substitute a no-op.
type CausalEmitter interface {
	Emit(in causal.EmitInput) (string, error)
}

// Package-level seams.
var (
	agentRunner   AgentRunner   = supervisor.New(nil, nil)
	causalEmitter CausalEmitter = noopCausalEmitter{}
)

// SetAgentRunner overrides the supervisor seam. Returns the previous runner.
func SetAgentRunner(r AgentRunner) AgentRunner {
	prev := agentRunner
	if r != nil {
		agentRunner = r
	}
	return prev
}

// SetCausalEmitter overrides the causal-event seam. Returns the previous emitter.
func SetCausalEmitter(e CausalEmitter) CausalEmitter {
	prev := causalEmitter
	if e != nil {
		causalEmitter = e
	}
	return prev
}

type noopCausalEmitter struct{}

func (noopCausalEmitter) Emit(causal.EmitInput) (string, error) { return "", nil }

// Run is the pipeline-integration entry point. Mirrors
// lib/test_audit.sh::run_test_audit:
//
//  1. Gate on Options.Enabled.
//  2. CollectAuditContext.
//  3. SampleUnauditedTestFiles (if rolling enabled).
//  4. Skip when neither modified nor sampled test files are available.
//  5. Run orphan / weakening / symbol detectors.
//  6. BuildTestAuditContext + invoke audit agent.
//  7. ParseAuditVerdict + emit causal event + RouteAuditVerdict.
//  8. On NEEDS_WORK: rework loop up to Options.MaxReworkCycles.
//
// Returns a non-error result in all branches except an internal agent /
// renderer failure. Exhausted rework cycles return AuditResult with the
// final NEEDS_WORK verdict but a nil error — operators see the warning,
// pipeline proceeds.
func Run(ctx context.Context, req *Request) (*AuditResult, error) {
	if req == nil {
		return nil, errors.New("test_audit: nil request")
	}
	opts := withOptionDefaults(req.Options)
	req.Options = opts
	log := resolveLogger(req)

	if !opts.Enabled {
		log.Logf("Test audit disabled (TEST_AUDIT_ENABLED=false). Skipping.")
		return &AuditResult{Verdict: VerdictPASS, Skipped: true}, nil
	}

	ac := CollectAuditContext(ctx, req)
	sampler := SamplerOptions{
		K:           opts.SamplerK,
		MaxRecords:  opts.HistoryMax,
		HistoryFile: resolveHistoryFile(req),
	}

	if opts.RollingEnabled {
		SampleUnauditedTestFiles(ctx, ac, req.ProjectDir, sampler)
	}

	if len(ac.TestFiles) == 0 && len(ac.SampleFiles) == 0 {
		log.Logf("No test files written this run and no sample available — skipping audit.")
		return &AuditResult{Verdict: VerdictPASS, Skipped: true}, nil
	}

	runDetectors(ctx, ac, req, opts)

	result := &AuditResult{}
	verdict, agentCalls, err := singleAuditCycle(ctx, ac, req, opts)
	result.AgentCalls += agentCalls
	if err != nil {
		return result, err
	}
	result.Verdict = verdict
	result.OrphanFindings = append([]string(nil), ac.OrphanFindings...)
	result.WeakeningFindings = append([]string(nil), ac.WeakeningFindings...)
	result.SymbolFindings = append([]string(nil), ac.SymbolFindings...)

	emitCausalAuditEvent(verdict, ac, req)

	if verdict != VerdictNEEDS_WORK {
		recordHistoryForAuditedFiles(ac, sampler, log)
	}

	if routeErr := RouteAuditVerdict(ctx, req, verdict); routeErr == nil {
		return result, nil
	}

	for cycle := 1; cycle <= opts.MaxReworkCycles; cycle++ {
		result.ReworkCycles = cycle
		log.Logf("Test audit rework cycle %d/%d...", cycle, opts.MaxReworkCycles)

		reworkCalls, reworkErr := invokeReworkAgent(ctx, req, opts, cycle)
		result.AgentCalls += reworkCalls
		if reworkErr != nil {
			return result, reworkErr
		}

		// Re-collect & re-detect.
		ac = CollectAuditContext(ctx, req)
		if opts.RollingEnabled {
			SampleUnauditedTestFiles(ctx, ac, req.ProjectDir, sampler)
		}
		runDetectors(ctx, ac, req, opts)

		verdict, agentCalls, err = singleAuditCycle(ctx, ac, req, opts)
		result.AgentCalls += agentCalls
		if err != nil {
			return result, err
		}
		result.Verdict = verdict
		result.OrphanFindings = append([]string(nil), ac.OrphanFindings...)
		result.WeakeningFindings = append([]string(nil), ac.WeakeningFindings...)
		result.SymbolFindings = append([]string(nil), ac.SymbolFindings...)

		emitCausalAuditEvent(verdict, ac, req)

		if verdict != VerdictNEEDS_WORK {
			recordHistoryForAuditedFiles(ac, sampler, log)
			_ = RouteAuditVerdict(ctx, req, verdict)
			return result, nil
		}
	}

	log.Logf("Test audit NEEDS_WORK after %d rework cycle(s). Escalating to human.",
		opts.MaxReworkCycles)
	log.Logf("Review %s and fix tests manually.",
		fallback(req.AuditReportFile, ".tekhton/TEST_AUDIT_REPORT.md"))
	return result, nil
}

// RunStandalone is the --audit-tests CLI entry point. Discovers all test
// files (regardless of current diff), runs the audit agent once, and
// returns the verdict. No continuation, no rework.
func RunStandalone(ctx context.Context, req *Request) (*AuditResult, error) {
	if req == nil {
		return nil, errors.New("test_audit: nil request")
	}
	opts := withOptionDefaults(req.Options)
	req.Options = opts
	log := resolveLogger(req)

	all := DiscoverAllTestFiles(ctx, req.ProjectDir)
	if len(all) == 0 {
		log.Logf("No test files found in project.")
		return &AuditResult{Verdict: VerdictPASS, Skipped: true}, nil
	}
	// Build a standalone-mode context block (mirrors the bash heredoc).
	var ctxBlock = "## Test Files Under Audit (full suite)\n"
	for _, f := range all {
		ctxBlock += "- " + f + "\n"
	}
	ctxBlock += "\n## Mode: Standalone full-suite audit (--audit-tests)\nAll test files are included regardless of current diff.\n"

	body, renderErr := renderAuditPromptStandalone(req, opts, ctxBlock)
	if renderErr != nil {
		return nil, renderErr
	}
	agentCalls, err := invokeAgent(ctx, body, "Test Audit (standalone)", opts.ReviewerModel,
		opts.MaxTurns, req.ProjectDir, opts.ReviewerTools)
	if err != nil {
		return &AuditResult{AgentCalls: agentCalls}, err
	}
	verdict := ParseAuditVerdict(req.AuditReportFile)
	return &AuditResult{
		Verdict:    verdict,
		AgentCalls: agentCalls,
	}, nil
}

func renderAuditPromptStandalone(req *Request, opts Options, ctxBlock string) (string, error) {
	vars := prompt.EnvVars()
	vars["TEST_AUDIT_CONTEXT"] = ctxBlock
	vars["CODER_DELETED_FILES"] = ""
	return prompt.Render(req.PromptsDir, "test_audit", vars)
}

// runDetectors invokes the three pure-shell-equivalent scans (orphan,
// symbol, weakening) in the same order the bash version did. Findings are
// merged into ac.* fields.
func runDetectors(ctx context.Context, ac *AuditContext, req *Request, opts Options) {
	if opts.OrphanDetection {
		DetectOrphanedTests(ac)
	}
	if opts.SymbolMapEnabled && opts.SerenaActive {
		DetectStaleSymbolRefs(ctx, ac, SymbolOptions{
			SymbolMapEnabled: opts.SymbolMapEnabled,
			TestMapFile:      req.TestMapFile,
			TagsFile:         req.TagsFile,
			SerenaActive:     opts.SerenaActive,
		})
	}
	if opts.WeakeningDetection {
		DetectTestWeakening(ctx, ac, req.ProjectDir)
	}
}

// singleAuditCycle renders the test_audit prompt, invokes the audit agent,
// and returns the parsed verdict + agent-call count.
func singleAuditCycle(ctx context.Context, ac *AuditContext, req *Request, opts Options) (Verdict, int, error) {
	testCtx, deleted := BuildTestAuditContext(ac)
	vars := prompt.EnvVars()
	vars["TEST_AUDIT_CONTEXT"] = testCtx
	vars["CODER_DELETED_FILES"] = deleted
	body, err := prompt.Render(req.PromptsDir, "test_audit", vars)
	if err != nil {
		return VerdictPASS, 0, fmt.Errorf("test_audit: render prompt: %w", err)
	}

	calls, runErr := invokeAgent(ctx, body, "Test Audit",
		opts.ReviewerModel, opts.MaxTurns, req.ProjectDir, opts.ReviewerTools)
	if runErr != nil {
		return VerdictPASS, calls, fmt.Errorf("test_audit: agent: %w", runErr)
	}
	return ParseAuditVerdict(req.AuditReportFile), calls, nil
}

// invokeReworkAgent renders the test_audit_rework prompt and runs the
// tester agent to address the previous-cycle findings.
func invokeReworkAgent(ctx context.Context, req *Request, opts Options, cycle int) (int, error) {
	vars := prompt.EnvVars()
	if body, err := os.ReadFile(req.AuditReportFile); err == nil {
		vars["TEST_AUDIT_FINDINGS"] = string(body)
	} else {
		vars["TEST_AUDIT_FINDINGS"] = ""
	}
	body, err := prompt.Render(req.PromptsDir, "test_audit_rework", vars)
	if err != nil {
		return 0, fmt.Errorf("test_audit: render rework prompt: %w", err)
	}
	label := fmt.Sprintf("Tester (audit rework %d)", cycle)
	return invokeAgent(ctx, body, label, opts.TesterModel, opts.TesterTurns,
		req.ProjectDir, opts.TesterTools)
}

// invokeAgent is the shared agent-invocation helper. Writes the prompt to
// a tmp file (the supervisor expects a path on disk), invokes via the
// package-level agentRunner, and returns the agent-call increment.
func invokeAgent(ctx context.Context, body, label, model string, turns int,
	projectDir, tools string) (int, error) {
	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return 0, fmt.Errorf("test_audit: write prompt: %w", err)
	}
	defer cleanup()
	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        label,
		Model:        model,
		MaxTurns:     turns,
		PromptFile:   promptFile,
		WorkingDir:   projectDir,
		AllowedTools: tools,
	}
	_, err = agentRunner.Run(ctx, agentReq)
	if err != nil {
		return 1, err
	}
	return 1, nil
}

// writePromptTmpFile creates a tmpfile carrying body and returns its path
// + a cleanup func. Matches the pattern used by other Go-native stages.
func writePromptTmpFile(content string) (string, func(), error) {
	f, err := os.CreateTemp("", "tekhton-test-audit-prompt-*.md")
	if err != nil {
		return "", func() {}, err
	}
	if _, err := f.WriteString(content); err != nil {
		_ = f.Close()
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	if err := f.Close(); err != nil {
		_ = os.Remove(f.Name())
		return "", func() {}, err
	}
	return f.Name(), func() { _ = os.Remove(f.Name()) }, nil
}

// emitCausalAuditEvent emits the byte-for-byte preserved `test_audit`
// causal event. The bash version called `emit_event "test_audit" "tester"
// "verdict=…" "" "" '{...}'`. The Go port produces the same context
// payload `{"verdict":"X","orphans":"found"|"","weakening":"found"|""}`.
func emitCausalAuditEvent(verdict Verdict, ac *AuditContext, _ *Request) {
	type ctxPayload struct {
		Verdict    string `json:"verdict"`
		Orphans    string `json:"orphans"`
		Weakening  string `json:"weakening"`
	}
	payload := ctxPayload{Verdict: verdict.String()}
	if len(ac.OrphanFindings) > 0 || len(ac.SymbolFindings) > 0 {
		payload.Orphans = "found"
	}
	if len(ac.WeakeningFindings) > 0 {
		payload.Weakening = "found"
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return
	}
	_, _ = causalEmitter.Emit(causal.EmitInput{
		Stage:   "tester",
		Type:    "test_audit",
		Detail:  "verdict=" + verdict.String(),
		Context: raw,
	})
}

// recordHistoryForAuditedFiles records the union of modified + sampled
// test files into the JSONL history. Best-effort: failures warn but do
// not block.
func recordHistoryForAuditedFiles(ac *AuditContext, sampler SamplerOptions, log Logger) {
	files := append([]string{}, ac.TestFiles...)
	files = append(files, ac.SampleFiles...)
	if err := RecordAuditHistory(files, sampler); err != nil {
		log.Logf("[test-audit] Failed to record audit history: %v", err)
	}
}

// resolveHistoryFile resolves the JSONL history path under the project's
// cache directory. Request.HistoryFile takes precedence; otherwise the
// bash-parity EnsureHistoryFile helper.
func resolveHistoryFile(req *Request) string {
	if req.HistoryFile != "" {
		return req.HistoryFile
	}
	if req.ProjectDir == "" {
		return ""
	}
	return EnsureHistoryFile(req.ProjectDir)
}

// withOptionDefaults fills empty option fields from DefaultOptions().
// Unlike a simple struct merge, we treat zero ints / empty strings as
// "use the default" so callers can pass a sparse Options.
func withOptionDefaults(o Options) Options {
	d := DefaultOptions()
	// Bool defaults are tricky — a zero-value bool is indistinguishable
	// from explicit-false. Callers that need to opt out of a detector
	// pass a fully-populated Options. The bash version honored the
	// individual TEST_AUDIT_*_DETECTION flags; the Go port mirrors via
	// the explicit-zero pattern here.
	if !o.Enabled && !o.OrphanDetection && !o.WeakeningDetection &&
		!o.SymbolMapEnabled && !o.RollingEnabled && o.SamplerK == 0 &&
		o.MaxTurns == 0 && o.MaxReworkCycles == 0 && o.ReviewerModel == "" &&
		o.TesterModel == "" {
		return d
	}
	if o.SamplerK == 0 {
		o.SamplerK = d.SamplerK
	}
	if o.HistoryMax == 0 {
		o.HistoryMax = d.HistoryMax
	}
	if o.MaxTurns == 0 {
		o.MaxTurns = d.MaxTurns
	}
	if o.MaxReworkCycles == 0 {
		o.MaxReworkCycles = d.MaxReworkCycles
	}
	if o.ReviewerModel == "" {
		o.ReviewerModel = d.ReviewerModel
	}
	if o.TesterModel == "" {
		o.TesterModel = d.TesterModel
	}
	if o.ReviewerTools == "" {
		o.ReviewerTools = d.ReviewerTools
	}
	if o.TesterTools == "" {
		o.TesterTools = d.TesterTools
	}
	if o.TesterTurns == 0 {
		o.TesterTurns = d.TesterTurns
	}
	return o
}

// resolveDefaults exists for tests that want to inspect the merged
// Options without invoking Run. Returns the same value Run would use
// internally.
func resolveDefaults(o Options) Options { return withOptionDefaults(o) }

// resolveProjectFile is a small helper used by RunStandalone to find the
// audit report when the request leaves the field empty.
func resolveProjectFile(projectDir, override, defaultName string) string {
	if override != "" {
		return resolveProjectRelative(projectDir, override)
	}
	return filepath.Join(projectDir, defaultName)
}
