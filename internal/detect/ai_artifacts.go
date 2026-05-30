package detect

import (
	"context"
	"path/filepath"
	"regexp"
	"strings"
)

// AIArtifactsDetector ports lib/detect_ai_artifacts.sh::detect_ai_artifacts.
// Heuristic ordering is load-bearing: classify_ai_tool uses the first
// matching finding to disambiguate ties. The aiArtifactHeuristics slice
// below encodes the exact bash order; ai_artifacts_test.go::
// TestHeuristicOrder fails red if the order changes.
type AIArtifactsDetector struct{}

// Name returns the canonical detector name.
func (AIArtifactsDetector) Name() string { return "ai_artifacts" }

// Run executes the ordered AI-artifact heuristics.
func (AIArtifactsDetector) Run(_ context.Context, in *Input) (*Result, error) {
	dir := in.ProjectDir
	r := &Result{Detector: "ai_artifacts"}
	for _, h := range aiArtifactHeuristics {
		for _, a := range h.fn(dir) {
			r.Findings = append(r.Findings, map[string]string{
				"tool":       a.Tool,
				"path":       a.Path,
				"type":       a.Kind,
				"confidence": a.Confidence,
			})
		}
	}
	return r, nil
}

// aiArtifactHeuristics — order is load-bearing. TestHeuristicOrder
// asserts the exact sequence below; reordering changes
// classify_ai_tool's tie-break and breaks the parity gate.
//
// The bash flow (lib/detect_ai_artifacts.sh:60-109) runs:
//
//	known_dirs       — .cursor/, .github/copilot/, .cline/, …
//	known_files      — .cursorrules, .windsurfrules, .roomodes, .aiconfig
//	known_globs      — .aider*
//	claude_dir       — .claude/pipeline.conf, .claude/agents/, etc.
//	claude_md        — CLAUDE.md (with tekhton-managed marker check)
//	directive_mds    — AGENTS.md / CONVENTIONS.md / ARCHITECTURE.md
//
// `claude_md` runs after `claude_dir` because the bash dispatches
// `_detect_claude_dir_artifacts` first then `_detect_claude_md`.
// `directive_language` is the helper consulted by `directive_mds`;
// each markdown candidate is scanned for persona / rules / directive
// patterns and emitted with `type=rules, confidence=low` on match.
var aiArtifactHeuristics = []aiHeuristic{
	{name: "known_dirs", fn: detectKnownAIDirs},
	{name: "known_files", fn: detectKnownAIFiles},
	{name: "known_globs", fn: detectKnownAIGlobs},
	{name: "claude_dir", fn: detectClaudeDirArtifacts},
	{name: "claude_md", fn: detectClaudeMD},
	{name: "directive_markdowns", fn: detectDirectiveMarkdowns},
}

type aiHeuristic struct {
	name string
	fn   func(dir string) []AIArtifact
}

// knownAIDirs mirrors _KNOWN_AI_DIRS.
var knownAIDirs = []struct {
	dir, tool string
}{
	{".cursor", "Cursor"},
	{".github/copilot", "GitHub Copilot"},
	{".cline", "Cline"},
	{"cline_docs", "Cline"},
	{".continue", "Continue.dev"},
	{".windsurf", "Windsurf"},
	{".roo", "Roo Code"},
	{".ai", "Generic AI Config"},
}

// knownAIFiles mirrors _KNOWN_AI_FILES.
var knownAIFiles = []struct {
	file, tool string
}{
	{".cursorrules", "Cursor"},
	{".windsurfrules", "Windsurf"},
	{".roomodes", "Roo Code"},
	{".aiconfig", "Generic AI Config"},
}

// knownAIGlobs mirrors _KNOWN_AI_GLOBS.
var knownAIGlobs = []struct {
	pattern, tool string
}{
	{".aider*", "aider"},
}

func detectKnownAIDirs(dir string) []AIArtifact {
	var out []AIArtifact
	for _, e := range knownAIDirs {
		full := filepath.Join(dir, e.dir)
		if !dirExists(full) {
			continue
		}
		// .ai/ might be Adobe Illustrator files — require config files.
		if e.dir == ".ai" {
			if !dirHasConfigFiles(full) {
				continue
			}
			out = append(out, AIArtifact{Tool: e.tool, Path: e.dir + "/", Kind: "config", Confidence: "medium"})
			continue
		}
		out = append(out, AIArtifact{Tool: e.tool, Path: e.dir + "/", Kind: "config", Confidence: "high"})
	}
	return out
}

func detectKnownAIFiles(dir string) []AIArtifact {
	var out []AIArtifact
	for _, e := range knownAIFiles {
		if fileExists(filepath.Join(dir, e.file)) {
			out = append(out, AIArtifact{Tool: e.tool, Path: e.file, Kind: "rules", Confidence: "high"})
		}
	}
	return out
}

func detectKnownAIGlobs(dir string) []AIArtifact {
	var out []AIArtifact
	for _, e := range knownAIGlobs {
		matches := globMany(dir, e.pattern)
		for _, m := range matches {
			out = append(out, AIArtifact{Tool: e.tool, Path: filepath.Base(m), Kind: "config", Confidence: "high"})
		}
	}
	return out
}

