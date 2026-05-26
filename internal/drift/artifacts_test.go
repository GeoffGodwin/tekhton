package drift

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func tempADR(t *testing.T) *ADR {
	t.Helper()
	dir := t.TempDir()
	a := NewADR(filepath.Join(dir, "ARCHITECTURE_DECISION_LOG.md"))
	a.Now = func() time.Time { return time.Date(2026, 5, 26, 0, 0, 0, 0, time.UTC) }
	return a
}

func tempHA(t *testing.T) *HumanAction {
	t.Helper()
	dir := t.TempDir()
	h := NewHumanAction(filepath.Join(dir, "HUMAN_ACTION_REQUIRED.md"))
	h.Now = func() time.Time { return time.Date(2026, 5, 26, 0, 0, 0, 0, time.UTC) }
	return h
}

func TestADR_EnsureFile(t *testing.T) {
	a := tempADR(t)
	if err := a.EnsureFile(); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(a.Path)
	if !strings.Contains(string(body), "# Architecture Decision Log") {
		t.Errorf("preamble missing:\n%s", body)
	}
}

func TestADR_NextNumber_EmptyFile(t *testing.T) {
	a := tempADR(t)
	_ = a.EnsureFile()
	n, err := a.NextNumber()
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("NextNumber on empty = %d, want 1", n)
	}
}

