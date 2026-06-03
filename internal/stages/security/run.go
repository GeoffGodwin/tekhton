// Package security implements the Tekhton security stage (m35.2 port).
//
// RunStage is the entry point registered in
// internal/stagerunner.DefaultStageDefs[proto.StageSecurity].GoImpl. It mirrors
// the bash run_stage_security flow at stages/security.sh line-for-line:
//
//  1. Skip checks: SECURITY_AGENT_ENABLED, SKIP_SECURITY, IsDocsOnly.
//  2. Scan/rework loop bounded by SECURITY_MAX_REWORK_CYCLES.
//  3. Per cycle: render security_scan prompt → invoke agent → parse findings
//     → classify → escalate unfixable → rework fixable → build-gate.
//  4. Emit verdict + env exports.
//
// The stage never logs to a per-stage log file the way the bash side does —
// staglog writes to stderr, and the result envelope carries the structured
// outcome. The m35.2 dogfood run confirms the visible operator output stays
// indistinguishable from the bash version.
package security

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/proto"
	sec "github.com/geoffgodwin/tekhton/internal/security"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// AgentRunner is the seam between the security stage and the supervisor.
// Production wires the in-process supervisor; tests wire a recording fake.
type AgentRunner interface {
	Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)
}

// BuildGateRunner is the seam for the post-rework build gate. The bash
// stage shelled to `run_build_gate`, which after m31.1 execs
// `tekhton gate build`. The Go port preserves the subprocess semantics
// behind an interface so tests can drive both pass and fail paths
// deterministically without invoking the real binary.
type BuildGateRunner interface {
	Run(ctx context.Context, projectDir, stageLabel string) error
}

// agentRunner is the package-level supervisor seam. Tests overwrite it via
// SetAgentRunner; production uses the default in-process supervisor.
var agentRunner AgentRunner = supervisor.New(nil, nil)

// buildGateRunner is the package-level build-gate seam. Defaults to the
// subprocess implementation that execs `tekhton gate build`.
var buildGateRunner BuildGateRunner = subprocessBuildGate{}

// SetAgentRunner replaces the package-level agent seam. Returns the previous
// runner so tests can restore it.
func SetAgentRunner(r AgentRunner) AgentRunner {
	prev := agentRunner
	agentRunner = r
	return prev
}

// SetBuildGateRunner replaces the package-level build-gate seam.
func SetBuildGateRunner(r BuildGateRunner) BuildGateRunner {
	prev := buildGateRunner
	buildGateRunner = r
	return prev
}

