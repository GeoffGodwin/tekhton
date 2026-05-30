package detect

import (
	"context"
	"reflect"
	"testing"
)

// TestHeuristicOrder is the load-bearing m29.2 invariant. Reordering
// aiArtifactHeuristics changes classify_ai_tool's tie-break, which
// changes the bash baselines, which fails the parity gate.
func TestHeuristicOrder(t *testing.T) {
	want := []string{
		"known_dirs", "known_files", "known_globs",
		"claude_dir", "claude_md", "directive_markdowns",
	}
	got := make([]string, len(aiArtifactHeuristics))
	for i, h := range aiArtifactHeuristics {
		got[i] = h.name
	}
	if !reflect.DeepEqual(want, got) {
		t.Fatalf("heuristic order changed; parity gate will fail.\nwant %v\n got %v", want, got)
	}
}

func TestAIArtifactsDetector_ClaudeDir(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".claude/pipeline.conf":      "PROJECT_NAME=x\n",
		".claude/agents/coder.md":    "you are a coder.\n",
		".claude/settings.json":      "{}",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	tools := map[string]bool{}
	for _, row := range r.Findings {
		tools[row["tool"]] = true
	}
	if !tools["Tekhton"] || !tools["Claude Code"] {
		t.Errorf("expected both Tekhton + Claude Code findings; got %v", tools)
	}
}

