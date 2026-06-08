package scout

import (
	"context"
	"fmt"
	"os"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Config holds the resolved knobs for a single Run invocation. The m39.4
// orchestrator resolves env → Config once at coder-stage entry; tests
// pass Config{} to exercise the defaulting path.
type Config struct {
	// Model mirrors CLAUDE_SCOUT_MODEL. Default "claude-sonnet-4-6".
	Model string

	// MaxTurns mirrors SCOUT_MAX_TURNS. Default 20.
	MaxTurns int

	// AgentTools mirrors AGENT_TOOLS_SCOUT (or "Read Glob Grep Write"
	// when the repo map is available and SCOUT_REPO_MAP_TOOLS_ONLY=true).
	AgentTools string

	// ReportFile mirrors SCOUT_REPORT_FILE.
	ReportFile string

	// LogFile mirrors LOG_FILE — best-effort passthrough to the agent
	// supervisor.
	LogFile string

	// PostSplit is true for the post-milestone-split re-scout. Drives
	// the agent label.
	PostSplit bool

	// Cached mirrors SCOUT_CACHED=true: the report is read from disk
	// rather than re-spawned. Bypasses the agent invocation entirely.
	Cached bool
}

// Result is the orchestrator's return envelope. The m39.4 orchestrator
// branches on (Estimate, WasNullRun) — null-run scout outputs are
// non-fatal and the orchestrator falls back to filesystem exploration.
type Result struct {
	// Estimate is the parsed complexity estimate from SCOUT_REPORT.md.
	// nil when the report is missing or unparseable.
	Estimate *Estimate

	// ReportPath is the absolute path to the scout's emitted report.
	// Empty when no report was produced.
	ReportPath string

	// WasNullRun is true when the agent exited without doing meaningful
	// work (mirrors was_null_run in lib/agent_helpers.sh).
	WasNullRun bool
}

// Deps is the dependency-injection seam. Every field is best-effort
// (nil-safe) so the m39.4 orchestrator can construct a fully-wired Deps
// and tests can substitute recording stubs.
type Deps struct {
	// RenderPrompt renders the "scout" template body. Production wires
	// internal/prompt.Render; tests substitute a recording stub.
	RenderPrompt func(name string, vars map[string]string) (string, error)

	// RunAgent dispatches the scout agent. Production wires the
	// in-process supervisor; tests substitute a recording fake.
	RunAgent func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)

	// ParseEstimate reads ReportFile and parses the Complexity Estimate
	// section into an Estimate. Returns nil on missing-file /
	// parse-failure (matches bash parse_scout_complexity's return code
	// 1 semantics).
	ParseEstimate func(reportPath string) (*Estimate, error)

	// WasNullRun reports whether the most recent agent invocation was a
	// null run. Production wires lib/agent_helpers.sh::was_null_run; nil
	// is treated as "not a null run" (assume agent did work).
	WasNullRun func() bool

	// Log / Warn / Success surface progress to the operator. Nil values
	// degrade to no-ops.
	Log     func(format string, args ...any)
	Warn    func(format string, args ...any)
	Success func(format string, args ...any)
}

// Run invokes the scout sub-agent and returns the parsed Estimate.
// Mirrors the scout block at stages/coder.sh:189-358 with one
// orchestration difference — the milestone-split branch and the
// BUG_SCOUT_CONTEXT assembly are NOT part of Run's scope (the m39.4
// orchestrator owns them).
//
// Cached path: when cfg.Cached=true and the report exists on disk, the
// agent invocation is skipped entirely. Mirrors stages/coder.sh:176-187.
//
// Returns a populated Result on every path — Estimate may be nil if the
// report was missing or unparseable, and WasNullRun may be true if the
// agent died early. The caller decides whether either is fatal.
func Run(ctx context.Context, cfg *Config, deps *Deps) (*Result, error) {
	if cfg == nil {
		cfg = &Config{}
	}
	if deps == nil {
		deps = &Deps{}
	}
	applyDefaults(cfg)

	result := &Result{ReportPath: cfg.ReportFile}

	if cfg.Cached {
		return runCached(cfg, deps, result)
	}

	label := "Scout"
	if cfg.PostSplit {
		label = "Scout (post-split)"
	}

	if deps.RunAgent != nil {
		if err := invokeScoutAgent(ctx, cfg, deps, label); err != nil {
			warnf(deps, "Scout agent invocation failed: %v", err)
		}
	}

	// Null-run path: the agent died before producing a report.
	if deps.WasNullRun != nil && deps.WasNullRun() {
		result.WasNullRun = true
		warnf(deps, "Scout was a null run — coder will explore independently.")
		return result, nil
	}

	if !fileExists(cfg.ReportFile) {
		warnf(deps, "Scout agent did not produce %s — coder will explore independently.", cfg.ReportFile)
		return result, nil
	}

	successf(deps, "Scout agent finished. Relevant files located.")

	estimate, err := parseEstimate(cfg.ReportFile, deps)
	if err != nil {
		warnf(deps, "Failed to parse scout estimate: %v", err)
	}
	result.Estimate = estimate
	return result, nil
}

