package intake

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
)

func TestExtractWords_4CharMinUnique(t *testing.T) {
	got := extractWords("Add the FOO bar baz quux to the foo plan again", 4)
	want := []string{"again", "plan", "quux"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("extractWords = %v, want %v", got, want)
	}
}

func TestExtractWords_EmptyAndNoMatches(t *testing.T) {
	if got := extractWords("", 4); len(got) != 0 {
		t.Errorf("empty task should produce no words, got %v", got)
	}
	if got := extractWords("a b c def", 4); len(got) != 0 {
		t.Errorf("no-4-char-word task should produce nothing, got %v (the > 3-char 'def' is exactly 3)", got)
	}
}

func TestExtractWords_CaseInsensitive(t *testing.T) {
	got := extractWords("Verify the BUILD works", 4)
	sort.Strings(got)
	want := []string{"build", "verify", "works"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("case-insensitive extractWords = %v, want %v", got, want)
	}
}

func TestMatchNotes_KeywordOverlap(t *testing.T) {
	all := []string{
		"- [BUG] Fix the build script",
		"- [FEAT] Add login screen",
		"- [POLISH] Tweak the colors",
	}
	got := matchNotes("verify the build works", all)
	want := []string{"- [BUG] Fix the build script"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("matchNotes = %v, want %v", got, want)
	}
}

func TestMatchNotes_NoMatch(t *testing.T) {
	all := []string{"- [FEAT] Add login screen"}
	if got := matchNotes("ship it", all); len(got) != 0 {
		t.Errorf("no overlap should produce nothing, got %v", got)
	}
}

func TestMatchNotes_FilterEmptyLines(t *testing.T) {
	all := []string{
		"",
		"- [BUG] verify works",
		"",
	}
	got := matchNotes("verify the system", all)
	if len(got) != 1 || got[0] != "- [BUG] verify works" {
		t.Errorf("matchNotes should skip empty lines, got %v", got)
	}
}

func TestBuildIntakeRoleContent_MissingReturnsEmpty(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		ProjectDir: dir,
		RoleFile:   ".claude/agents/intake.md",
	}
	if got := buildIntakeRoleContent(cfg); got != "" {
		t.Errorf("missing role file should return empty, got %q", got)
	}
}

