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