// runCached implements the SCOUT_CACHED=true branch. The report is
// already on disk; parse the estimate and return without invoking the
// agent. Mirrors stages/coder.sh:176-187.
func runCached(cfg *Config, deps *Deps, result *Result) (*Result, error) {
	if !fileExists(cfg.ReportFile) {
		warnf(deps, "SCOUT_CACHED=true but %s missing — falling back to live invocation.", cfg.ReportFile)
		return result, nil
	}
	logf(deps, "Scout using cached results — dry-run cache available.")

	estimate, err := parseEstimate(cfg.ReportFile, deps)
	if err != nil {
		warnf(deps, "Failed to parse cached scout estimate: %v", err)
	}
	result.Estimate = estimate
	return result, nil
}

// applyDefaults populates zero-valued Config fields with the bash
// defaults. The m39.4 orchestrator threads env → Config; tests rely on
// this to pass Config{} for the cached path.
func applyDefaults(cfg *Config) {
	if cfg.Model == "" {
		cfg.Model = "claude-sonnet-4-6"
	}
	if cfg.MaxTurns <= 0 {
		cfg.MaxTurns = 20
	}
	if cfg.ReportFile == "" {
		cfg.ReportFile = ".tekhton/SCOUT_REPORT.md"
	}
}

// invokeScoutAgent renders the scout prompt and dispatches the agent.
// The body is intentionally minimal: the m39.4 orchestrator pre-populates
// every template variable in the prompt-vars map before calling Run, so
// the scout sub-package doesn't reach into shell globals.
func invokeScoutAgent(ctx context.Context, cfg *Config, deps *Deps, label string) error {
	prompt := ""
	if deps.RenderPrompt != nil {
		p, err := deps.RenderPrompt("scout", nil)
		if err != nil {
			return fmt.Errorf("render scout prompt: %w", err)
		}
		prompt = p
	}

	req := &proto.AgentRequestV1{
		Proto:        proto.AgentRequestProtoV1,
		Label:        label,
		Model:        cfg.Model,
		MaxTurns:     cfg.MaxTurns,
		PromptFile:   prompt,
		AllowedTools: cfg.AgentTools,
	}
	_, err := deps.RunAgent(ctx, req)
	return err
}

// parseEstimate delegates to Deps.ParseEstimate when wired; otherwise
// returns nil so the m39.4 orchestrator can decide whether to fall back
// to the bash parser (legacy run) or skip estimate-driven turn limits.
func parseEstimate(reportPath string, deps *Deps) (*Estimate, error) {
	if deps.ParseEstimate == nil {
		return nil, nil
	}
	return deps.ParseEstimate(reportPath)
}

// fileExists is the same nil-safe check pattern used by stages/coder.sh
// `[ -f "$file" ]`. Empty path is treated as "no file."
func fileExists(path string) bool {
	if path == "" {
		return false
	}
	st, err := os.Stat(filepath.Clean(path))
	return err == nil && !st.IsDir()
}

// logf / warnf / successf are nil-safe wrappers around the Deps log
// helpers.

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

func successf(deps *Deps, format string, args ...any) {
	if deps == nil || deps.Success == nil {
		return
	}
	deps.Success(format, args...)
}
