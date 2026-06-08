package architect

import (
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// config holds the resolved architect-stage configuration for a single
// RunStage invocation. Field names mirror the bash env vars (camel-case
// Go style); each value is resolved once at stage entry so the stage
// body works against a stable snapshot.
type config struct {
	ProjectDir  string
	TekhtonHome string
	PromptsDir  string

	// Per-agent dispatch
	ArchitectModel    string
	ArchitectMaxTurns int
	ArchitectTools    string

	CoderModel    string
	CoderMaxTurns int
	CoderTools    string

	JrCoderModel    string
	JrCoderMaxTurns int
	JrCoderTools    string

	StandardModel    string
	ReviewerMaxTurns int
	ReviewerTools    string

	BuildFixTools string

	// File outputs
	ArchitectPlanFile string
	DriftLogFile      string
	HumanActionFile   string
	LogDir            string
	Timestamp         string

	MilestoneMode bool

	// Provider is the agent backend injected by the runner.
	Provider provider.Provider
}

// loadConfig resolves the per-stage configuration from env + the stage
// request. Mirrors the env-read pattern in stages/architect.sh:64-71 +
// the model/turn defaults from lib/agent.sh and lib/config_defaults.sh.
func loadConfig(req *proto.StageRequestV1) config {
	projectDir := resolveProjectDir(req)
	tekhtonHome := envOrFromReq(req, "TEKHTON_HOME", "")
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")

	standardModel := envOr("CLAUDE_STANDARD_MODEL", "claude-sonnet-4-6")
	architectMaxTurns := envInt("ARCHITECT_MAX_TURNS", 25)
	if envBool("MILESTONE_MODE", false) {
		architectMaxTurns = envInt("MILESTONE_ARCHITECT_MAX_TURNS", 50)
	}

	cfg := config{
		ProjectDir:  projectDir,
		TekhtonHome: tekhtonHome,
		PromptsDir:  resolvePromptsDir(req),

		ArchitectModel:    envOr("CLAUDE_ARCHITECT_MODEL", standardModel),
		ArchitectMaxTurns: architectMaxTurns,
		ArchitectTools:    envOr("AGENT_TOOLS_ARCHITECT", ""),

		CoderModel:    envOr("CLAUDE_CODER_MODEL", "claude-sonnet-4-6"),
		CoderMaxTurns: envInt("CODER_MAX_TURNS", 80),
		CoderTools:    envOr("AGENT_TOOLS_CODER", ""),

		JrCoderModel:    envOr("CLAUDE_JR_CODER_MODEL", "claude-sonnet-4-6"),
		JrCoderMaxTurns: envInt("JR_CODER_MAX_TURNS", 40),
		JrCoderTools:    envOr("AGENT_TOOLS_JR_CODER", ""),

		StandardModel:    standardModel,
		ReviewerMaxTurns: envInt("REVIEWER_MAX_TURNS", 20),
		ReviewerTools:    envOr("AGENT_TOOLS_REVIEWER", ""),

		BuildFixTools: envOr("AGENT_TOOLS_BUILD_FIX", ""),

		ArchitectPlanFile: resolveProjectRelative(projectDir,
			envOr("ARCHITECT_PLAN_FILE", filepath.Join(tekhtonDir, "ARCHITECT_PLAN.md"))),
		DriftLogFile: resolveProjectRelative(projectDir,
			envOr("DRIFT_LOG_FILE", "DRIFT_LOG.md")),
		HumanActionFile: resolveProjectRelative(projectDir,
			envOr("HUMAN_ACTION_FILE", "HUMAN_ACTION_REQUIRED.md")),
		LogDir:    resolveProjectRelative(projectDir, envOr("LOG_DIR", ".claude/logs")),
		Timestamp: envOr("TIMESTAMP", ""),

		MilestoneMode: envBool("MILESTONE_MODE", false),
		Provider:      stageProvider,
	}
	return cfg
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

func resolveProjectRelative(projectDir, path string) string {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(projectDir, path)
}
