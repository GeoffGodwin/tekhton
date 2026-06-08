package tester

import (
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// config holds the resolved tester-stage configuration for a single
// RunStage invocation. Field names mirror the bash env vars (lower-case
// Go style); each value is resolved once at stage entry so the stage
// body works against a stable snapshot. Matches the security-stage
// pattern in internal/stages/security/config.go.
type config struct {
	ProjectDir  string
	TekhtonHome string
	TekhtonDir  string
	PromptsDir  string
	Task        string
	Milestone   string

	StartAt    string
	TesterMode string

	TesterReportFile string
	CoderSummaryFile string
	LogFile          string

	TesterMaxTurns int
	TesterModel    string
	AgentTools     string
	TestCmd        string

	TesterFixEnabled  bool
	TesterFixMaxDepth int
	TesterFixMaxTurns int
	TesterFixOutLim   int

	ContinuationEnabled bool
	ContinuationMaxAtt  int
	ContinuationBudget  int

	HumanMode     bool
	HumanNotesTag string
	MilestoneMode bool

	ResumeFlag string
}

// loadConfig resolves the per-stage configuration from env + the stage
// request. Mirrors the env-read pattern in stages/tester.sh:39-178
// byte-for-byte. Each ${VAR:-DEFAULT} on the bash side becomes
// envOr/envInt/envBool here.
func loadConfig(req *proto.StageRequestV1) config {
	projectDir := resolveProjectDir(req)
	tekhtonHome := envOrFromReq(req, "TEKHTON_HOME", "")
	tekhtonDir := envOrFromReq(req, "TEKHTON_DIR", ".tekhton")

	cfg := config{
		ProjectDir:  projectDir,
		TekhtonHome: tekhtonHome,
		TekhtonDir:  tekhtonDir,
		PromptsDir:  resolvePromptsDir(req),
		Task:        envOrFromReq(req, "TASK", req.Task),
		Milestone:   envOrFromReq(req, "MILESTONE", req.Milestone),

		StartAt:    envOrFromReq(req, "START_AT", "coder"),
		TesterMode: envOrFromReq(req, "TESTER_MODE", "verify_passing"),

		TesterReportFile: resolveProjectRelative(projectDir,
			envOrFromReq(req, "TESTER_REPORT_FILE", filepath.Join(tekhtonDir, "TESTER_REPORT.md"))),
		CoderSummaryFile: resolveProjectRelative(projectDir,
			envOrFromReq(req, "CODER_SUMMARY_FILE", filepath.Join(tekhtonDir, "CODER_SUMMARY.md"))),
		LogFile: resolveProjectRelative(projectDir, envOrFromReq(req, "LOG_FILE", "")),

		TesterMaxTurns: resolveTesterMaxTurns(),
		TesterModel:    envOr("CLAUDE_TESTER_MODEL", "claude-sonnet-4-6"),
		AgentTools:     envOr("AGENT_TOOLS_TESTER", ""),
		TestCmd:        envOr("TEST_CMD", ""),

		TesterFixEnabled:  envBool("TESTER_FIX_ENABLED", false),
		TesterFixMaxDepth: envIntAllowZero("TESTER_FIX_MAX_DEPTH", 1),
		TesterFixMaxTurns: envInt("TESTER_FIX_MAX_TURNS", 26),
		TesterFixOutLim:   envInt("TESTER_FIX_OUTPUT_LIMIT", 4000),

		ContinuationEnabled: envBool("CONTINUATION_ENABLED", true),
		ContinuationMaxAtt:  envInt("MAX_CONTINUATION_ATTEMPTS", 3),
		ContinuationBudget:  envInt("CONTINUATION_TURN_BUDGET", 50),

		HumanMode:     envBool("HUMAN_MODE", false),
		HumanNotesTag: os.Getenv("HUMAN_NOTES_TAG"),
		MilestoneMode: envBool("MILESTONE_MODE", false),
	}

	cfg.ResumeFlag = buildResumeFlag("test", cfg)
	return cfg
}

// resolveTesterMaxTurns picks the first non-empty turn budget in the
// bash priority order: EFFECTIVE_TESTER_MAX_TURNS > ADJUSTED_TESTER_TURNS
// > TESTER_MAX_TURNS > 50.
func resolveTesterMaxTurns() int {
	for _, key := range []string{"EFFECTIVE_TESTER_MAX_TURNS", "ADJUSTED_TESTER_TURNS", "TESTER_MAX_TURNS"} {
		if n := envInt(key, 0); n > 0 {
			return n
		}
	}
	return 50
}

// buildResumeFlag mirrors lib/state.sh::_build_resume_flag. start_at is
// "test" for the tester stage.
func buildResumeFlag(startAt string, cfg config) string {
	flag := ""
	switch {
	case cfg.HumanMode:
		flag = "--human"
		if cfg.HumanNotesTag != "" {
			flag = flag + " " + cfg.HumanNotesTag
		}
	case cfg.MilestoneMode:
		flag = "--milestone"
	}
	if flag == "" {
		return "--start-at " + startAt
	}
	return flag + " --start-at " + startAt
}

// resolveProjectDir reads PROJECT_DIR from the env-override map first,
// then process env, then falls back to cwd.
func resolveProjectDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "PROJECT_DIR", ""); v != "" {
		return v
	}
	wd, _ := os.Getwd()
	return wd
}

func resolvePromptsDir(req *proto.StageRequestV1) string {
	if v := envOrFromReq(req, "PROMPTS_DIR", ""); v != "" {
		return v
	}
	if v := envOrFromReq(req, "TEKHTON_HOME", ""); v != "" {
		return filepath.Join(v, "prompts")
	}
	return "prompts"
}

// resolveProjectRelative joins relative paths under projectDir. An empty
// path stays empty.
func resolveProjectRelative(projectDir, path string) string {
	if path == "" {
		return ""
	}
	if filepath.IsAbs(path) {
		return path
	}
	return filepath.Join(projectDir, path)
}
