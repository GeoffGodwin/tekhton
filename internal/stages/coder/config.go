package coder

import (
	"os"
	"strconv"
	"strings"

	"github.com/geoffgodwin/tekhton/internal/coder/buildfix"
	"github.com/geoffgodwin/tekhton/internal/coder/prerun"
	"github.com/geoffgodwin/tekhton/internal/coder/scout"
	"github.com/geoffgodwin/tekhton/internal/provider"
)

// Config holds the orchestrator's resolved env once at stage entry. The bash
// version reads env vars repeatedly mid-flow; the Go port resolves the full
// snapshot up front so each method works against a stable shape and tests can
// inject Config explicitly.
//
// Defaults match stages/coder.sh byte-for-byte. Tag-specific multipliers
// (BUG/FEAT/POLISH) and the TDD multiplier are load-bearing — the bash
// version's reviewer-visible turn-budget math depends on these exact values.
type Config struct {
	// CoderMaxTurns mirrors CODER_MAX_TURNS. Default 80.
	CoderMaxTurns int

	// AdjustedCoderTurns mirrors ADJUSTED_CODER_TURNS — the post-scout
	// recommendation that overrides CoderMaxTurns when set.
	AdjustedCoderTurns int

	// EffectiveCoderMaxTurns mirrors EFFECTIVE_CODER_MAX_TURNS — the final
	// resolved budget used by the senior coder agent and the continuation
	// loop. Falls back to AdjustedCoderTurns, then CoderMaxTurns.
	EffectiveCoderMaxTurns int

	// CoderModel mirrors CLAUDE_CODER_MODEL. Default "claude-sonnet-4-6".
	CoderModel string

	// AgentToolsCoder mirrors AGENT_TOOLS_CODER. Passed verbatim to the
	// senior coder agent invocation.
	AgentToolsCoder string

	// LogFile mirrors LOG_FILE. Best-effort logging target.
	LogFile string

	// CoderSummaryFile mirrors CODER_SUMMARY_FILE. Default
	// ".tekhton/CODER_SUMMARY.md".
	CoderSummaryFile string

	// ProjectDir mirrors PROJECT_DIR. The orchestrator never assumes cwd —
	// every file access goes through this base.
	ProjectDir string

	// TekhtonHome mirrors TEKHTON_HOME. Used to locate prompt templates.
	TekhtonHome string

	// MilestoneMode mirrors MILESTONE_MODE.
	MilestoneMode bool

	// CurrentMilestone mirrors _CURRENT_MILESTONE.
	CurrentMilestone string

	// NotesFilter mirrors NOTES_FILTER ("BUG" | "FEAT" | "POLISH" | "").
	NotesFilter string

	// NoteTemplateName is the tag-specific prompt template ("coder_note_bug",
	// "coder_note_feat", "coder_note_polish", or "" for the default).
	NoteTemplateName string

	// ContinuationEnabled mirrors CONTINUATION_ENABLED. Default true.
	ContinuationEnabled bool

	// MaxContinuationAttempts mirrors MAX_CONTINUATION_ATTEMPTS. Default 3.
	MaxContinuationAttempts int

	// MaxSplitDepth mirrors MILESTONE_MAX_SPLIT_DEPTH. Default 3.
	MaxSplitDepth int

	// BugTurnMultiplier mirrors BUG_TURN_MULTIPLIER. Default 1.0.
	BugTurnMultiplier float64

	// FeatTurnMultiplier mirrors FEAT_TURN_MULTIPLIER. Default 1.0.
	FeatTurnMultiplier float64

	// PolishTurnMultiplier mirrors POLISH_TURN_MULTIPLIER. Default 0.6.
	PolishTurnMultiplier float64

	// TDDTurnMultiplier mirrors CODER_TDD_TURN_MULTIPLIER. Default 1.2.
	// Applied only when PipelineOrder == "test_first" AND TesterPreflight
	// non-empty.
	TDDTurnMultiplier float64

	// PipelineOrder mirrors PIPELINE_ORDER ("standard" | "test_first").
	PipelineOrder string

	// Defaults the bash version reads from the env, surfaced here for
	// sub-package construction.
	PrerunConfig   *prerun.Config
	ScoutConfig    *scout.Config
	BuildFixConfig *buildfix.Config

	// Provider is the agent backend injected by the runner.
	Provider provider.Provider
}

// DefaultConfig returns the bash-default values byte-identically. Tests assert
// struct equality against this — any drift fails red.
func DefaultConfig() Config {
	return Config{
		CoderMaxTurns:           80,
		CoderModel:              "claude-sonnet-4-6",
		CoderSummaryFile:        ".tekhton/CODER_SUMMARY.md",
		MilestoneMode:           false,
		ContinuationEnabled:     true,
		MaxContinuationAttempts: 3,
		MaxSplitDepth:           3,
		BugTurnMultiplier:       1.0,
		FeatTurnMultiplier:      1.0,
		PolishTurnMultiplier:    0.6,
		TDDTurnMultiplier:       1.2,
		PipelineOrder:           "standard",
	}
}

