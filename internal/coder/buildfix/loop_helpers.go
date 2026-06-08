package buildfix

import (
	"context"
	"fmt"
	"os"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// applyLoopDefaults populates zero-valued Config fields with the bash
// defaults. The m39.4 orchestrator threads env → Config; tests can pass
// Config{} and rely on this.
func applyLoopDefaults(cfg *Config) {
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 3
	}
	if cfg.BaseTurnDivisor <= 0 {
		cfg.BaseTurnDivisor = 3
	}
	if cfg.MaxTurnMultiplier <= 0 {
		cfg.MaxTurnMultiplier = 100
	}
	if cfg.TotalTurnCap <= 0 {
		cfg.TotalTurnCap = 120
	}
	if cfg.EffectiveCoderMaxTurns <= 0 {
		cfg.EffectiveCoderMaxTurns = 80
	}
}

// applyDepsDefaults installs no-op defaults for the seam functions Run
// always invokes. Functions that may legitimately be unset (e.g.
// ClassifyWithStats when no mixed_uncertain path is reachable) are NOT
// defaulted here — the call sites guard nil explicitly.
func applyDepsDefaults(deps *Deps) {
	if deps.ReadRawErrors == nil {
		deps.ReadRawErrors = func() (string, error) { return "", nil }
	}
	if deps.Classify == nil {
		deps.Classify = Classify
	}
	if deps.FilterCodeErrors == nil {
		deps.FilterCodeErrors = func(raw string) string { return raw }
	}
	if deps.CountErrors == nil {
		deps.CountErrors = CountErrors
	}
	if deps.ErrorTail == nil {
		deps.ErrorTail = ErrorTail
	}
	if deps.AppendReport == nil {
		deps.AppendReport = AppendReport
	}
	if deps.EmitRoutingDiagnosis == nil {
		deps.EmitRoutingDiagnosis = EmitRoutingDiagnosis
	}
	if deps.RunBuildGate == nil {
		deps.RunBuildGate = func(_ context.Context, _ string) (bool, error) { return false, nil }
	}
}

// applyPathsDefaults installs the bash-default file paths so a Paths{}
// caller sees the same resolution the bash version did.
func applyPathsDefaults(paths *Paths) {
	if paths.BuildRawErrorsFile == "" {
		paths.BuildRawErrorsFile = ".tekhton/BUILD_RAW_ERRORS.txt"
	}
	if paths.BuildErrorsFile == "" {
		paths.BuildErrorsFile = ".tekhton/BUILD_ERRORS.md"
	}
	if paths.BuildRoutingDiagFile == "" {
		paths.BuildRoutingDiagFile = ".tekhton/BUILD_ROUTING_DIAGNOSIS.md"
	}
	if paths.BuildFixReportFile == "" {
		paths.BuildFixReportFile = ".tekhton/BUILD_FIX_REPORT.md"
	}
	if paths.CoderModel == "" {
		paths.CoderModel = "claude-sonnet-4-6"
	}
}

// handleNoncodeDominant runs the noncode_dominant short-circuit: warn,
// append HUMAN_ACTION_REQUIRED entry with a 25-line snapshot, populate
// StateExit with env_failure semantics. Mirrors stages/coder_buildfix.sh
// lines 125-158.
func handleNoncodeDominant(ctx context.Context, deps *Deps, paths *Paths, rawErrors string, result *LoopResult) {
	warnf(deps, "Build errors classified as noncode_dominant: skipping build-fix loop.")
	warnf(deps, "These errors require environment remediation, not code changes.")

	desc := "Non-code build errors detected (routing=noncode_dominant); environment remediation required, not code changes."
	snapshot := buildErrorSnapshot(paths.BuildErrorsFile, 25)
	if snapshot != "" {
		desc = desc + "\n\n  Error snapshot (first 25 lines):\n" + snapshot
	}
	_ = rawErrors // rawErrors is the live stream; the snapshot reads from disk for parity with bash head -25.

	if deps.DriftHumanActionAppend != nil {
		if err := deps.DriftHumanActionAppend(ctx, "build_gate", desc); err != nil {
			warnf(deps, "Failed to append human action: %v", err)
		}
	}

	result.StateExit = &StateExit{
		Stage:      "coder",
		ExitReason: "env_failure",
		ResumeFlag: paths.BaseResumeFlag,
		Task:       paths.Task,
		Notes: fmt.Sprintf(
			"Build failed with environment errors (not code bugs). See %s.",
			paths.BuildErrorsFile),
	}
	errorf(deps, "State saved. Fix environment issues in %s then re-run.", paths.BuildErrorsFile)
}