// RunStage is the m35.2 entry point. Signature matches stagerunner.StageImpl
// so DefaultStageDefs[StageSecurity] can register it directly.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig(req)
	log := staglog.New(req)
	log.Header("Security")

	// --- Skip checks (order matches bash: agent-disabled → flag → docs-only) ---
	if !cfg.AgentEnabled {
		log.Info("[security] Security stage disabled (SECURITY_AGENT_ENABLED=false). Skipping.")
		return skipResult(req, "agent_disabled"), nil
	}
	if cfg.SkipFlag {
		log.Info("[security] Security stage skipped (--skip-security). Skipping.")
		return skipResult(req, "skip_flag"), nil
	}
	if docsOnly, _ := sec.IsDocsOnly(cfg.CoderSummaryFile); docsOnly {
		log.Info("[security] All changed files are docs/config/assets. Skipping security scan.")
		return skipResult(req, "docs_only"), nil
	}

	// --- Scan/rework loop ---
	var (
		cycle      int
		agentCalls int
		findings   []sec.Finding
		humanAct   bool
	)
	esc := sec.NewEscalatorWithPath(humanActionFile(cfg))

	scanNeeded := true
	noFindings := false
	for scanNeeded {
		scanNeeded = false

		scanRes, err := invokeScanAgent(ctx, cfg, req)
		if err != nil {
			log.Warn(fmt.Sprintf("[security] Scan agent invocation failed: %v", err))
			return failResult(req, "scan_failed", agentCalls), err
		}
		agentCalls++
		_ = scanRes
		log.Success("Security scan finished.")

		// --- Parse findings ---
		findings, err = sec.ParseReport(cfg.ReportFile)
		if err != nil {
			log.Warn(fmt.Sprintf("[security] Error parsing %s: %v", cfg.ReportFile, err))
			return failResult(req, "report_parse_error", agentCalls), err
		}
		if len(findings) == 0 {
			log.Info(fmt.Sprintf("[security] No structured findings in %s. Proceeding.", cfg.ReportFile))
			noFindings = true
			break
		}
		log.Info(fmt.Sprintf("[security] Found %d finding(s).", len(findings)))

		// --- Classify ---
		fixable := sec.BuildFixableBlock(findings, cfg.BlockSeverity)
		unfixable := sec.BuildUnfixableBlock(findings, cfg.BlockSeverity)
		notes := sec.BuildNotesBlock(findings, cfg.BlockSeverity)

		// --- Write notes file (best-effort) ---
		if err := WriteNotesFile(cfg.NotesFile, notes, unfixable, cfg.UnfixablePolicy, cfg.Now()); err != nil {
			log.Warn(fmt.Sprintf("[security] Failed to write notes file: %v", err))
		}

		// --- Handle unfixable ---
		if unfixable != "" {
			cont, escErr := esc.HandleUnfixable(cfg.UnfixablePolicy, unfixable, cfg.Task)
			if escErr != nil {
				log.Warn(fmt.Sprintf("[security] Failed to record human-action escalation: %v", escErr))
			}
			if !cont {
				// halt policy
				log.Warn("[security] Pipeline halted — unfixable CRITICAL/HIGH security findings detected.")
				log.Warn(fmt.Sprintf("[security] Review %s and resolve manually.", cfg.ReportFile))
				writeHaltState(cfg)
				exportEnvBlocks(findings, cycle, cfg.ReportFile)
				return &proto.StageResultV1{
					Proto:       proto.StageResultProtoV1,
					Stage:       req.Stage,
					Verdict:     proto.VerdictBlock,
					ExitReason:  "security_halt",
					AgentCalls:  agentCalls,
					HumanAction: true,
				}, nil
			}
			if cfg.UnfixablePolicy == "escalate" || cfg.UnfixablePolicy == "" {
				humanAct = true
			}
		}

		// --- Route fixable to rework ---
		if fixable != "" && cycle < cfg.MaxRework {
			cycle++
			firstFix := firstLine(fixable)
			log.Info(fmt.Sprintf("[security] Rework cycle %d / %d — fixing %s...", cycle, cfg.MaxRework, firstFix))

			if _, err := invokeReworkAgent(ctx, cfg, fixable, cycle); err != nil {
				log.Warn(fmt.Sprintf("[security] Rework agent invocation failed: %v", err))
				return failResult(req, "rework_failed", agentCalls), err
			}
			agentCalls++

			// --- Post-rework build gate ---
			if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "security-rework"); err != nil {
				log.Warn("[security] Build gate failed after security rework. Proceeding to reviewer.")
				break
			}
			scanNeeded = true
		}
	}

	exportEnvBlocks(findings, cycle, cfg.ReportFile)

	exitReason := "complete"
	if noFindings && agentCalls == 1 {
		exitReason = "no_findings"
	}

	log.Info(fmt.Sprintf("[security] Security stage complete. Rework cycles: %d.", cycle))
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictPass,
		ExitReason:  exitReason,
		AgentCalls:  agentCalls,
		HumanAction: humanAct,
	}, nil
}

// skipResult returns a verdict=skip result with the supplied reason.
func skipResult(req *proto.StageRequestV1, reason string) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictSkip,
		ExitReason: reason,
	}
}

// failResult returns a verdict=fail result with the supplied reason and
// agent-call count.
func failResult(req *proto.StageRequestV1, reason string, agentCalls int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictFail,
		ExitReason: reason,
		AgentCalls: agentCalls,
	}
}

// firstLine returns the substring up to the first newline (matches the
// bash `${fixable_block%%$'\n'*}` pattern). Returns the entire string when
// no newline is present.
func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

