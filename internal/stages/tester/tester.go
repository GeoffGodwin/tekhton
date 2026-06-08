// Package tester implements the Tekhton tester stage (m38.6 port).
//
// RunStage is the entry point registered in
// internal/stagerunner.DefaultStageDefs[proto.StageTester].GoImpl. It
// dispatches the TDD write-failing pre-flight (m38.2), invokes the main
// tester agent, classifies the output via internal/tester.ValidateOutput
// (m38.1), and routes into the inline fix loop (m38.3), the
// turn-exhaustion continuation loop (m38.3), or the test-integrity
// audit (m38.4) per the routing decision.
//
// Load-bearing semantics preserved here, verified by tester_test.go
// fixtures:
//
//  1. MAIN tester UPSTREAM is recoverable — returns nil error with
//     SkipFinalChecks=true (metadata) so the legacy bash orchestrator
//     prompts a re-run. TDD UPSTREAM (handled by tdd.Run) is fatal —
//     returns non-nil error. These differ on purpose: TDD is pre-flight
//     and the rest of the pipeline depends on it; the main tester is
//     mid-pipeline and the operator can resume.
//
//  2. Null-run on the main agent is recoverable — same SkipFinalChecks
//     semantics as UPSTREAM. The agent died before writing tests; final
//     checks would just compound the failure.
//
//  3. Test-failure routing requires BOTH TesterFixEnabled=true AND
//     TesterFixMaxDepth>0. Either alone is insufficient. Match
//     stages/tester_validation.sh:76-77.
//
//  4. CompilationErrors is no-agent-call. ValidateOutput flips the
//     affected report checkboxes back to `[ ]`; the stage exits
//     warn-only.
package tester

import (
	"context"
	"os"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
)

// RunStage is the m38.6 entry point. Signature matches stagerunner.StageImpl
// so DefaultStageDefs[StageTester] can register it directly.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig(req)
	log := staglog.New(req)
	log.Header("Tester")

	stageStart := time.Now()

	// --- TDD write_failing branch (M27 / m38.2) -----------------------------
	// In test_first pipeline order, the first tester pass writes failing
	// tests. Dispatch to tdd.Run; UPSTREAM there is FATAL (matches bash
	// `exit 1` semantics) and propagates as a non-nil error.
	if cfg.TesterMode == "write_failing" {
		return runTDDBranch(ctx, &cfg, req, log, stageStart)
	}

	// --- Main tester agent invocation --------------------------------------
	agentRes, err := invokeMainAgent(ctx, &cfg, req)
	if err != nil {
		log.Warn("[tester] main agent invocation failed: " + err.Error())
		return failResult(req, "agent_invocation_failed", 0, stageStart), err
	}
	agentCalls := 1

	// --- UPSTREAM short-circuit (RECOVERABLE — distinct from TDD UPSTREAM) -
	if agentRes != nil && agentRes.ErrorCategory == supervisor.CategoryUpstream {
		log.Warn("[tester] UPSTREAM error — re-run the same command.")
		_ = stateHaltWriter.Write(ctx, "tester", "upstream_error",
			cfg.ResumeFlag, cfg.Task,
			"API error ("+agentRes.ErrorSubcategory+"): "+agentRes.ErrorMessage+
				". Re-run the same command.")
		return upstreamResult(req, agentCalls, stageStart), nil
	}

	// --- Null-run short-circuit (RECOVERABLE) ------------------------------
	if isNullRun(agentRes) {
		log.Warn("[tester] null run — tester agent died before writing any tests.")
		_ = stateHaltWriter.Write(ctx, "tester", "null_run",
			cfg.ResumeFlag, cfg.Task,
			"Tester agent died during discovery. Check the log.")
		return nullRunResult(req, agentCalls, stageStart), nil
	}

	// --- Self-reported timing (M62 / m38.1) --------------------------------
	timing := innertester.ParseTesterTiming(cfg.TesterReportFile, innertester.ParseModeReplace)

	// --- Output validation → routing decision (m38.1) ----------------------
	decision := innertester.ValidateOutput(ctx, &innertester.Request{
		ProjectDir:       cfg.ProjectDir,
		TekhtonDir:       cfg.TekhtonDir,
		TesterReportFile: cfg.TesterReportFile,
		LogFile:          cfg.LogFile,
		Task:             cfg.Task,
	}, &innertester.AgentResult{})

	// --- Route by validation decision --------------------------------------
	routingMeta, addCalls, err := routeDecision(ctx, &cfg, decision, agentRes)
	agentCalls += addCalls
	if err != nil {
		log.Warn("[tester] routing failure: " + err.Error())
		return failResult(req, decision.Routing.String()+":error", agentCalls, stageStart), err
	}

	// --- Writing-time helper for downstream RUN_SUMMARY consumers ----------
	writingS := innertester.ComputeWritingTime(int(time.Since(stageStart).Seconds()), timing)
	exportTesterTimingEnv(timing, writingS)

	return finalizeResult(req, decision, routingMeta, agentCalls, stageStart), nil
}

