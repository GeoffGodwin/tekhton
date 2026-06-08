package coder

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Env captures the orchestrator's environment snapshot for context-block
// assembly. The bash version reads these from globals; the Go port resolves
// them once at stage entry so context_blocks.Build is testable without an
// environment.
type Env struct {
	ProjectDir     string
	TekhtonHome    string
	StartAt        string
	MilestoneMode  bool
	PipelineOrder  string
	FixNonblockers bool
}

// ContextBlocks holds the 14 context-block strings the coder prompt template
// substitutes. Empty fields short-circuit the prompt-template IF blocks,
// matching the bash _add_context_component semantics.
type ContextBlocks struct {
	Architecture        string
	RepoMap             string
	Glossary            string
	Milestone           string
	HumanNotes          string
	PriorReviewer       string
	PriorProgress       string
	PriorTester         string
	PreflightTests      string
	NonBlockingNotes    string
	ScoutReport         string
	AffectedTestFiles   string
	TestBaselineSummary string
	Clarifications      string
	TDDPreflight        string
}

// AsTemplateVars returns the ContextBlocks as a flat map suitable for
// internal/prompt.Render. Keys match the {{VAR}} placeholders in
// prompts/coder.prompt.md.
func (b *ContextBlocks) AsTemplateVars() map[string]string {
	if b == nil {
		return map[string]string{}
	}
	return map[string]string{
		"ARCHITECTURE_BLOCK":         b.Architecture,
		"REPO_MAP_CONTENT":           b.RepoMap,
		"GLOSSARY_BLOCK":             b.Glossary,
		"MILESTONE_BLOCK":            b.Milestone,
		"HUMAN_NOTES_BLOCK":          b.HumanNotes,
		"PRIOR_REVIEWER_CONTEXT":     b.PriorReviewer,
		"PRIOR_PROGRESS_CONTEXT":     b.PriorProgress,
		"PRIOR_TESTER_CONTEXT":       b.PriorTester,
		"PREFLIGHT_TEST_CONTEXT":     b.PreflightTests,
		"NON_BLOCKING_CONTEXT":       b.NonBlockingNotes,
		"BUG_SCOUT_CONTEXT":          b.ScoutReport,
		"AFFECTED_TEST_FILES":        b.AffectedTestFiles,
		"TEST_BASELINE_SUMMARY":      b.TestBaselineSummary,
		"CLARIFICATIONS_CONTENT":     b.Clarifications,
		"TESTER_PREFLIGHT_CONTENT":   b.TDDPreflight,
	}
}

// Build assembles the 14 context blocks. Each builder method is a method on
// *ContextBlocks so it can be unit-tested in isolation. The bash version's
// _safe_read_file wrapper (which catches missing files and emits a sentinel)
// ports as safeReadFile here, returning "" on error.
//
// The orchestrator calls Build once after the scout sub-agent runs and
// before invoking the senior coder agent.
func Build(_ context.Context, env *Env, deps *Deps) *ContextBlocks {
	if env == nil {
		env = &Env{ProjectDir: "."}
	}
	b := &ContextBlocks{}
	b.buildArchitecture(env, deps)
	b.buildRepoMap()
	b.buildGlossary(env, deps)
	b.buildMilestone(env)
	b.buildHumanNotes(env)
	b.buildPriorReviewer(env, deps)
	b.buildPriorProgress(env, deps)
	b.buildPriorTester(env, deps)
	b.buildPreflightTests(env, deps)
	b.buildNonBlockingNotes(env)
	b.buildScoutReport()
	b.buildAffectedTestFiles()
	b.buildTestBaseline()
	b.buildClarifications(env, deps)
	b.buildTDDPreflight(env, deps)
	return b
}