func TestAIArtifactsDetector_CursorPlusClaude(t *testing.T) {
	// Tie-breaking case: .cursor/ runs in known_dirs (first heuristic),
	// CLAUDE.md runs in claude_md (5th heuristic). The first match wins
	// in classify_ai_tool for ambiguous paths, but distinct paths emit
	// independent rows. Verify both fire and that Cursor (known_dirs)
	// appears BEFORE Claude/Tekhton (claude_md) in the result.
	dir := writeFixture(t, map[string]string{
		".cursor/rules.md": "rules\n",
		"CLAUDE.md":        "# project\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	var cursorIdx, claudeIdx int = -1, -1
	for i, row := range r.Findings {
		switch row["tool"] {
		case "Cursor":
			cursorIdx = i
		case "Claude/Tekhton":
			claudeIdx = i
		}
	}
	if cursorIdx < 0 || claudeIdx < 0 {
		t.Fatalf("expected both Cursor and Claude/Tekhton findings; got %v", r.Findings)
	}
	if cursorIdx > claudeIdx {
		t.Errorf("expected Cursor to appear before Claude/Tekhton (heuristic order); got Cursor@%d, Claude@%d", cursorIdx, claudeIdx)
	}
}

func TestAIArtifactsDetector_None(t *testing.T) {
	dir := writeFixture(t, map[string]string{"README.md": "# x"})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	if len(r.Findings) != 0 {
		t.Errorf("expected no AI artifacts; got %v", r.Findings)
	}
}

func TestClassifyAITool(t *testing.T) {
	cases := map[string]string{
		".cursor/rules.md":         "Cursor",
		".cursorrules":             "Cursor",
		".aider.conf.yml":          "aider",
		".claude/agents/coder.md":  "Tekhton",
		".claude/settings.json":    "Claude Code",
		".claude/commands/foo.md":  "Claude Code",
		"CLAUDE.md":                "Claude/Tekhton",
		"random.txt":               "unknown",
	}
	for path, want := range cases {
		if got := ClassifyAITool(path); got != want {
			t.Errorf("ClassifyAITool(%q) = %q; want %q", path, got, want)
		}
	}
}

// --- known_dirs heuristic ---

func TestAIArtifactsDetector_KnownDirs_Cursor(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".cursor/settings.json": `{"cursorVersion":"1.0"}`,
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Cursor" && row["path"] == ".cursor/" {
			found = true
			if row["type"] != "config" {
				t.Errorf("cursor dir type: got %q, want config", row["type"])
			}
			if row["confidence"] != "high" {
				t.Errorf("cursor dir confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected known_dirs Cursor finding for .cursor/; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownDirs_Windsurf(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".windsurf/config.yaml": "version: 1\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Windsurf" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected known_dirs Windsurf finding; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownDirs_AIWithConfigFiles(t *testing.T) {
	// .ai/ only triggers when it contains config files (not Adobe Illustrator files).
	dir := writeFixture(t, map[string]string{
		".ai/config.json": `{"model":"gpt-4"}`,
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Generic AI Config" {
			found = true
			if row["confidence"] != "medium" {
				t.Errorf(".ai/ dir confidence: got %q, want medium", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected Generic AI Config finding for .ai/ with config files; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownDirs_AIEmptyDirIgnored(t *testing.T) {
	// An empty .ai/ directory (no config files) must NOT produce a finding.
	dir := writeFixture(t, map[string]string{
		".ai/.gitkeep": "",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["tool"] == "Generic AI Config" {
			t.Errorf("expected no Generic AI Config finding for empty .ai/; got %v", row)
		}
	}
}

// --- known_files heuristic ---

func TestAIArtifactsDetector_KnownFiles_Cursorrules(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".cursorrules": "# cursor rules\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Cursor" && row["path"] == ".cursorrules" {
			found = true
			if row["type"] != "rules" {
				t.Errorf(".cursorrules type: got %q, want rules", row["type"])
			}
		}
	}
	if !found {
		t.Fatalf("expected known_files Cursor finding for .cursorrules; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownFiles_Windsurfrules(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".windsurfrules": "always use TypeScript\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Windsurf" && row["path"] == ".windsurfrules" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected known_files Windsurf finding for .windsurfrules; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownFiles_RooModes(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".roomodes": `{"modes":[]}`,
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "Roo Code" && row["path"] == ".roomodes" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected known_files Roo Code finding for .roomodes; got %v", r.Findings)
	}
}

// --- known_globs heuristic ---

func TestAIArtifactsDetector_KnownGlobs_Aider(t *testing.T) {
	dir := writeFixture(t, map[string]string{
		".aider.conf.yml": "model: gpt-4o\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "aider" {
			found = true
			if row["type"] != "config" {
				t.Errorf("aider glob type: got %q, want config", row["type"])
			}
			if row["confidence"] != "high" {
				t.Errorf("aider glob confidence: got %q, want high", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected known_globs aider finding for .aider.conf.yml; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_KnownGlobs_AiderHistory(t *testing.T) {
	// .aider.chat.history.md also matches the .aider* glob.
	dir := writeFixture(t, map[string]string{
		".aider.chat.history.md": "# aider chat history\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "aider" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected known_globs aider finding for .aider.chat.history.md; got %v", r.Findings)
	}
}

// --- known_dirs fires BEFORE known_files in result ordering ---

func TestAIArtifactsDetector_HeuristicOrderDirsBeforeFiles(t *testing.T) {
	// .cursor/ (known_dirs) and .cursorrules (known_files) should both fire,
	// with the dir finding appearing first in r.Findings.
	dir := writeFixture(t, map[string]string{
		".cursor/rules.md": "rules\n",
		".cursorrules":     "extra rules\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	var dirIdx, fileIdx int = -1, -1
	for i, row := range r.Findings {
		if row["tool"] == "Cursor" {
			if row["path"] == ".cursor/" && dirIdx < 0 {
				dirIdx = i
			} else if row["path"] == ".cursorrules" && fileIdx < 0 {
				fileIdx = i
			}
		}
	}
	if dirIdx < 0 || fileIdx < 0 {
		t.Fatalf("expected both .cursor/ and .cursorrules findings; got %v", r.Findings)
	}
	if dirIdx > fileIdx {
		t.Errorf("expected .cursor/ (known_dirs) before .cursorrules (known_files); got dir@%d file@%d", dirIdx, fileIdx)
	}
}

// --- directive markdowns ---

func TestAIArtifactsDetector_DirectiveMarkdown(t *testing.T) {
	// AGENTS.md with sufficient directive markers should produce an AI Directives finding.
	dir := writeFixture(t, map[string]string{
		"AGENTS.md": "## Rules\n\nYou are a helpful assistant.\n\nYou MUST always follow the style guide. You NEVER break the API. ALWAYS write tests.\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	found := false
	for _, row := range r.Findings {
		if row["tool"] == "AI Directives" && row["path"] == "AGENTS.md" {
			found = true
			if row["type"] != "rules" {
				t.Errorf("directive md type: got %q, want rules", row["type"])
			}
			if row["confidence"] != "low" {
				t.Errorf("directive md confidence: got %q, want low", row["confidence"])
			}
		}
	}
	if !found {
		t.Fatalf("expected AI Directives finding for AGENTS.md; got %v", r.Findings)
	}
}

func TestAIArtifactsDetector_DirectiveMarkdown_InsufficientMarkers(t *testing.T) {
	// A markdown with only one directive marker must NOT produce an AI Directives finding.
	dir := writeFixture(t, map[string]string{
		"AGENTS.md": "# About\n\nThis project does X. You MUST read the README.\n",
	})
	r, _ := AIArtifactsDetector{}.Run(context.Background(), &Input{ProjectDir: dir})
	for _, row := range r.Findings {
		if row["tool"] == "AI Directives" {
			t.Errorf("expected no AI Directives finding with only one marker; got %v", row)
		}
	}
}