// buildErrorSnapshot reads the first n lines of path, prepends each with
// "    " (4 spaces), and joins with "\n". Mirrors `head -25 ... | sed
// 's/^/    /'`. Returns empty when the file is unreadable.
func buildErrorSnapshot(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(string(data), "\n")
	if len(lines) > n {
		lines = lines[:n]
	}
	var b strings.Builder
	for i, line := range lines {
		if i > 0 {
			b.WriteByte('\n')
		}
		b.WriteString("    ")
		b.WriteString(line)
	}
	return b.String()
}

// invokeBuildFix mirrors _bf_invoke_build_fix in stages/coder_buildfix.sh
// lines 47-80. Returns the agent's exit code and turn count so the caller
// can compute the terminal class. A nil RunAgent dep returns
// (exit=0, turns=0); test fakes use this to assert the call path without
// supplying an outcome.
func invokeBuildFix(
	ctx context.Context,
	deps *Deps,
	paths *Paths,
	decision Decision,
	extra, rawErrors string,
	budget int,
) (exitCode, turns int) {
	body := deps.FilterCodeErrors(rawErrors)
	if extra != "" {
		body = body + "\n\n" + extra
	}

	label := fmt.Sprintf("Coder (build fix — %s)", decision)
	logf(deps, "Build fix coder: invoking %s with budget %d turns.", label, budget)

	if deps.RunAgent == nil {
		return 0, 0
	}

	vars := map[string]string{
		"BUILD_ERRORS_CONTENT": wrapFileContent("BUILD_ERRORS", body),
	}
	prompt := ""
	if deps.RenderPrompt != nil {
		p, err := deps.RenderPrompt("build_fix", vars)
		if err != nil {
			warnf(deps, "Failed to render build_fix prompt: %v", err)
			return 0, 0
		}
		prompt = p
	}

	req := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        label,
		Model:        paths.CoderModel,
		MaxTurns:     budget,
		PromptFile:   prompt,
		AllowedTools: paths.AgentTools,
	}
	res, err := deps.RunAgent(ctx, req)
	if err != nil {
		warnf(deps, "Build fix agent invocation error: %v", err)
		return 0, 0
	}
	logf(deps, "Build fix coder finished.")
	if res == nil {
		return 0, 0
	}
	return res.ExitCode, res.TurnsUsed
}

// appendAttemptReport is a thin wrapper that builds an AttemptReport and
// forwards it to deps.AppendReport. Nil-safe for the AppendReport dep.
func appendAttemptReport(
	deps *Deps,
	paths *Paths,
	attempt, budget int,
	terminal Class,
	gateResult string,
	progress Signal,
	delta string,
	decision Decision,
	gatePass bool,
) {
	progressVal := progress
	if gatePass {
		// On a passing gate the bash version writes "n/a" for progress —
		// the loop has nothing to compare to once the build is green.
		progressVal = Signal("n/a")
	}
	report := AttemptReport{
		Attempt:         attempt,
		Budget:          budget,
		TerminalClass:   terminal,
		GateResult:      gateResult,
		ProgressSignal:  progressVal,
		ErrorCountDelta: delta,
		Classification:  decision,
	}
	if err := deps.AppendReport(paths.BuildFixReportFile, report); err != nil {
		warnf(deps, "Failed to append build-fix report: %v", err)
	}
}

// wrapFileContent mirrors _wrap_file_content in lib/prompts_io.sh so the
// build_fix prompt body is bracketed with the same BEGIN/END FILE CONTENT
// delimiters the bash side uses.
func wrapFileContent(label, content string) string {
	return fmt.Sprintf("--- BEGIN FILE CONTENT: %s ---\n%s\n--- END FILE CONTENT: %s ---", label, content, label)
}

// logf / warnf / errorf are nil-safe wrappers around Deps.Log/Warn/Error.

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

func errorf(deps *Deps, format string, args ...any) {
	if deps == nil || deps.Error == nil {
		return
	}
	deps.Error(format, args...)
}
