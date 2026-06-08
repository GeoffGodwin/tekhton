package architect

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/drift"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/stages/staglog"
)

// BuildGateRunner is the seam for the post-remediation build gate. The
// bash architect.sh shelled to `run_build_gate`, which after m31.1 execs
// `tekhton gate build`. The Go port preserves the subprocess semantics
// behind an interface so tests can drive both pass and fail paths
// deterministically without invoking the real binary.
type BuildGateRunner interface {
	Run(ctx context.Context, projectDir, stageLabel string) error
}

// TUICaller is the seam for `_tui_call SUBCMD ...` — execs
// `tekhton tui SUBCMD ...` against the active status file. Tests substitute
// a recording fake so substage-begin / stage-end verdicts can be asserted
// without spawning subprocesses.
type TUICaller interface {
	Call(ctx context.Context, sub string, args ...string)
}

var (
	stageProvider   provider.Provider
	buildGateRunner BuildGateRunner = subprocessBuildGate{}
	tuiCaller       TUICaller       = subprocessTUI{}
)

// SetProvider replaces the package-level provider. Returns the previous
// value so tests can restore it.
func SetProvider(p provider.Provider) provider.Provider {
	prev := stageProvider
	stageProvider = p
	return prev
}

// SetBuildGateRunner replaces the package-level build-gate seam.
func SetBuildGateRunner(r BuildGateRunner) BuildGateRunner {
	prev := buildGateRunner
	buildGateRunner = r
	return prev
}

// SetTUICaller replaces the package-level TUI seam. Tests use this to
// assert lifecycle (stage-begin, substage-begin, stage-end verdict).
func SetTUICaller(c TUICaller) TUICaller {
	prev := tuiCaller
	tuiCaller = c
	return prev
}