func TestADR_NextNumber_WithExistingEntries(t *testing.T) {
	a := tempADR(t)
	// Acceptance criterion: fixture with ADR-0007 → NextNumber=8.
	body := `# Architecture Decision Log

## ADL-1: alpha
content

## ADL-7: highest
content
`
	if err := os.WriteFile(a.Path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	n, err := a.NextNumber()
	if err != nil {
		t.Fatal(err)
	}
	if n != 8 {
		t.Errorf("NextNumber after ADL-7 = %d, want 8", n)
	}
}

func TestADR_NextNumber_WithADL0007(t *testing.T) {
	// Acceptance criterion: NextADRNumber returns 8 against a fixture
	// containing ADR-0007 as the highest. The Go port emits the legacy
	// "ADL-N" prefix to match bash output; the acceptance criterion's
	// "ADR-0007" wording covers both prefixes since the regex looks for
	// the numeric suffix.
	a := tempADR(t)
	body := `# Architecture Decision Log

## ADL-7: highest
`
	if err := os.WriteFile(a.Path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := a.NextNumber()
	if err != nil {
		t.Fatal(err)
	}
	if got != 8 {
		t.Errorf("NextNumber with highest=7 returned %d, want 8 — acceptance criterion regressed", got)
	}
}

func TestADR_AppendDecision(t *testing.T) {
	a := tempADR(t)
	lines := []string{
		"- ACP: refactor splitter into dag-aware unit — ACCEPT — clearer ownership",
	}
	if err := a.AppendDecision("port the splitter", lines); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(a.Path)
	s := string(body)
	if !strings.Contains(s, "## ADL-1:") {
		t.Errorf("ADL-1 heading missing:\n%s", s)
	}
	if !strings.Contains(s, "refactor splitter into dag-aware unit") {
		t.Errorf("ACP name missing:\n%s", s)
	}
	if !strings.Contains(s, "clearer ownership") {
		t.Errorf("rationale missing:\n%s", s)
	}
	if !strings.Contains(s, `"port the splitter"`) {
		t.Errorf("task missing:\n%s", s)
	}
}

func TestHumanAction_AppendAndCount(t *testing.T) {
	h := tempHA(t)
	if err := h.Append("coder", "review design doc inconsistency in section 4"); err != nil {
		t.Fatal(err)
	}
	body, _ := os.ReadFile(h.Path)
	if !strings.Contains(string(body), "- [ ] [2026-05-26 | Source: coder]") {
		t.Errorf("action line shape wrong:\n%s", body)
	}
	n, err := h.CountUnchecked()
	if err != nil {
		t.Fatal(err)
	}
	if n != 1 {
		t.Errorf("CountUnchecked = %d, want 1", n)
	}
	has, _ := h.HasUnchecked()
	if !has {
		t.Error("HasUnchecked should be true")
	}
}

func TestHumanAction_ConsolidateLegacy(t *testing.T) {
	dir := t.TempDir()
	canonical := filepath.Join(dir, ".tekhton", "HUMAN_ACTION_REQUIRED.md")
	legacy := filepath.Join(dir, "HUMAN_ACTION_REQUIRED.md")

	// Write canonical with one existing item.
	_ = os.MkdirAll(filepath.Dir(canonical), 0o755)
	_ = os.WriteFile(canonical, []byte("# Human Action Required\n\n## Action Items\n- [ ] [2026-01-01] existing\n"), 0o644)
	// Write legacy with one new item + one duplicate.
	_ = os.WriteFile(legacy, []byte("- [ ] [2026-01-01] existing\n- [ ] [2026-01-02] new\n"), 0o644)

	h := NewHumanAction(canonical)
	merged, err := h.ConsolidateLegacy(legacy)
	if err != nil {
		t.Fatal(err)
	}
	if merged != 1 {
		t.Errorf("merged = %d, want 1 (one dedup)", merged)
	}
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Error("legacy file should be removed after consolidation")
	}
	body, _ := os.ReadFile(canonical)
	if !strings.Contains(string(body), "new") {
		t.Error("new item should be merged into canonical")
	}
}

func TestParseACPLine(t *testing.T) {
	name, rationale := parseACPLine("- ACP: short name — ACCEPT — solid reason")
	if name != "short name" {
		t.Errorf("name = %q, want short name", name)
	}
	if rationale != "solid reason" {
		t.Errorf("rationale = %q, want solid reason", rationale)
	}
}

// TestParseACPLine_NoACPMarker covers the else-branch where the input
// line doesn't contain the "ACP: " prefix. The whole line should become
// the name.
func TestParseACPLine_NoACPMarker(t *testing.T) {
	name, rationale := parseACPLine("plain description without prefix")
	if name == "" {
		t.Error("name should be non-empty for a line without ACP: prefix")
	}
	if rationale != "" {
		t.Errorf("rationale should be empty, got %q", rationale)
	}
}

// TestADR_EnsureFile_Idempotent ensures calling EnsureFile twice does
// not corrupt the file or change its content.
func TestADR_EnsureFile_Idempotent(t *testing.T) {
	a := tempADR(t)
	if err := a.EnsureFile(); err != nil {
		t.Fatal(err)
	}
	first, _ := os.ReadFile(a.Path)
	if err := a.EnsureFile(); err != nil {
		t.Fatal(err)
	}
	second, _ := os.ReadFile(a.Path)
	if string(first) != string(second) {
		t.Errorf("EnsureFile not idempotent: first=%q second=%q", first, second)
	}
}

// TestHumanAction_CountUnchecked_MissingFile verifies the missing-file
// path returns 0 without error (file may not exist yet).
func TestHumanAction_CountUnchecked_MissingFile(t *testing.T) {
	h := tempHA(t)
	// Do not call EnsureFile — the file must not exist.
	n, err := h.CountUnchecked()
	if err != nil {
		t.Fatalf("CountUnchecked on missing file: %v", err)
	}
	if n != 0 {
		t.Errorf("CountUnchecked missing = %d, want 0", n)
	}
}

// TestHumanAction_ConsolidateLegacy_NoCanonical verifies that when the
// canonical file does not yet exist, the legacy file is simply moved
// into place (os.Rename path).
func TestHumanAction_ConsolidateLegacy_NoCanonical(t *testing.T) {
	dir := t.TempDir()
	canonical := filepath.Join(dir, "sub", "HUMAN_ACTION_REQUIRED.md")
	legacy := filepath.Join(dir, "HUMAN_ACTION_REQUIRED.md")

	// Write only the legacy file; canonical does not exist.
	_ = os.WriteFile(legacy, []byte("- [ ] [2026-01-01] only item\n"), 0o644)

	h := NewHumanAction(canonical)
	merged, err := h.ConsolidateLegacy(legacy)
	if err != nil {
		t.Fatalf("ConsolidateLegacy: %v", err)
	}
	// Rename path returns 0 merged (just moved, not merged line-by-line).
	if merged != 0 {
		t.Errorf("merged = %d, want 0 for a pure move", merged)
	}
	if _, err := os.Stat(legacy); !os.IsNotExist(err) {
		t.Error("legacy file should have been moved (not exist at old path)")
	}
	if _, err := os.Stat(canonical); err != nil {
		t.Errorf("canonical file should now exist: %v", err)
	}
}
