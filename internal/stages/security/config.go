package security

import (
	"os"
	"path/filepath"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	sec "github.com/geoffgodwin/tekhton/internal/security"
)

// config holds the resolved security-stage configuration for a single
// RunStage invocation. Field names mirror the bash env vars (lower-case
// Go style); each value is resolved once at stage entry so the stage
// body works against a stable snapshot.
type config struct {
	ProjectDir  string
	TekhtonHome string
	PromptsDir  string
	Task        string

	AgentEnabled bool
	SkipFlag     bool

	CoderSummaryFile string
	ReportFile       string
	NotesFile        string

	MaxRework     int
	MaxTurns      int
	MinTurns      int
	MaxTurnsCap   int
	CoderMaxTurns int

	MilestoneMode          bool
	MilestoneSecurityTurns string // raw env value (may be empty)

	ScanModel     string
	CoderModel    string
	ReviewerTools string
	CoderTools    string

	BlockSeverity   sec.Severity
	UnfixablePolicy string

	now func() time.Time
}

// Now returns the current time via the config's clock seam — tests
// substitute a frozen clock by overriding cfg.now.
func (c config) Now() time.Time {
	if c.now != nil {
		return c.now()
	}
	return time.Now()
}

// loadConfig resolves the per-stage configuration from env + the stage
// request. Mirrors the env-read pattern in stages/security.sh:18-66
// verbatim. Each ${VAR:-DEFAULT} on the bash side becomes envOr/envInt
// here so the V4 env contract holds.
func loadConfig(req *proto.StageRequestV1) config {
	projectDir := resolveProjectDir(req)
	tekhtonHome := envOrFromReq(req, "TEKHTON_HOME", "")
	tekhtonDir := envOr("TEKHTON_DIR", ".tekhton")

	cfg := config{
		ProjectDir:  projectDir,
		TekhtonHome: tekhtonHome,
		PromptsDir:  resolvePromptsDir(req),
		Task:        envOrFromReq(req, "TASK", req.Task),

		AgentEnabled: envBool("SECURITY_AGENT_ENABLED", true),
		SkipFlag:     envBool("SKIP_SECURITY", false),

		CoderSummaryFile: resolveProjectRelative(projectDir,
			envOr("CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))),
		ReportFile: resolveProjectRelative(projectDir,
			envOr("SECURITY_REPORT_FILE", filepath.Join(tekhtonDir, "SECURITY_REPORT.md"))),
		NotesFile: resolveProjectRelative(projectDir,
			envOr("SECURITY_NOTES_FILE", "")),

		MaxRework:     envInt("SECURITY_MAX_REWORK_CYCLES", 2),
		MaxTurns:      envInt("SECURITY_MAX_TURNS", 15),
		MinTurns:      envInt("SECURITY_MIN_TURNS", 8),
		MaxTurnsCap:   envInt("SECURITY_MAX_TURNS_CAP", 30),
		CoderMaxTurns: envInt("CODER_MAX_TURNS", 80),

		MilestoneMode:          envBool("MILESTONE_MODE", false),
		MilestoneSecurityTurns: os.Getenv("MILESTONE_SECURITY_MAX_TURNS"),

		ScanModel: envOr("CLAUDE_SECURITY_MODEL",
			envOr("CLAUDE_STANDARD_MODEL", "claude-sonnet-4-6")),
		CoderModel:    envOr("CLAUDE_CODER_MODEL", "claude-sonnet-4-6"),
		ReviewerTools: envOr("AGENT_TOOLS_REVIEWER", ""),
		CoderTools:    envOr("AGENT_TOOLS_CODER", ""),

		BlockSeverity:   sec.Severity(envOr("SECURITY_BLOCK_SEVERITY", "HIGH")),
		UnfixablePolicy: envOr("SECURITY_UNFIXABLE_POLICY", "escalate"),
	}
	return cfg
}

// resolveProjectDir reads PROJECT_DIR from the env-override map first, then
// process env, then falls back to cwd.
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

// resolveProjectRelative joins relative paths under projectDir. An empty
// path stays empty (SECURITY_NOTES_FILE unset means "skip notes").
func resolveProjectRelative(projectDir, path string) string {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(projectDir, path)
}
