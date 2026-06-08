package tester

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
	"github.com/geoffgodwin/tekhton/internal/tester/tdd"
	testaudit "github.com/geoffgodwin/tekhton/internal/test_audit"
)

// routingMetadata carries the per-routing-branch artefacts the result
// builder consumes. Two notable outputs: SkipFinalChecks signals to the
// legacy bash orchestrator (via the result metadata) that downstream
// final-check stages should be skipped; ResolvedFailures is what the
// fix-loop reported when invoked.
type routingMetadata struct {
	HumanAction      bool
	ResolvedFailures bool
	ContinuationOK   bool
	AuditRan         bool
	SkipFinalChecks  bool
	BlockedReason    string
}

// routeDecision consumes a ValidationDecision from m38.1 and dispatches
// into the appropriate downstream component. Returns the routing
// metadata, the additional agent-call count, and any error.
func routeDecision(
	ctx context.Context,
	cfg *config,
	decision innertester.ValidationDecision,
	_ *provider.Result,
) (routingMetadata, int, error) {
	meta := routingMetadata{}
	additionalCalls := 0

	switch decision.Routing {
	case innertester.RoutingClean:
		// Clean exit — audit (m38.4).
		auditCalls, err := runAudit(ctx, cfg)
		additionalCalls += auditCalls
		if err == nil {
			meta.AuditRan = true
		}

	case innertester.RoutingCompilationErrors:
		// ValidateOutput already flipped checkboxes. No agent re-call.
		// Operator resumes manually after fixing the test sources.

	case innertester.RoutingTestFailures:
		// Inline fix gate: BOTH TesterFixEnabled=true AND MaxDepth>0
		// (regression-canary; matches stages/tester_validation.sh:76-77).
		if cfg.TesterFixEnabled && cfg.TesterFixMaxDepth > 0 {
			fixRes, err := runFix(ctx, cfg)
			if err != nil {
				return meta, additionalCalls, err
			}
			if fixRes != nil {
				additionalCalls += fixRes.AttemptCount
				meta.ResolvedFailures = fixRes.ResolvedFailures
			}
		}

	case innertester.RoutingPartialRun:
		// Continuation loop (m38.3).
		contRes, err := runContinuations(ctx, cfg, decision.Remaining)
		if err != nil {
			return meta, additionalCalls, err
		}
		if contRes != nil {
			additionalCalls += contRes.AttemptsUsed
			meta.ContinuationOK = contRes.Continued
			meta.SkipFinalChecks = contRes.SkipFinalChecks
			if contRes.Continued {
				// Audit runs on clean continuation.
				auditCalls, _ := runAudit(ctx, cfg)
				additionalCalls += auditCalls
				meta.AuditRan = true
			} else if !contRes.UpstreamErrored {
				// Continuation didn't finish — write resume state.
				_ = stateHaltWriter.Write(ctx, "tester", "partial_tests",
					cfg.ResumeFlag, cfg.Task, decision.ResumeMessage)
			}
		}

	case innertester.RoutingNoReportButTestsCreated:
		// Commit gate already tripped by ValidateOutput. Result is
		// pass-with-warning — downstream will see synthesized report.

	case innertester.RoutingNoReportNoTests:
		// Warn-and-state. Operator resumes manually.
		_ = stateHaltWriter.Write(ctx, "tester", "no_report",
			cfg.ResumeFlag, cfg.Task, decision.ResumeMessage)
		meta.SkipFinalChecks = true
	}

	return meta, additionalCalls, nil
}

// runTDDBranch dispatches the m38.2 TDD pre-flight. UPSTREAM errors
// propagate as a non-nil error (fatal — pre-flight halt). Null runs are
// non-fatal and recorded as such.
func runTDDBranch(
	ctx context.Context,
	cfg *config,
	req *proto.StageRequestV1,
	log staglog.Logger,
	stageStart time.Time,
) (*proto.StageResultV1, error) {
	tddReq := &tdd.Request{
		ProjectDir:          cfg.ProjectDir,
		TekhtonHome:         cfg.TekhtonHome,
		PromptsDir:          cfg.PromptsDir,
		Task:                cfg.Task,
		ArchitectureContent: os.Getenv("ARCHITECTURE_CONTENT"),
		RepoMapContent:      os.Getenv("REPO_MAP_CONTENT"),
		MilestoneBlock:      os.Getenv("MILESTONE_BLOCK"),
		HumanMode:           cfg.HumanMode,
		HumanNotesTag:       cfg.HumanNotesTag,
		MilestoneMode:       cfg.MilestoneMode,
		PromptVarsBase:      promptVarsFromEnv(),
		Options: tdd.Options{
			MaxTurns:      envInt("TESTER_WRITE_FAILING_MAX_TURNS", 0),
			Model:         cfg.TesterModel,
			AgentTools:    cfg.AgentTools,
			PreflightFile: envOr("TDD_PREFLIGHT_FILE", ""),
			LogDir:        envOr("LOG_DIR", ""),
			Timestamp:     envOr("TIMESTAMP", ""),
		},
	}
	tddRes, err := tddRunner.Run(ctx, tddReq)
	if err != nil {
		// TDD UPSTREAM is fatal — propagate.
		log.Warn("[tester] TDD pre-flight halt: " + err.Error())
		return tddFailResult(req, "tdd_upstream", stageStart), err
	}
	if tddRes != nil && tddRes.NullRun {
		log.Warn("[tester] TDD pre-flight was a null run — coder proceeds without pre-written failing tests.")
	}
	dur := int(time.Since(stageStart).Seconds())
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictPass,
		ExitReason:  "tdd_preflight",
		AgentCalls:  1,
		DurationSec: dur,
	}, nil
}