func TestBuildIntakeRoleContent_ReadsFile(t *testing.T) {
	dir := t.TempDir()
	rolePath := filepath.Join(dir, ".claude", "agents", "intake.md")
	if err := os.MkdirAll(filepath.Dir(rolePath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := "You are the intake agent. Be terse."
	if err := os.WriteFile(rolePath, []byte(body), 0o644); err != nil {
		t.Fatalf("write role file: %v", err)
	}
	cfg := config{
		ProjectDir: dir,
		RoleFile:   ".claude/agents/intake.md",
	}
	if got := buildIntakeRoleContent(cfg); got != body {
		t.Errorf("buildIntakeRoleContent = %q, want %q", got, body)
	}
}

func TestBuildNotesContext_NoFile(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		ProjectDir:     dir,
		HumanNotesFile: ".tekhton/HUMAN_NOTES.md",
		Task:           "verify the build works",
	}
	if got := buildNotesContext(context.Background(), cfg); got != "" {
		t.Errorf("missing notes file should return empty, got %q", got)
	}
}

func TestBuildNotesContext_FiltersByTask(t *testing.T) {
	dir := t.TempDir()
	notesPath := filepath.Join(dir, ".tekhton", "HUMAN_NOTES.md")
	if err := os.MkdirAll(filepath.Dir(notesPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := `# Human Notes

- [ ] [BUG] Fix the build pipeline
- [ ] [FEAT] Add login screen
- [ ] [POLISH] Tweak the colors
`
	if err := os.WriteFile(notesPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write notes: %v", err)
	}
	cfg := config{
		ProjectDir:     dir,
		HumanNotesFile: ".tekhton/HUMAN_NOTES.md",
		Task:           "verify the build works",
	}
	got := buildNotesContext(context.Background(), cfg)
	if !strings.Contains(got, "Fix the build pipeline") {
		t.Errorf("matching note missing in %q", got)
	}
	if strings.Contains(got, "Tweak the colors") {
		t.Errorf("non-matching note leaked into %q", got)
	}
}

func TestBuildPromptVars_PopulatesRequiredKeys(t *testing.T) {
	dir := t.TempDir()
	cfg := config{
		ProjectDir:        dir,
		HumanNotesFile:    ".tekhton/HUMAN_NOTES.md",
		ProjectIndexFile:  ".tekhton/PROJECT_INDEX.md",
		RoleFile:          ".claude/agents/intake.md",
		ReportFile:        filepath.Join(dir, ".tekhton/INTAKE_REPORT.md"),
		Task:              "verify the system",
		UIProjectDetected: "false",
		UIFramework:       "",
	}
	vars := buildPromptVars(context.Background(), cfg, "milestone body here")
	required := []string{
		"INTAKE_MILESTONE_CONTENT", "INTAKE_PROJECT_INDEX", "INTAKE_HISTORY_BLOCK",
		"HEALTH_SCORE_SUMMARY", "INTAKE_ROLE_CONTENT", "NOTES_CONTEXT_BLOCK",
		"UI_PROJECT_DETECTED", "UI_FRAMEWORK", "INTAKE_REPORT_FILE", "TASK",
	}
	for _, k := range required {
		if _, ok := vars[k]; !ok {
			t.Errorf("missing required prompt var %q", k)
		}
	}
	if vars["INTAKE_MILESTONE_CONTENT"] != "milestone body here" {
		t.Errorf("milestone content not populated: %q", vars["INTAKE_MILESTONE_CONTENT"])
	}
	if vars["TASK"] != "verify the system" {
		t.Errorf("TASK not populated: %q", vars["TASK"])
	}
}

func TestSplitLines_HandlesEmpty(t *testing.T) {
	if got := splitLines(""); got != nil {
		t.Errorf("empty input should return nil, got %v", got)
	}
}

func TestSplitLines_PreservesBlank(t *testing.T) {
	got := splitLines("a\n\nb\n")
	want := []string{"a", "", "b"}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("splitLines = %v, want %v", got, want)
	}
}

func TestCapBytes(t *testing.T) {
	if capBytes("hello", 10) != "hello" {
		t.Error("short input should be unchanged")
	}
	if capBytes("0123456789ABC", 5) != "01234" {
		t.Error("long input should be truncated to limit")
	}
}

// TestBuildNotesContext_IgnoresHumanNotesFileEnvVar is the regression guard for
// the buildNotesContext fix: the function must use the already-resolved
// notesPath from cfg.HumanNotesFile, NOT the HUMAN_NOTES_FILE env var that
// notes.ExtractFromProject / LoadDocument read internally. With the old code
// (ExtractFromProject), setting HUMAN_NOTES_FILE to /nonexistent would cause
// the function to return "" even when cfg.HumanNotesFile points to a real file.
func TestBuildNotesContext_IgnoresHumanNotesFileEnvVar(t *testing.T) {
	dir := t.TempDir()
	notesPath := filepath.Join(dir, ".tekhton", "HUMAN_NOTES.md")
	if err := os.MkdirAll(filepath.Dir(notesPath), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	body := "# Human Notes\n\n- [ ] [BUG] Fix the build pipeline\n"
	if err := os.WriteFile(notesPath, []byte(body), 0o644); err != nil {
		t.Fatalf("write notes: %v", err)
	}

	// Point env var at a nonexistent path to prove it is NOT consulted.
	t.Setenv("HUMAN_NOTES_FILE", "/nonexistent/path/HUMAN_NOTES.md")

	cfg := config{
		ProjectDir:     dir,
		HumanNotesFile: ".tekhton/HUMAN_NOTES.md",
		Task:           "fix the build pipeline",
	}
	got := buildNotesContext(context.Background(), cfg)
	if !strings.Contains(got, "Fix the build pipeline") {
		t.Errorf("buildNotesContext must use cfg.HumanNotesFile, not HUMAN_NOTES_FILE env var; got %q", got)
	}
}