// RunStage is the m36.1 entry point. Mirrors stages/architect.sh:22-417
// — drift context load → architect agent → plan parse → sr/jr router →
// post-remediation build + expedited review → drift resolution + OOS
// re-add → design-doc observation surfacing → audit counter reset →
// archive plan.
//
// The stage NEVER returns verdict=fail. Every error path in the bash
// version exited with status 0; the Go port preserves that behavior so
// the outer dispatcher does not mistakenly block the main task on an
// audit pass that hits an API blip.
func RunStage(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
	cfg := loadConfig(req)
	log := staglog.New(req)
	log.Header("Pre-stage 2 — Architect Audit")

	architectStarted := false
	if os.Getenv("_TUI_ACTIVE") == "true" {
		tuiCaller.Call(ctx, "stage-begin", "--label", "architect", "--model", cfg.ArchitectModel)
		architectStarted = true
	}

	// --- 1. Invoke architect agent -------------------------------------
	obsCount := unresolvedDriftCount(cfg)
	log.Info(fmt.Sprintf("Invoking architect agent (%d observations, max %d turns)...", obsCount, cfg.ArchitectMaxTurns))

	agentRes, agentErr := runArchitectAgent(ctx, cfg)
	if agentRes != nil && agentRes.ErrorCategory == "UPSTREAM" {
		log.Warn(fmt.Sprintf("Architect hit an API error (%s): %s", agentRes.ErrorSubcategory, agentRes.ErrorMessage))
		log.Warn("Drift observations remain unresolved — will retry next audit cycle.")
		stageEnd(ctx, architectStarted, cfg, "UPSTREAM_ERROR")
		return passResult(req, "upstream_error", 1), nil
	}
	if agentErr != nil {
		log.Warn(fmt.Sprintf("Architect agent failed: %v", agentErr))
		log.Warn("Drift observations remain unresolved — will retry next audit cycle.")
		stageEnd(ctx, architectStarted, cfg, "UPSTREAM_ERROR")
		return passResult(req, "agent_error", 1), nil
	}
	log.Success("Architect agent finished.")

	// --- 2. Validate plan ----------------------------------------------
	if !fileExists(cfg.ArchitectPlanFile) {
		log.Warn(fmt.Sprintf("Architect did not produce %s. Skipping remediation.", cfg.ArchitectPlanFile))
		log.Warn("Drift observations remain unresolved — will retry next audit cycle.")
		stageEnd(ctx, architectStarted, cfg, "NO_PLAN")
		return passResult(req, "no_plan", 1), nil
	}
	log.Info(fmt.Sprintf("%s produced. Parsing sections...", cfg.ArchitectPlanFile))

	// --- 3. Parse plan + route -----------------------------------------
	planF, err := os.Open(cfg.ArchitectPlanFile)
	if err != nil {
		log.Warn(fmt.Sprintf("Failed to open architect plan: %v", err))
		stageEnd(ctx, architectStarted, cfg, "NO_PLAN")
		return passResult(req, "plan_open_error", 1), nil
	}
	plan, parseErr := parsePlan(planF)
	_ = planF.Close()
	if parseErr != nil {
		log.Warn(fmt.Sprintf("Failed to parse architect plan: %v", parseErr))
		stageEnd(ctx, architectStarted, cfg, "NO_PLAN")
		return passResult(req, "plan_parse_error", 1), nil
	}

	agentCalls := 1
	remediationStarted := false
	hasSimplification := plan.HasSimplification()
	hasJrWork := plan.HasJrWork()

	if hasSimplification || hasJrWork {
		if os.Getenv("_TUI_ACTIVE") == "true" {
			tuiCaller.Call(ctx, "substage-begin", "--label", "architect-remediation")
			remediationStarted = true
		}
	}

	if hasSimplification {
		log.Info("Simplification items found — routing to senior coder...")
		if err := runRework(ctx, remediationSr, cfg); err != nil {
			log.Warn(fmt.Sprintf("Senior coder remediation failed: %v", err))
		} else {
			log.Success("Senior coder remediation finished.")
		}
		agentCalls++
	} else {
		log.Info("No Simplification items — skipping senior coder.")
	}

	if hasJrWork {
		log.Info("Staleness/Dead Code/Naming items found — routing to jr coder...")
		if err := runRework(ctx, remediationJr, cfg); err != nil {
			log.Warn(fmt.Sprintf("Jr coder remediation failed: %v", err))
		} else {
			log.Success("Jr coder remediation finished.")
		}
		agentCalls++
	} else {
		log.Info("No Staleness/Dead Code/Naming items — skipping jr coder.")
	}

	// --- 4. Build gate + expedited review ------------------------------
	if hasSimplification || hasJrWork {
		if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-architect-remediation"); err != nil {
			log.Warn("Build gate failed after architect remediation.")
			log.Warn("Attempting build fix...")
			if err := runBuildFix(ctx, cfg); err != nil {
				log.Warn(fmt.Sprintf("Build fix agent failed: %v", err))
			}
			agentCalls++
			if err := buildGateRunner.Run(ctx, cfg.ProjectDir, "post-architect-remediation-retry"); err != nil {
				log.Warn("Build still broken after architect remediation. Skipping review.")
				log.Warn("Drift observations NOT resolved — will retry next audit cycle.")
				resetAuditCounter(cfg, log)
				substageEnd(ctx, remediationStarted, "BUILD_BROKEN")
				stageEnd(ctx, architectStarted, cfg, "BUILD_BROKEN")
				return passResult(req, "build_broken", agentCalls), nil
			}
		}

		log.Info("Running expedited review of architect remediation...")
		if err := runExpeditedReview(ctx, cfg); err != nil {
			log.Warn(fmt.Sprintf("Expedited review failed: %v", err))
		} else {
			log.Success("Expedited review finished.")
		}
		agentCalls++
	}

	// --- 5. Resolve drift observations + re-add OOS --------------------
	preResolve := unresolvedDriftCount(cfg)
	if preResolve > 0 {
		oos := plan.OutOfScope()
		log.Info(fmt.Sprintf("Ticking all %d drift observations...", preResolve))
		l := drift.NewLog(cfg.DriftLogFile)
		if err := l.ResolveAllObservations(); err != nil {
			log.Warn(fmt.Sprintf("drift resolve-all failed: %v", err))
		}
		if len(oos) > 0 {
			log.Info(fmt.Sprintf("Re-adding %d out-of-scope item(s) to drift log...", len(oos)))
			if err := l.AppendEntries(oosBulletLines(oos)); err != nil {
				log.Warn(fmt.Sprintf("drift entries append failed: %v", err))
			}
		}
		postResolve := unresolvedDriftCount(cfg)
		log.Info(fmt.Sprintf("Drift resolution: %d → %d unresolved.", preResolve, postResolve))
	}

	// --- 6. Surface design doc observations to human action ------------
	designDoc := plan.DesignDocObservations()
	if len(designDoc) > 0 {
		log.Info("Adding design doc observations to human action file...")
		h := drift.NewHumanAction(cfg.HumanActionFile)
		for _, entry := range designDoc {
			if err := h.Append("architect", entry); err != nil {
				log.Warn(fmt.Sprintf("human-action append failed: %v", err))
			}
		}
	}

	// --- 7. Reset audit counter + archive plan -------------------------
	resetAuditCounter(cfg, log)
	archivePlan(cfg, log)

	substageEnd(ctx, remediationStarted, "")
	stageEnd(ctx, architectStarted, cfg, "")
	log.Success("Architect audit complete.")

	return passResult(req, "audit_complete", agentCalls), nil
}

// --- helpers ---------------------------------------------------------------

func passResult(req *proto.StageRequestV1, reason string, agentCalls int) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:      proto.StageResultProtoV1,
		Stage:      req.Stage,
		Verdict:    proto.VerdictPass,
		ExitReason: reason,
		AgentCalls: agentCalls,
	}
}

