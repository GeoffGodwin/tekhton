package review

import (
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// config holds the resolved review-stage configuration for one RunStage
// invocation. Field names mirror the bash env vars one-to-one so future
// readers can grep across the bash port history. Values are resolved once at
// stage entry so the stage body works against a stable snapshot.
type config struct {
	ProjectDir  string
	TekhtonHome string
	PromptsDir  string
	TekhtonDir  string

	Task          string
	Milestone     string
	MilestoneMode bool

	MaxReviewCycles      int
	ReviewerMaxTurns     int
	ReviewerMaxTurnsCap  int
	AdjustedReviewerTurn int
	CoderMaxTurns        int
	EffectiveCoderTurns  int
	JrCoderMaxTurns      int
	EffectiveJrTurns     int

	ReviewerModel string
	CoderModel    string
	JrCoderModel  string

	ReviewerTools string
	CoderTools    string
	JrCoderTools  string
	BuildFixTools string

	ReviewerReportFile    string // resolved (absolute) — used for I/O
	ReviewerReportFileRaw string // raw env value or env-default literal — used in synthesized-body text for bash byte-parity
	CoderSummaryFile      string
	SpecialistReportFile  string

	ReviewSkipThreshold int

	// Provider is the agent backend injected by the runner.
	Provider provider.Provider

	// Diff-stat helper seam — overrideable for tests.
	diffStatTotal func(projectDir string) (int, error)
}

func loadConfig(req *proto.StageRequestV1) config {
	projectDir := resolveProjectDir(req)
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")

	cfg := config{
		ProjectDir:    projectDir,
		TekhtonHome:   envOrFromReq(req, "TEKHTON_HOME", ""),
		PromptsDir:    resolvePromptsDir(req),
		TekhtonDir:    tekhtonDir,
		Task:          envOrFromReq(req, "TASK", req.Task),
		Milestone:     envOrFromReq(req, "MILESTONE_ID", req.Milestone),
		MilestoneMode: envBool("MILESTONE_MODE", false),

		MaxReviewCycles:      envInt("MAX_REVIEW_CYCLES", 3),
		ReviewerMaxTurns:     envInt("REVIEWER_MAX_TURNS", 20),
		ReviewerMaxTurnsCap:  envInt("REVIEWER_MAX_TURNS_CAP", 60),
		AdjustedReviewerTurn: envInt("ADJUSTED_REVIEWER_TURNS", 0),
		CoderMaxTurns:        envInt("CODER_MAX_TURNS", 80),
		EffectiveCoderTurns:  envInt("EFFECTIVE_CODER_MAX_TURNS", 0),
		JrCoderMaxTurns:      envInt("JR_CODER_MAX_TURNS", 40),
		EffectiveJrTurns:     envInt("EFFECTIVE_JR_CODER_MAX_TURNS", 0),

		ReviewerModel: envOr("CLAUDE_REVIEWER_MODEL", "claude-sonnet-4-6"),
		CoderModel:    envOr("CLAUDE_CODER_MODEL", "claude-sonnet-4-6"),
		JrCoderModel:  envOr("CLAUDE_JR_CODER_MODEL", "claude-sonnet-4-6"),

		ReviewerTools: envOr("AGENT_TOOLS_REVIEWER", ""),
		CoderTools:    envOr("AGENT_TOOLS_CODER", ""),
		JrCoderTools:  envOr("AGENT_TOOLS_JR_CODER", ""),
		BuildFixTools: envOr("AGENT_TOOLS_BUILD_FIX", ""),

		ReviewerReportFile: resolveProjectRelative(projectDir,
			envOr("REVIEWER_REPORT_FILE", filepath.Join(tekhtonDir, "REVIEWER_REPORT.md"))),
		ReviewerReportFileRaw: envOr("REVIEWER_REPORT_FILE", filepath.Join(tekhtonDir, "REVIEWER_REPORT.md")),
		CoderSummaryFile: resolveProjectRelative(projectDir,
			envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))),
		SpecialistReportFile: resolveProjectRelative(projectDir,
			envOr("SPECIALIST_REPORT_FILE", filepath.Join(tekhtonDir, "SPECIALIST_REPORT.md"))),

		ReviewSkipThreshold: envInt("REVIEW_SKIP_THRESHOLD", 0),
	}

	// Reviewer turn limit — prefer the in-flight ADJUSTED_REVIEWER_TURNS
	// override (the legacy bash global) when set, otherwise the base.
	if cfg.AdjustedReviewerTurn <= 0 {
		cfg.AdjustedReviewerTurn = cfg.ReviewerMaxTurns
	}
	if cfg.EffectiveCoderTurns <= 0 {
		cfg.EffectiveCoderTurns = cfg.CoderMaxTurns
	}
	if cfg.EffectiveJrTurns <= 0 {
		cfg.EffectiveJrTurns = cfg.JrCoderMaxTurns
	}

	cfg.diffStatTotal = gitDiffStatTotal
	cfg.Provider = stageProvider
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