// buildArchitecture reads ARCHITECTURE.md (or ARCHITECTURE_FILE env override)
// and wraps it in the BEGIN/END FILE CONTENT delimiters for prompt injection.
func (b *ContextBlocks) buildArchitecture(env *Env, deps *Deps) {
	path := envOr("ARCHITECTURE_FILE", "ARCHITECTURE.md")
	content := readUnder(env.ProjectDir, path, "ARCHITECTURE", deps)
	if content == "" {
		return
	}
	b.Architecture = "\n## Architecture Map (read FIRST — saves you 10+ turns of exploration)\n" + content
}

// buildRepoMap reads the REPO_MAP_CONTENT env var (populated by the
// indexer subsystem prior to coder stage entry).
func (b *ContextBlocks) buildRepoMap() {
	b.RepoMap = os.Getenv("REPO_MAP_CONTENT")
}

// buildGlossary reads GLOSSARY_FILE if set.
func (b *ContextBlocks) buildGlossary(env *Env, deps *Deps) {
	path := os.Getenv("GLOSSARY_FILE")
	if path == "" {
		return
	}
	content := readUnder(env.ProjectDir, path, "GLOSSARY", deps)
	if content == "" {
		return
	}
	b.Glossary = "\n## Glossary (use these terms precisely — do not invent synonyms)\n" + content
}

// buildMilestone reads MILESTONE_BLOCK from env (populated by
// set_focused_milestone_block) and falls back to the static block when
// missing.
func (b *ContextBlocks) buildMilestone(env *Env) {
	if v := os.Getenv("MILESTONE_BLOCK"); v != "" {
		b.Milestone = v
		return
	}
	if !env.MilestoneMode {
		return
	}
	b.Milestone = "## Milestone Mode\n" +
		"This is a milestone-sized task. Before writing any code:\n" +
		"1. Read the relevant Milestone section in CLAUDE.md in full\n" +
		"2. Check the 'Seeds forward' annotations on this milestone\n"
}

// buildHumanNotes reads the HUMAN_NOTES_BLOCK env var (populated upstream).
func (b *ContextBlocks) buildHumanNotes(_ *Env) {
	b.HumanNotes = os.Getenv("HUMAN_NOTES_BLOCK")
}

// buildPriorReviewer wraps an existing REVIEWER_REPORT.md (when START_AT is
// "coder") in the prior-reviewer block.
func (b *ContextBlocks) buildPriorReviewer(env *Env, deps *Deps) {
	if env.StartAt != "coder" {
		return
	}
	path := envOr("REVIEWER_REPORT_FILE", ".tekhton/REVIEWER_REPORT.md")
	content := readUnder(env.ProjectDir, path, "REVIEWER_REPORT", deps)
	if content == "" {
		return
	}
	b.PriorReviewer = "\n## Prior Reviewer Report (unresolved blockers from last run)\n" +
		"The previous pipeline run ended with these unresolved items.\n" +
		"Fix the Complex and Simple Blockers listed below — do not re-implement anything already done.\n" +
		"Non-Blocking Notes are optional improvements if turns allow.\n\n" +
		content
}

// buildPriorProgress reads PIPELINE_STATE for turn-limit recovery context.
func (b *ContextBlocks) buildPriorProgress(_ *Env, _ *Deps) {
	gitDiff := os.Getenv("PRIOR_GIT_DIFF_STAT")
	exitReason := os.Getenv("PRIOR_EXIT_REASON")
	if exitReason != "turn_limit" || gitDiff == "" {
		return
	}
	b.PriorProgress = fmt.Sprintf("\n## Previous Run Partial Progress\n"+
		"The last coder run hit the turn limit mid-implementation. These files were already modified:\n%s\n\n"+
		"Check CODER_SUMMARY.md for what was completed. Do NOT redo work already done.\n", gitDiff)
}

// buildPriorTester wraps TESTER_REPORT.md when it contains bug markers.
func (b *ContextBlocks) buildPriorTester(env *Env, deps *Deps) {
	path := envOr("TESTER_REPORT_FILE", ".tekhton/TESTER_REPORT.md")
	content := readUnder(env.ProjectDir, path, "TESTER_REPORT", deps)
	if content == "" {
		return
	}
	if !strings.Contains(content, "Bugs Found") && !strings.Contains(content, "BUG-") {
		return
	}
	b.PriorTester = "\n## Bugs Found by Tester (must fix)\n" +
		"The tester identified these bugs in the last run. Fix all BUG-* items before\n" +
		"doing anything else.\n\n" + content
}