// exportEnvBlocks writes the three SECURITY_* env vars consumed by
// downstream stages. Mirrors stages/security.sh:149-164 verbatim. The
// values land in process env so subsequent bash stages (review, tester)
// read them via shell expansion. m35.2 keeps this seam — until every
// downstream stage is also Go-native, the env-export contract is the
// integration surface.
func exportEnvBlocks(findings []sec.Finding, cycle int, reportFile string) {
	var fb strings.Builder
	for _, f := range findings {
		fb.WriteString("- [")
		fb.WriteString(string(f.Severity))
		fb.WriteString("] ")
		fb.WriteString(f.Description)
		fb.WriteByte('\n')
	}
	_ = os.Setenv("SECURITY_FINDINGS_BLOCK", fb.String())

	fixes := ""
	if cycle > 0 {
		fixes = fmt.Sprintf("Security rework applied %d cycle(s). Review %s for details of findings and fixes.",
			cycle, reportFile)
	}
	_ = os.Setenv("SECURITY_FIXES_BLOCK", fixes)
	_ = os.Setenv("SECURITY_REWORK_CYCLES_DONE", strconv.Itoa(cycle))
}

// writeHaltState records the security_halt resume context. Mirrors the
// bash `write_pipeline_state "security" "security_halt" ...` call from
// _handle_unfixable_findings. Best-effort: failure is logged but does not
// flip the stage outcome.
func writeHaltState(cfg config) {
	statePath := envOr("PIPELINE_STATE_FILE",
		filepath.Join(envOr("TEKHTON_DIR", ".tekhton"), "PIPELINE_STATE.json"))
	if !filepath.IsAbs(statePath) {
		statePath = filepath.Join(cfg.ProjectDir, statePath)
	}
	store := state.New(statePath)
	resumeFlag := "--start-at security"
	if cfg.MilestoneMode {
		resumeFlag = "--milestone " + resumeFlag
	}
	_ = store.Update(func(snap *proto.StateSnapshotV1) {
		snap.ExitStage = "security"
		snap.ExitReason = "security_halt"
		snap.ResumeTask = cfg.Task
		snap.ResumeFlag = resumeFlag
		snap.Notes = "Unfixable security findings with halt policy."
	})
}

// humanActionFile resolves HUMAN_ACTION_FILE for this stage run. Honors the
// env override; falls back to the shared bash default
// (.tekhton/HUMAN_ACTION_REQUIRED.md under projectDir).
func humanActionFile(cfg config) string {
	override := os.Getenv("HUMAN_ACTION_FILE")
	if override == "" {
		override = filepath.Join(envOr("TEKHTON_DIR", ".tekhton"), "HUMAN_ACTION_REQUIRED.md")
	}
	if filepath.IsAbs(override) {
		return override
	}
	return filepath.Join(cfg.ProjectDir, override)
}

// writePromptTmpFile writes content to an os.CreateTemp file and returns
// its path plus a cleanup func. Shared by scan.go and rework.go.
func writePromptTmpFile(content string) (string, func(), error) {
	f, err := os.CreateTemp("", "tekhton-security-prompt-*.md")
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

// subprocessBuildGate is the default BuildGateRunner — execs
// `tekhton gate build --stage-label <label>`. Matches the post-m31.1
// shim that the bash stage previously transitively called.
type subprocessBuildGate struct{}

func (subprocessBuildGate) Run(ctx context.Context, projectDir, stageLabel string) error {
	bin := resolveTekhtonBin()
	if bin == "" {
		return nil
	}
	cmd := exec.CommandContext(ctx, bin, "gate", "build", "--stage-label", stageLabel)
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func resolveTekhtonBin() string {
	if v := os.Getenv("TEKHTON_BIN"); v != "" {
		if _, err := os.Stat(v); err == nil {
			return v
		}
	}
	if home := os.Getenv("TEKHTON_HOME"); home != "" {
		cand := filepath.Join(home, "bin", "tekhton")
		if _, err := os.Stat(cand); err == nil {
			return cand
		}
	}
	if p, err := exec.LookPath("tekhton"); err == nil {
		return p
	}
	return ""
}