func detectClaudeDirArtifacts(dir string) []AIArtifact {
	claude := filepath.Join(dir, ".claude")
	if !dirExists(claude) {
		return nil
	}
	var out []AIArtifact
	if fileExists(filepath.Join(claude, "pipeline.conf")) {
		out = append(out, AIArtifact{Tool: "Tekhton", Path: ".claude/pipeline.conf", Kind: "config", Confidence: "high"})
	}
	if dirExists(filepath.Join(claude, "agents")) {
		if len(globMany(filepath.Join(claude, "agents"), "*.md")) > 0 {
			out = append(out, AIArtifact{Tool: "Tekhton", Path: ".claude/agents/", Kind: "agents", Confidence: "high"})
		}
	}
	if dirExists(filepath.Join(claude, "milestones")) {
		out = append(out, AIArtifact{Tool: "Tekhton", Path: ".claude/milestones/", Kind: "config", Confidence: "high"})
	}
	if fileExists(filepath.Join(claude, "settings.json")) {
		out = append(out, AIArtifact{Tool: "Claude Code", Path: ".claude/settings.json", Kind: "config", Confidence: "high"})
	}
	if fileExists(filepath.Join(claude, "settings.local.json")) {
		out = append(out, AIArtifact{Tool: "Claude Code", Path: ".claude/settings.local.json", Kind: "config", Confidence: "high"})
	}
	if dirExists(filepath.Join(claude, "commands")) {
		if entries, err := readDirNames(filepath.Join(claude, "commands")); err == nil && len(entries) > 0 {
			out = append(out, AIArtifact{Tool: "Claude Code", Path: ".claude/commands/", Kind: "config", Confidence: "high"})
		}
	}
	return out
}

func detectClaudeMD(dir string) []AIArtifact {
	p := filepath.Join(dir, "CLAUDE.md")
	if !fileExists(p) {
		return nil
	}
	body := readFile(p)
	if strings.Contains(body, "<!-- tekhton-managed -->") {
		return []AIArtifact{{Tool: "Tekhton", Path: "CLAUDE.md", Kind: "rules", Confidence: "high"}}
	}
	return []AIArtifact{{Tool: "Claude/Tekhton", Path: "CLAUDE.md", Kind: "rules", Confidence: "medium"}}
}

// detectDirectiveMarkdowns scans well-known markdown candidates for
// agent-style directives (`_scan_for_directive_language`).
func detectDirectiveMarkdowns(dir string) []AIArtifact {
	var out []AIArtifact
	for _, c := range []string{"AGENTS.md", "CONVENTIONS.md", "ARCHITECTURE.md"} {
		p := filepath.Join(dir, c)
		if !fileExists(p) {
			continue
		}
		if scanForDirectiveLanguage(p) {
			out = append(out, AIArtifact{Tool: "AI Directives", Path: c, Kind: "rules", Confidence: "low"})
		}
	}
	return out
}

var (
	rxYouAre      = regexp.MustCompile(`(?im)^\s*you are\b`)
	rxYourRoleJob = regexp.MustCompile(`(?im)^\s*your (role|job)\b`)
	rxRulesHeader = regexp.MustCompile(`(?im)^##\s*(Rules|Constraints|Guidelines|Instructions)`)
	rxDirective   = regexp.MustCompile(`\bMUST\b|\bNEVER\b|\bALWAYS\b`)
)

// scanForDirectiveLanguage ports _scan_for_directive_language. Returns
// true when at least two of the four markers fire.
func scanForDirectiveLanguage(file string) bool {
	if filepath.Ext(file) != ".md" {
		return false
	}
	body := readFile(file)
	count := 0
	if rxYouAre.MatchString(body) {
		count++
	}
	if rxYourRoleJob.MatchString(body) {
		count++
	}
	if rxRulesHeader.MatchString(body) {
		count++
	}
	matches := rxDirective.FindAllString(body, -1)
	if len(matches) >= 3 {
		count++
	}
	return count >= 2
}

// dirHasConfigFiles ports _dir_has_config_files.
func dirHasConfigFiles(dir string) bool {
	for _, pat := range []string{"*.json", "*.yaml", "*.yml", "*.md", "*.toml"} {
		if len(globMany(dir, pat)) > 0 {
			return true
		}
	}
	return false
}

// ClassifyAITool ports classify_ai_tool. Exposed for parity with the
// bash surface; not used by Render today but available to callers.
func ClassifyAITool(path string) string {
	switch {
	case strings.HasPrefix(path, ".cursor/") || path == ".cursorrules":
		return "Cursor"
	case strings.HasPrefix(path, ".github/copilot/"):
		return "GitHub Copilot"
	case strings.HasPrefix(path, ".aider"):
		return "aider"
	case strings.HasPrefix(path, ".cline/") || strings.HasPrefix(path, "cline_docs/"):
		return "Cline"
	case strings.HasPrefix(path, ".continue/"):
		return "Continue.dev"
	case strings.HasPrefix(path, ".windsurf/") || path == ".windsurfrules":
		return "Windsurf"
	case path == ".roomodes" || strings.HasPrefix(path, ".roo/"):
		return "Roo Code"
	case strings.HasPrefix(path, ".ai/") || path == ".aiconfig":
		return "Generic AI Config"
	case path == ".claude/pipeline.conf",
		strings.HasPrefix(path, ".claude/agents/"),
		strings.HasPrefix(path, ".claude/milestones/"):
		return "Tekhton"
	case path == ".claude/settings.json", path == ".claude/settings.local.json",
		strings.HasPrefix(path, ".claude/commands/"):
		return "Claude Code"
	case strings.HasPrefix(path, ".claude/"):
		return "Claude Code"
	case path == "CLAUDE.md":
		return "Claude/Tekhton"
	}
	return "unknown"
}
