package preflight

import (
	"context"
	"os"
	"path/filepath"
	"testing"
)

func runClaudeEnv(t *testing.T, projectDir string, env map[string]string) []Finding {
	t.Helper()
	in := &Input{ProjectDir: projectDir, Env: env}
	return ClaudeEnvCheck{}.Run(context.Background(), in).Findings
}

func TestClaudeEnv_MissingSettingsFile_NoFinding(t *testing.T) {
	proj := t.TempDir()
	// claude binary detection is environment-dependent; force-skip
	// the version sub-check by pointing at a non-existent binary.
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	for _, f := range got {
		if f.Name == "Claude settings.json" {
			t.Errorf("expected no settings.json finding when file absent; got %+v", f)
		}
	}
}

func TestClaudeEnv_EmptySettingsFile_Pass(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	// settings.json is itself the "managed marker" — present + empty
	// content exercises the empty-file branch of checkClaudeSettingsJSON.
	if err := os.WriteFile(filepath.Join(proj, ".claude", "settings.json"), []byte(""), 0o644); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	assertFindingStatus(t, got, "Claude settings.json", StatusPass)
}

func TestClaudeEnv_ValidSettingsJSON_Pass(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	settings := []byte(`{"includeCoAuthoredBy": false, "model": "opus"}`)
	if err := os.WriteFile(filepath.Join(proj, ".claude", "settings.json"), settings, 0o644); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	assertFindingStatus(t, got, "Claude settings.json", StatusPass)
}

// Malformed JSON is the load-bearing case: claude refuses to load tool
// config when settings.json fails to parse, and the symptom looks
// identical to "model decided not to do anything." Must fail loudly.
func TestClaudeEnv_MalformedSettingsJSON_Fail(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".claude", "settings.json"),
		[]byte(`{"includeCoAuthoredBy": false,`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	assertFindingStatus(t, got, "Claude settings.json", StatusFail)
}

// When the claude binary is missing entirely, the version sub-check must
// emit nothing (Tekhton may be invoked from a build context without claude
// installed; the supervisor handles "binary missing" at the run_agent
// boundary with a much better error message). The .claude/ directory is
// created so the outer applicability gate doesn't short-circuit the run.
func TestClaudeEnv_MissingClaudeBinary_NoVersionFinding(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude", "agents"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	for _, f := range got {
		if f.Name == "Claude CLI version" {
			t.Errorf("expected no version finding when binary absent; got %+v", f)
		}
	}
}

// Applicability gate: a project without a Claude-/Tekhton-managed marker
// must skip entirely. Without this gate the version sub-check would fire
// whenever the claude binary lives on PATH, false-alarming preflight on
// every adjacent directory.
func TestClaudeEnv_NoManagedMarker_SkipsEntireCheck(t *testing.T) {
	proj := t.TempDir()
	// Don't create any marker files.
	got := runClaudeEnv(t, proj, nil)
	if len(got) != 0 {
		t.Errorf("expected zero findings without managed marker; got %d: %+v", len(got), got)
	}
}

// Regression: ui_audit's auto-fix creates `.claude/preflight_bak/` as a
// side effect, which the previous overly-loose gate (any `.claude/` dir
// is a marker) treated as "Claude-managed." Result: the parity-test
// fixture started growing a spurious "Claude CLI version" finding after
// ui_audit ran. The gate must look for a deliberate marker file.
func TestClaudeEnv_OnlyPreflightBakDir_SkipsEntireCheck(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude", "preflight_bak"), 0o755); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	if len(got) != 0 {
		t.Errorf("expected zero findings when only .claude/preflight_bak/ exists; got %d: %+v",
			len(got), got)
	}
}

// pipeline.conf alone is sufficient signal — many Tekhton projects have
// a config but no settings.json (claude defaults are fine), so the gate
// must accept that as a managed marker. Verified by adding a malformed
// settings.json alongside pipeline.conf and confirming the malformed-JSON
// finding fires (it wouldn't if the gate had short-circuited).
func TestClaudeEnv_PipelineConfMarker_FiresCheck(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".claude", "pipeline.conf"), []byte("PROJECT_NAME=demo\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".claude", "settings.json"), []byte(`{broken`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	assertFindingStatus(t, got, "Claude settings.json", StatusFail)
}

// agents/ dir alone is sufficient signal — same reasoning as
// pipeline.conf but the marker is the agents directory rather than the
// config file.
func TestClaudeEnv_AgentsDirMarker_FiresCheck(t *testing.T) {
	proj := t.TempDir()
	if err := os.MkdirAll(filepath.Join(proj, ".claude", "agents"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, ".claude", "settings.json"), []byte(`{broken`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := runClaudeEnv(t, proj, map[string]string{"TEKHTON_CLAUDE_BIN": "/no/such/claude"})
	assertFindingStatus(t, got, "Claude settings.json", StatusFail)
}

func TestCompareSemver(t *testing.T) {
	cases := []struct {
		a, b   string
		want   int
		wantOK bool
	}{
		{"2.1.146", "2.1.140", 1, true},
		{"2.1.140", "2.1.146", -1, true},
		{"2.1.146", "2.1.146", 0, true},
		{"3.0.0", "2.99.99", 1, true},
		{"v2.1.146", "2.1.146", 0, true},
		{"2.1.146-beta1", "2.1.146", 0, true},
		{"notaversion", "2.1.146", 0, false},
	}
	for _, tc := range cases {
		got, ok := compareSemver(tc.a, tc.b)
		if got != tc.want || ok != tc.wantOK {
			t.Errorf("compareSemver(%q,%q) = (%d,%v); want (%d,%v)",
				tc.a, tc.b, got, ok, tc.want, tc.wantOK)
		}
	}
}

func assertFindingStatus(t *testing.T, findings []Finding, name string, want Status) {
	t.Helper()
	for _, f := range findings {
		if f.Name == name {
			if f.Status != want {
				t.Errorf("%s: got status %s, want %s (detail: %s)", name, f.Status, want, f.Detail)
			}
			return
		}
	}
	t.Errorf("no finding named %q in result", name)
}