// invokeMainAgent renders the tester prompt (fresh vs resume) and
// dispatches via the package-level MainAgentRunner seam. The prompt
// rendering pulls every {{VAR}} from the calling shell — m38.6 does not
// re-build the full context machinery in Go; the legacy bash dispatcher
// already exports ARCHITECTURE_CONTENT, REPO_MAP_CONTENT,
// TEST_BASELINE_SUMMARY, UI_TESTER_PATTERNS, MILESTONE_BLOCK, etc.
// before invoking the binary.
func invokeMainAgent(ctx context.Context, cfg *config, req *proto.StageRequestV1) (*proto.AgentResultV1, error) {
	promptName := "tester"
	if cfg.StartAt == "tester" {
		promptName = "tester_resume"
	}
	body, err := renderTesterPrompt(cfg, promptName)
	if err != nil {
		return nil, err
	}
	promptFile, cleanup, err := writePromptTmpFile(body)
	if err != nil {
		return nil, err
	}
	defer cleanup()

	agentReq := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        "Tester",
		Model:        cfg.TesterModel,
		MaxTurns:     cfg.TesterMaxTurns,
		PromptFile:   promptFile,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.AgentTools,
	}
	return mainAgentRunner.Run(ctx, agentReq)
}

// isNullRun ports lib/agent_helpers.sh::was_null_run via
// supervisor.AgentResult.IsNullRun semantics. A nil result is treated as
// null so a supervisor failure before the result is built doesn't get
// classified as real work.
func isNullRun(res *proto.AgentResultV1) bool {
	if res == nil {
		return true
	}
	return supervisor.FromProto(res).IsNullRun()
}

// exportTesterTimingEnv writes the four _TESTER_TIMING_* env vars the
// bash finalize chain consumes to populate RUN_SUMMARY.json. -1 stays
// "-1" verbatim — matches the bash sentinel.
func exportTesterTimingEnv(t innertester.TesterTiming, writingS int) {
	_ = os.Setenv("_TESTER_TIMING_EXEC_COUNT", itoaSentinel(t.ExecCount))
	_ = os.Setenv("_TESTER_TIMING_EXEC_APPROX_S", itoaSentinel(t.ExecApproxS))
	_ = os.Setenv("_TESTER_TIMING_FILES_WRITTEN", itoaSentinel(t.FilesWritten))
	_ = os.Setenv("_TESTER_TIMING_WRITING_S", itoaSentinel(writingS))
}

func itoaSentinel(n int) string {
	if n == -1 {
		return "-1"
	}
	// itoa for non-negative ints without strconv to avoid extra import
	// churn — performance is irrelevant for four env writes per run.
	if n == 0 {
		return "0"
	}
	digits := []byte{}
	for n > 0 {
		digits = append([]byte{byte('0' + n%10)}, digits...)
		n /= 10
	}
	return string(digits)
}