// loadConfigFromEnv resolves the orchestrator's Config from process env. The
// orchestrator calls this once at stage entry; tests pass a hand-built Config
// to bypass the env lookup.
func loadConfigFromEnv() Config {
	cfg := DefaultConfig()
	cfg.CoderMaxTurns = envOrInt("CODER_MAX_TURNS", 80)
	cfg.AdjustedCoderTurns = envOrInt("ADJUSTED_CODER_TURNS", 0)
	cfg.EffectiveCoderMaxTurns = envOrInt("EFFECTIVE_CODER_MAX_TURNS", 0)
	cfg.CoderModel = envOr("CLAUDE_CODER_MODEL", "claude-sonnet-4-6")
	cfg.AgentToolsCoder = os.Getenv("AGENT_TOOLS_CODER")
	cfg.LogFile = os.Getenv("LOG_FILE")
	cfg.CoderSummaryFile = envOr("CODER_SUMMARY_FILE", ".tekhton/CODER_SUMMARY.md")
	cfg.ProjectDir = envOr("PROJECT_DIR", ".")
	cfg.TekhtonHome = os.Getenv("TEKHTON_HOME")
	cfg.MilestoneMode = envBool("MILESTONE_MODE", false)
	cfg.CurrentMilestone = os.Getenv("_CURRENT_MILESTONE")
	cfg.NotesFilter = os.Getenv("NOTES_FILTER")
	cfg.ContinuationEnabled = envBool("CONTINUATION_ENABLED", true)
	cfg.MaxContinuationAttempts = envOrInt("MAX_CONTINUATION_ATTEMPTS", 3)
	cfg.MaxSplitDepth = envOrInt("MILESTONE_MAX_SPLIT_DEPTH", 3)
	cfg.BugTurnMultiplier = envOrFloat("BUG_TURN_MULTIPLIER", 1.0)
	cfg.FeatTurnMultiplier = envOrFloat("FEAT_TURN_MULTIPLIER", 1.0)
	cfg.PolishTurnMultiplier = envOrFloat("POLISH_TURN_MULTIPLIER", 0.6)
	cfg.TDDTurnMultiplier = envOrFloat("CODER_TDD_TURN_MULTIPLIER", 1.2)
	cfg.PipelineOrder = envOr("PIPELINE_ORDER", "standard")

	// Compose the sub-package configs from the env-snapshot so the
	// orchestrator can hand them to prerun.Run / scout.Run / buildfix.Run
	// without each sub-package re-reading the env.
	cfg.PrerunConfig = &prerun.Config{
		Enabled:    envBool("PRE_RUN_CLEAN_ENABLED", true),
		TestCmd:    os.Getenv("TEST_CMD"),
		MaxTurns:   envOrInt("PRE_RUN_FIX_MAX_TURNS", prerun.DefaultMaxTurns),
		Model:      envOr("PREFLIGHT_FIX_MODEL", envOr("CLAUDE_JR_CODER_MODEL", "")),
		AgentTools: os.Getenv("AGENT_TOOLS_BUILD_FIX"),
		LogFile:    cfg.LogFile,
		ProjectDir: cfg.ProjectDir,
		Milestone:  cfg.CurrentMilestone,
	}
	cfg.ScoutConfig = &scout.Config{
		Model:      envOr("CLAUDE_SCOUT_MODEL", "claude-sonnet-4-6"),
		MaxTurns:   envOrInt("SCOUT_MAX_TURNS", 20),
		AgentTools: envOr("AGENT_TOOLS_SCOUT", "Read Glob Grep Write"),
		ReportFile: envOr("SCOUT_REPORT_FILE", ".tekhton/SCOUT_REPORT.md"),
		LogFile:    cfg.LogFile,
		Cached:     envBool("SCOUT_CACHED", false),
	}
	bf := buildfix.DefaultConfig()
	bf.Enabled = envBool("BUILD_FIX_ENABLED", true)
	bf.MaxAttempts = envOrInt("BUILD_FIX_MAX_ATTEMPTS", 3)
	bf.BaseTurnDivisor = envOrInt("BUILD_FIX_BASE_TURN_DIVISOR", 3)
	bf.MaxTurnMultiplier = envOrInt("BUILD_FIX_MAX_TURN_MULTIPLIER", 100)
	bf.RequireProgress = envBool("BUILD_FIX_REQUIRE_PROGRESS", true)
	bf.TotalTurnCap = envOrInt("BUILD_FIX_TOTAL_TURN_CAP", 120)
	bf.ClassificationRequired = envBool("BUILD_FIX_CLASSIFICATION_REQUIRED", false)
	bf.EffectiveCoderMaxTurns = cfg.EffectiveCoderMaxTurns
	if bf.EffectiveCoderMaxTurns <= 0 {
		bf.EffectiveCoderMaxTurns = cfg.CoderMaxTurns
	}
	cfg.BuildFixConfig = &bf
	cfg.Provider = stageProvider
	return cfg
}

// envOr returns os.Getenv(key) or fallback when empty.
func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// envOrInt returns os.Getenv(key) parsed as int, or fallback on empty/invalid.
func envOrInt(key string, fallback int) int {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return fallback
	}
	return n
}

// envOrFloat returns os.Getenv(key) parsed as float64, or fallback on
// empty/invalid.
func envOrFloat(key string, fallback float64) float64 {
	v := os.Getenv(key)
	if v == "" {
		return fallback
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return fallback
	}
	return f
}

// envBool parses "true"/"false" (case-insensitive). Anything else returns
// fallback. Matches the bash `[[ "$v" = "true" ]]` semantics.
func envBool(key string, fallback bool) bool {
	v := strings.ToLower(os.Getenv(key))
	if v == "" {
		return fallback
	}
	switch v {
	case "true", "1", "yes":
		return true
	case "false", "0", "no":
		return false
	}
	return fallback
}

// effectiveCoderTurns returns the budget the senior coder agent runs with.
// Mirrors stages/coder.sh:718 cascade:
// EFFECTIVE_CODER_MAX_TURNS → ADJUSTED_CODER_TURNS → CODER_MAX_TURNS → 80.
func (c Config) effectiveCoderTurns() int {
	if c.EffectiveCoderMaxTurns > 0 {
		return c.EffectiveCoderMaxTurns
	}
	if c.AdjustedCoderTurns > 0 {
		return c.AdjustedCoderTurns
	}
	if c.CoderMaxTurns > 0 {
		return c.CoderMaxTurns
	}
	return 80
}