// buildPreflightTests wraps PREFLIGHT_ERRORS.md when present.
func (b *ContextBlocks) buildPreflightTests(env *Env, deps *Deps) {
	if env.StartAt != "coder" {
		return
	}
	path := envOr("PREFLIGHT_ERRORS_FILE", ".tekhton/PREFLIGHT_ERRORS.md")
	content := readUnder(env.ProjectDir, path, "PREFLIGHT_ERRORS", deps)
	if content == "" {
		return
	}
	b.PreflightTests = "\n## Pre-Finalization Test Failures (must fix)\n" + content
}

// buildNonBlockingNotes injects accumulated non-blocking notes when
// FIX_NONBLOCKERS_MODE is set.
func (b *ContextBlocks) buildNonBlockingNotes(env *Env) {
	if !env.FixNonblockers {
		return
	}
	b.NonBlockingNotes = os.Getenv("NON_BLOCKING_NOTES")
}

// buildScoutReport reads BUG_SCOUT_CONTEXT from env (populated upstream).
func (b *ContextBlocks) buildScoutReport() {
	b.ScoutReport = os.Getenv("BUG_SCOUT_CONTEXT")
}

// buildAffectedTestFiles reads AFFECTED_TEST_FILES from env (populated by
// scout).
func (b *ContextBlocks) buildAffectedTestFiles() {
	b.AffectedTestFiles = os.Getenv("AFFECTED_TEST_FILES")
}

// buildTestBaseline reads TEST_BASELINE_SUMMARY from env.
func (b *ContextBlocks) buildTestBaseline() {
	b.TestBaselineSummary = os.Getenv("TEST_BASELINE_SUMMARY")
}

// buildClarifications reads CLARIFICATIONS_CONTENT from env, or falls back
// to reading CLARIFICATIONS.md directly.
func (b *ContextBlocks) buildClarifications(env *Env, deps *Deps) {
	if v := os.Getenv("CLARIFICATIONS_CONTENT"); v != "" {
		b.Clarifications = v
		return
	}
	path := envOr("CLARIFICATIONS_FILE", ".tekhton/CLARIFICATIONS.md")
	content := readUnder(env.ProjectDir, path, "CLARIFICATIONS", deps)
	if content == "" {
		return
	}
	b.Clarifications = content
}

// buildTDDPreflight reads TDD_PREFLIGHT_FILE when PIPELINE_ORDER=test_first.
func (b *ContextBlocks) buildTDDPreflight(env *Env, deps *Deps) {
	if env.PipelineOrder != "test_first" {
		return
	}
	path := os.Getenv("TDD_PREFLIGHT_FILE")
	if path == "" {
		return
	}
	content := readUnder(env.ProjectDir, path, "TESTER_PREFLIGHT", deps)
	b.TDDPreflight = content
}

// readUnder resolves path against projectDir (if relative) and reads via
// Deps.SafeReadFile when wired; otherwise falls back to a direct os.ReadFile
// under a 1MB cap.
func readUnder(projectDir, path, label string, deps *Deps) string {
	if !filepath.IsAbs(path) {
		path = filepath.Join(projectDir, path)
	}
	if deps != nil && deps.SafeReadFile != nil {
		s, _ := deps.SafeReadFile(path, label)
		return s
	}
	return safeReadFileFallback(path)
}

// safeReadFileFallback is the in-package _safe_read_file. 1MB cap matches
// lib/prompts_io.sh.
func safeReadFileFallback(path string) string {
	st, err := os.Stat(path)
	if err != nil {
		return ""
	}
	if st.Size() > 1024*1024 {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(b)
}