// runFix wraps innertester.RunInlineFix via the package-level seam.
func runFix(ctx context.Context, cfg *config) (*innertester.FixResult, error) {
	failureLog := readFile(cfg.LogFile)
	return fixRunner.Run(ctx, &innertester.FixRequest{
		ProjectDir:   cfg.ProjectDir,
		PromptsDir:   cfg.PromptsDir,
		Task:         cfg.Task,
		TestCmd:      cfg.TestCmd,
		Milestone:    cfg.Milestone,
		FailureLog:   failureLog,
		Architecture: os.Getenv("ARCHITECTURE_CONTENT"),
		Options: innertester.FixOptions{
			MaxDepth:    cfg.TesterFixMaxDepth,
			OutputLimit: cfg.TesterFixOutLim,
			MaxTurns:    cfg.TesterFixMaxTurns,
			Model:       envOr("CLAUDE_CODER_MODEL", "claude-sonnet-4-6"),
			AgentTools:  envOr("AGENT_TOOLS_CODER", innertester.DefaultFixAgentTools),
			SummaryFile: cfg.CoderSummaryFile,
			ReportFile:  cfg.TesterReportFile,
		},
	})
}

// runContinuations wraps innertester.RunContinuations via the
// package-level seam. ResumeFlag flows through so the writer inside the
// continuation loop uses the correct flag if it has to record a halt.
func runContinuations(ctx context.Context, cfg *config, initialRemaining int) (*innertester.ContinuationResult, error) {
	return continuationRunner.Run(ctx, &innertester.ContinuationRequest{
		ProjectDir:       cfg.ProjectDir,
		PromptsDir:       cfg.PromptsDir,
		Task:             cfg.Task,
		ResumeFlag:       cfg.ResumeFlag,
		InitialRemaining: initialRemaining,
		HumanMode:        cfg.HumanMode,
		HumanNotesTag:    cfg.HumanNotesTag,
		MilestoneMode:    cfg.MilestoneMode,
		Options: innertester.ContinuationOptions{
			Enabled:        cfg.ContinuationEnabled,
			MaxAttempts:    cfg.ContinuationMaxAtt,
			NextTurnBudget: cfg.ContinuationBudget,
			Model:          cfg.TesterModel,
			AgentTools:     cfg.AgentTools,
			ReportFile:     cfg.TesterReportFile,
		},
	})
}

// runAudit wraps test_audit.Run via the package-level seam. Returns the
// number of agent calls the audit consumed plus any error.
func runAudit(ctx context.Context, cfg *config) (int, error) {
	req := buildAuditRequest(cfg)
	res, err := auditRunner.Run(ctx, req)
	if res == nil {
		return 0, err
	}
	return res.AgentCalls, err
}

// buildAuditRequest assembles the test_audit.Request from the resolved
// config. Mirrors buildAuditRequestFromEnv in continuation.go.
func buildAuditRequest(cfg *config) *testaudit.Request {
	tekhtonDir := cfg.TekhtonDir
	if tekhtonDir == "" {
		tekhtonDir = ".tekhton"
	}
	resolve := func(path string) string {
		if path == "" || filepath.IsAbs(path) {
			return path
		}
		return filepath.Join(cfg.ProjectDir, path)
	}
	return &testaudit.Request{
		ProjectDir:       cfg.ProjectDir,
		TekhtonHome:      cfg.TekhtonHome,
		PromptsDir:       cfg.PromptsDir,
		TesterReportFile: cfg.TesterReportFile,
		CoderSummaryFile: cfg.CoderSummaryFile,
		AuditReportFile:  resolve(envOr("TEST_AUDIT_REPORT_FILE", filepath.Join(tekhtonDir, "TEST_AUDIT_REPORT.md"))),
		NonBlockingFile:  resolve(envOr("NON_BLOCKING_LOG_FILE", filepath.Join(tekhtonDir, "NON_BLOCKING_LOG.md"))),
		TestMapFile:      envOr("TEST_SYMBOL_MAP_FILE", ""),
		TagsFile:         envOr("TEST_SYMBOL_TAGS_FILE", ""),
	}
}

// readFile reads a file's bytes, returning an empty string on any
// error. Used to extract the LOG_FILE body for innertester.RunInlineFix.
func readFile(path string) string {
	if path == "" {
		return ""
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}

// tddFailResult wraps a TDD-branch failure into a verdict=fail
// StageResultV1. The Error field carries the propagated reason.
func tddFailResult(req *proto.StageRequestV1, reason string, stageStart time.Time) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictFail,
		ExitReason:  reason,
		AgentCalls:  1,
		DurationSec: int(time.Since(stageStart).Seconds()),
		Error:       fmt.Sprintf("tdd: %s", reason),
	}
}