func stageEnd(ctx context.Context, started bool, cfg config, verdict string) {
	if !started {
		return
	}
	args := []string{"--label", "architect", "--model", cfg.ArchitectModel}
	if verdict != "" {
		args = append(args, "--verdict", verdict)
	}
	tuiCaller.Call(ctx, "stage-end", args...)
}

func substageEnd(ctx context.Context, started bool, verdict string) {
	if !started {
		return
	}
	args := []string{"--label", "architect-remediation"}
	if verdict != "" {
		args = append(args, "--verdict", verdict)
	}
	tuiCaller.Call(ctx, "substage-end", args...)
}

// runArchitectAgent renders the architect prompt and dispatches it. Returns
// the provider result so the caller can branch on ErrorCategory/UPSTREAM.
func runArchitectAgent(ctx context.Context, cfg config) (*provider.Result, error) {
	body, err := renderArchitectPrompt(cfg)
	if err != nil {
		return nil, fmt.Errorf("render architect prompt: %w", err)
	}
	return cfg.Provider.RunAgent(ctx, &provider.Request{
		Prompt:       body,
		Label:        "Architect",
		Model:        cfg.ArchitectModel,
		MaxTurns:     cfg.ArchitectMaxTurns,
		WorkingDir:   cfg.ProjectDir,
		AllowedTools: cfg.ArchitectTools,
	})
}

// resetAuditCounter wraps drift.ResetRunsSinceAudit with a logged warning
// path so the bash `|| true` tolerance is preserved.
func resetAuditCounter(cfg config, log staglog.Logger) {
	l := drift.NewLog(cfg.DriftLogFile)
	if err := l.ResetRunsSinceAudit(); err != nil {
		log.Warn(fmt.Sprintf("drift reset-audit failed: %v", err))
		return
	}
	log.Info("Runs-since-audit counter reset.")
}

func unresolvedDriftCount(cfg config) int {
	l := drift.NewLog(cfg.DriftLogFile)
	n, err := l.CountUnresolved()
	if err != nil {
		return 0
	}
	return n
}

// archivePlan moves ARCHITECT_PLAN.md into the log dir with a timestamp
// prefix. Best-effort: any failure is logged + tolerated.
func archivePlan(cfg config, log staglog.Logger) {
	if !fileExists(cfg.ArchitectPlanFile) {
		return
	}
	if cfg.LogDir == "" {
		return
	}
	if err := os.MkdirAll(cfg.LogDir, 0o755); err != nil {
		log.Warn(fmt.Sprintf("create log dir: %v", err))
		return
	}
	base := filepath.Base(cfg.ArchitectPlanFile)
	dest := filepath.Join(cfg.LogDir, cfg.Timestamp+"_"+base)
	if cfg.Timestamp == "" {
		dest = filepath.Join(cfg.LogDir, base)
	}
	if err := os.Rename(cfg.ArchitectPlanFile, dest); err != nil {
		log.Warn(fmt.Sprintf("archive plan: %v", err))
		return
	}
	log.Info(fmt.Sprintf("%s archived and removed from working directory.", cfg.ArchitectPlanFile))
}

// oosBulletLines normalizes raw entry bodies for drift.Log.AppendEntries.
// AppendEntries owns the `- [ ] [date | "architect audit"] ` prefix, so
// the body alone is passed in (matching the bash `tekhton drift entries
// --entry "$body"` semantics).
func oosBulletLines(entries []string) []string {
	out := make([]string, 0, len(entries))
	for _, e := range entries {
		body := strings.TrimSpace(e)
		if body == "" {
			continue
		}
		out = append(out, body)
	}
	return out
}

func fileExists(p string) bool {
	if p == "" {
		return false
	}
	_, err := os.Stat(p)
	return err == nil
}

// subprocessBuildGate is the default BuildGateRunner — execs
// `tekhton gate build --stage-label <label>`. Matches the post-m31.1
// shim that the bash stage transitively called.
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

// subprocessTUI is the default TUICaller — execs `tekhton tui SUBCMD ...`
// against the active status file. Matches lib/sidecar_lifecycle.sh::_tui_call
// behavior verbatim (silent no-op on any failure).
type subprocessTUI struct{}

func (subprocessTUI) Call(ctx context.Context, sub string, args ...string) {
	bin := resolveTekhtonBin()
	if bin == "" || sub == "" {
		return
	}
	cmdArgs := []string{"tui", sub}
	if sf := os.Getenv("_TUI_STATUS_FILE"); sf != "" {
		cmdArgs = append(cmdArgs, "--status-file", sf)
	}
	cmdArgs = append(cmdArgs, args...)
	cmd := exec.CommandContext(ctx, bin, cmdArgs...)
	cmd.Stdout = nil
	cmd.Stderr = nil
	_ = cmd.Run()
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
