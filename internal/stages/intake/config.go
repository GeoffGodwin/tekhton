package intake

import (
	"os"
	"path/filepath"
	"strings"

	pkgintake "github.com/geoffgodwin/tekhton/internal/intake"
	"github.com/geoffgodwin/tekhton/internal/manifest"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// config holds the resolved intake-stage configuration for a single RunStage
// invocation. Field names mirror the bash env vars. Each value resolves once
// at stage entry so the stage body works against a stable snapshot.
type config struct {
	ProjectDir       string
	TekhtonHome      string
	TekhtonDir       string
	PromptsDir       string
	SessionDir       string
	LogFile          string
	Task             string
	CurrentMilestone string

	AgentEnabled     bool
	HumanMode        bool
	MilestoneMode    bool
	Cached           bool
	CompleteMode     bool
	HealthEnabled    bool
	CausalLogEnabled bool

	ReportFile         string
	RoleFile           string
	HumanNotesFile     string
	ProjectIndexFile   string
	ProjectRulesFile   string
	MilestoneDir       string
	ClarificationsFile string

	Model    string
	MaxTurns int

	AutoSplit       bool
	ConfirmTweaks   bool
	TweakMinSizePct int

	UIProjectDetected string
	UIFramework       string

	// DagEnabled mirrors MILESTONE_DAG_ENABLED.
	DagEnabled bool

	// Provider is the agent backend injected by the runner. Must be non-nil
	// before invokeIntakeAgent is reached; nil panics on first RunAgent call
	// so the wiring gap surfaces immediately in tests.
	Provider provider.Provider
}

// loadConfig resolves the per-stage configuration. Mirrors the env-read
// pattern in stages/intake.sh and lib/intake_helpers.sh, preserving every
// ${VAR:-DEFAULT} form per the m27 env contract.
func loadConfig(req *proto.StageRequestV1) config {
	projectDir := resolveProjectDir(req)
	tekhtonHome := envOrFromReq(req, "TEKHTON_HOME", "")
	tekhtonDir := envOrFromReq(req, "TEKHTON_DIR", ".tekhton")

	cfg := config{
		ProjectDir:       projectDir,
		TekhtonHome:      tekhtonHome,
		TekhtonDir:       tekhtonDir,
		PromptsDir:       resolvePromptsDir(req),
		SessionDir:       envOrFromReq(req, "TEKHTON_SESSION_DIR", ""),
		LogFile:          req.LogFile,
		Task:             envOrFromReq(req, "TASK", req.Task),
		CurrentMilestone: envOrFromReq(req, "_CURRENT_MILESTONE", req.Milestone),

		AgentEnabled:     envBoolFromReq(req, "INTAKE_AGENT_ENABLED", true),
		HumanMode:        envBoolFromReq(req, "HUMAN_MODE", false),
		MilestoneMode:    envBoolFromReq(req, "MILESTONE_MODE", false),
		Cached:           envBoolFromReq(req, "INTAKE_CACHED", false),
		CompleteMode:     envBoolFromReq(req, "COMPLETE_MODE", false),
		HealthEnabled:    envBoolFromReq(req, "HEALTH_ENABLED", true),
		CausalLogEnabled: envBoolFromReq(req, "CAUSAL_LOG_ENABLED", true),

		ReportFile: resolveProjectRelative(projectDir,
			envOr("INTAKE_REPORT_FILE", filepath.Join(tekhtonDir, "INTAKE_REPORT.md"))),
		RoleFile:           envOr("INTAKE_ROLE_FILE", ".claude/agents/intake.md"),
		HumanNotesFile:     envOr("HUMAN_NOTES_FILE", filepath.Join(tekhtonDir, "HUMAN_NOTES.md")),
		ProjectIndexFile:   envOr("PROJECT_INDEX_FILE", filepath.Join(tekhtonDir, "PROJECT_INDEX.md")),
		ProjectRulesFile:   envOr("PROJECT_RULES_FILE", "CLAUDE.md"),
		MilestoneDir:       envOr("MILESTONE_DIR", ".claude/milestones"),
		ClarificationsFile: envOr("CLARIFICATIONS_FILE", filepath.Join(tekhtonDir, "CLARIFICATIONS.md")),

		Model:    envOr("CLAUDE_INTAKE_MODEL", "claude-sonnet-4-6"),
		MaxTurns: envInt("INTAKE_MAX_TURNS", 10),

		AutoSplit:       envBool("INTAKE_AUTO_SPLIT", false),
		ConfirmTweaks:   envBool("INTAKE_CONFIRM_TWEAKS", false),
		TweakMinSizePct: envInt("INTAKE_TWEAK_MIN_SIZE_PCT", 50),

		UIProjectDetected: envOr("UI_PROJECT_DETECTED", "false"),
		UIFramework:       envOr("UI_FRAMEWORK", ""),

		DagEnabled: envBoolFromReq(req, "MILESTONE_DAG_ENABLED", true),
		Provider:   stageProvider,
	}

	return cfg
}

// newHelpers builds an intake.Helpers populated from the stage config. Used
// for content-hash / report-parsing / tweak-application calls.
func newHelpers(cfg config) *pkgintake.Helpers {
	msDir := resolveProjectRelative(cfg.ProjectDir, cfg.MilestoneDir)
	h := &pkgintake.Helpers{
		ProjectDir:         cfg.ProjectDir,
		SessionDir:         cfg.SessionDir,
		MilestoneDir:       msDir,
		ProjectRulesFile:   resolveProjectRelative(cfg.ProjectDir, cfg.ProjectRulesFile),
		ClarificationsFile: cfg.ClarificationsFile,
		DagEnabled:         cfg.DagEnabled,
	}
	// Wire the manifest-backed bare-id → slug resolver so MilestoneContent
	// can locate slug-named files (e.g. "m37.1-review-helpers-and-parser.md")
	// when given "37.1" or "m37.1". Without this, the bare-id direct join
	// `<MilestoneDir>/37.1.md` misses, the inline CLAUDE.md fallback can't
	// find per-milestone content, and intake sees only the task title — which
	// produced the m37.1 / m42 NEEDS_CLARITY false-positives (intake.log
	// "could not locate milestone file for 42" is the same symptom).
	h.MilestoneFileResolver = func(num string) string {
		man, err := manifest.Load(filepath.Join(msDir, "MANIFEST.cfg"))
		if err != nil {
			return ""
		}
		id := num
		if !strings.HasPrefix(id, "m") {
			id = "m" + id
		}
		if entry, ok := man.Get(id); ok {
			return entry.File
		}
		return ""
	}
	return h
}

func resolveProjectDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "PROJECT_DIR", ""); v != "" {
		return v
	}
	wd, _ := os.Getwd()
	return wd
}

func resolvePromptsDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "TEKHTON_HOME", ""); v != "" {
		return filepath.Join(v, "prompts")
	}
	return "prompts"
}

// resolveProjectRelative joins relative paths under projectDir.
func resolveProjectRelative(projectDir, path string) string {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(projectDir, path)
}

// resolveTekhtonBin mirrors the architect/security stage helpers.
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
	return ""
}
