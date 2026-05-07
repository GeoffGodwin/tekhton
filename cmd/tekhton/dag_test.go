package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/dag"
	"github.com/geoffgodwin/tekhton/internal/manifest"
)

const dagCLIFixture = `# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|done||m01.md|
m02|Second|in_progress|m01|m02.md|
m03|Third|pending|m02|m03.md|
m04|Fourth|pending|m01|m04.md|
`

// ---------------------------------------------------------------------------
// frontier
// ---------------------------------------------------------------------------

func TestDagFrontierCmd(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	cmd := newDagFrontierCmd()
	cmd.SetArgs([]string{"--path", path})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	want := "m02\nm04\n"
	if out != want {
		t.Errorf("frontier got %q, want %q", out, want)
	}
}

func TestDagFrontierCmd_NoPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	cmd := newDagFrontierCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Errorf("expected error for missing path")
	}
}

// ---------------------------------------------------------------------------
// active
// ---------------------------------------------------------------------------

func TestDagActiveCmd(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	cmd := newDagActiveCmd()
	cmd.SetArgs([]string{"--path", path})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	if out != "m02\n" {
		t.Errorf("active got %q, want %q", out, "m02\n")
	}
}

// ---------------------------------------------------------------------------
// advance
// ---------------------------------------------------------------------------

func TestDagAdvanceCmd_Success(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	cmd := newDagAdvanceCmd()
	cmd.SetArgs([]string{"--path", path, "m02", "done"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	m, err := manifest.Load(path)
	if err != nil {
		t.Fatal(err)
	}
	e, _ := m.Get("m02")
	if e.Status != "done" {
		t.Errorf("Status after advance = %s, want done", e.Status)
	}
}

func TestDagAdvanceCmd_InvalidTransition(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	cmd := newDagAdvanceCmd()
	cmd.SetArgs([]string{"--path", path, "m01", "in_progress"}) // m01 is done -> terminal
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.code != exitUsage {
		t.Errorf("err code = %v, want exitUsage", err)
	}
}

func TestDagAdvanceCmd_UnknownID(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	cmd := newDagAdvanceCmd()
	cmd.SetArgs([]string{"--path", path, "m99", "done"})
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.code != exitNotFound {
		t.Errorf("err code = %v, want exitNotFound", err)
	}
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

func TestDagValidateCmd_Clean(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	dir := filepath.Dir(path)
	for _, fn := range []string{"m01.md", "m02.md", "m03.md", "m04.md"} {
		_ = os.WriteFile(filepath.Join(dir, fn), []byte("stub"), 0o644)
	}
	cmd := newDagValidateCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("validate clean: %v", err)
	}
}

func TestDagValidateCmd_MissingDep(t *testing.T) {
	body := `m01|First|pending|m_nonexistent|m01.md|
`
	path := writeFixture(t, body)
	cmd := newDagValidateCmd()
	cmd.SetArgs([]string{"--path", path, "--milestone-dir", ""})
	err := cmd.Execute()
	if err == nil {
		t.Fatalf("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.code != exitCorrupt {
		t.Errorf("err code = %v, want exitCorrupt", err)
	}
}

// ---------------------------------------------------------------------------
// migrate
// ---------------------------------------------------------------------------

func TestDagMigrateCmd_HappyPath(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project
### Milestones
#### Milestone 1: First
Acceptance criteria:
- ok
#### Milestone 2: Second
Acceptance criteria:
- ok
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")

	cmd := newDagMigrateCmd()
	cmd.SetArgs([]string{
		"--inline-claude-md", claudeMD,
		"--milestone-dir", mDir,
	})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	if _, err := os.Stat(filepath.Join(mDir, "MANIFEST.cfg")); err != nil {
		t.Errorf("MANIFEST.cfg not created: %v", err)
	}
}

func TestDagMigrateCmd_AlreadyExists(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(claudeMD, []byte("# x\n#### Milestone 1: A\nAcceptance criteria:\n- ok\n"), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")
	_ = os.MkdirAll(mDir, 0o755)
	_ = os.WriteFile(filepath.Join(mDir, "MANIFEST.cfg"), []byte("# pre-existing\n"), 0o644)

	cmd := newDagMigrateCmd()
	cmd.SetArgs([]string{
		"--inline-claude-md", claudeMD,
		"--milestone-dir", mDir,
	})
	if err := cmd.Execute(); err != nil {
		t.Errorf("idempotent migrate should succeed silently, got %v", err)
	}
}

func TestDagMigrateCmd_RewritePointer(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project
### Milestones
#### Milestone 1: First
First content.

Acceptance criteria:
- ok
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")

	cmd := newDagMigrateCmd()
	cmd.SetArgs([]string{
		"--inline-claude-md", claudeMD,
		"--milestone-dir", mDir,
		"--rewrite-pointer",
	})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	out, _ := os.ReadFile(claudeMD)
	if !strings.Contains(string(out), "Milestones are managed as individual files") {
		t.Errorf("--rewrite-pointer did not insert pointer")
	}
}

// ---------------------------------------------------------------------------
// rewrite-pointer (standalone)
// ---------------------------------------------------------------------------

func TestDagRewritePointerCmd(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project
#### Milestone 1: First
content
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)
	cmd := newDagRewritePointerCmd()
	cmd.SetArgs([]string{"--inline-claude-md", claudeMD})
	if err := cmd.Execute(); err != nil {
		t.Fatal(err)
	}
	out, _ := os.ReadFile(claudeMD)
	if !strings.Contains(string(out), "Milestones are managed") {
		t.Errorf("pointer not inserted")
	}
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

func TestMapDagError(t *testing.T) {
	cases := []struct {
		err  error
		code int
	}{
		{dag.ErrNotFound, exitNotFound},
		{dag.ErrUnknownStatus, exitUsage},
		{dag.ErrInvalidTransition, exitUsage},
	}
	for _, c := range cases {
		got := mapDagError(c.err)
		var ec errExitCode
		if !errors.As(got, &ec) || ec.code != c.code {
			t.Errorf("mapDagError(%v) -> code %d, want %d", c.err, ec.code, c.code)
		}
	}
}

func TestLoadDagState_NoPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	if _, err := loadDagState(""); err == nil {
		t.Fatalf("expected error")
	}
}

// ---------------------------------------------------------------------------
// Error-path coverage for active / advance / validate when manifest is corrupt
// ---------------------------------------------------------------------------

// emptyManifestPath returns a path to an existing but empty manifest file.
// manifest.Load returns ErrEmpty for such files, which exercises the
// loadDagState error branch.
func emptyManifestPath(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	if err := os.WriteFile(path, []byte("# only comments\n"), 0o644); err != nil {
		t.Fatalf("write empty fixture: %v", err)
	}
	return path
}

func TestDagActiveCmd_LoadError(t *testing.T) {
	path := emptyManifestPath(t)
	cmd := newDagActiveCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err == nil {
		t.Errorf("expected error from loadDagState on empty manifest")
	}
}

func TestDagAdvanceCmd_LoadError(t *testing.T) {
	path := emptyManifestPath(t)
	cmd := newDagAdvanceCmd()
	cmd.SetArgs([]string{"--path", path, "m01", "done"})
	if err := cmd.Execute(); err == nil {
		t.Errorf("expected error from loadDagState on empty manifest")
	}
}

func TestDagValidateCmd_LoadError(t *testing.T) {
	path := emptyManifestPath(t)
	cmd := newDagValidateCmd()
	cmd.SetArgs([]string{"--path", path})
	if err := cmd.Execute(); err == nil {
		t.Errorf("expected error from loadDagState on empty manifest")
	}
}

func TestLoadDagState_EmptyManifest(t *testing.T) {
	path := emptyManifestPath(t)
	if _, err := loadDagState(path); err == nil {
		t.Fatalf("expected error for empty manifest")
	}
}

// ---------------------------------------------------------------------------
// mapDagError default branch — unrecognised error passes through as-is
// ---------------------------------------------------------------------------

func TestMapDagError_Default(t *testing.T) {
	sentinel := errors.New("some-other-error")
	got := mapDagError(sentinel)
	if got != sentinel {
		t.Errorf("mapDagError passthrough: got %v, want %v", got, sentinel)
	}
	var ec errExitCode
	if errors.As(got, &ec) {
		t.Errorf("mapDagError should not wrap unknown errors, got errExitCode")
	}
}

// ---------------------------------------------------------------------------
// defaultManifestName — the override (non-empty) branch
// ---------------------------------------------------------------------------

func TestDefaultManifestName(t *testing.T) {
	if got := defaultManifestName(""); got != "MANIFEST.cfg" {
		t.Errorf("empty override: got %q, want MANIFEST.cfg", got)
	}
	if got := defaultManifestName("custom.cfg"); got != "custom.cfg" {
		t.Errorf("non-empty override: got %q, want custom.cfg", got)
	}
}

// ---------------------------------------------------------------------------
// newDagMigrateCmd — $MILESTONE_DIR env-var fallback path
// ---------------------------------------------------------------------------

func TestDagMigrateCmd_MilestoneDirFromEnv(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	body := `# Project
### Milestones
#### Milestone 1: Alpha
Acceptance criteria:
- ok
`
	_ = os.WriteFile(claudeMD, []byte(body), 0o644)
	mDir := filepath.Join(dir, "env-milestones")
	t.Setenv("MILESTONE_DIR", mDir)

	cmd := newDagMigrateCmd()
	// --milestone-dir intentionally omitted so the env var is used.
	cmd.SetArgs([]string{"--inline-claude-md", claudeMD})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("migrate via $MILESTONE_DIR: %v", err)
	}
	if _, err := os.Stat(filepath.Join(mDir, "MANIFEST.cfg")); err != nil {
		t.Errorf("MANIFEST.cfg not created in env-specified dir: %v", err)
	}
}

// ---------------------------------------------------------------------------
// newDagMigrateCmd — --manifest-name flag surfaces in the already-exists msg
// ---------------------------------------------------------------------------

func TestDagMigrateCmd_AlreadyExists_CustomManifestName(t *testing.T) {
	dir := t.TempDir()
	claudeMD := filepath.Join(dir, "CLAUDE.md")
	_ = os.WriteFile(claudeMD, []byte("# x\n#### Milestone 1: A\nAcceptance criteria:\n- ok\n"), 0o644)
	mDir := filepath.Join(dir, ".claude/milestones")
	_ = os.MkdirAll(mDir, 0o755)
	const customName = "MY_MANIFEST.cfg"
	_ = os.WriteFile(filepath.Join(mDir, customName), []byte("# pre-existing\n"), 0o644)

	cmd := newDagMigrateCmd()
	cmd.SetArgs([]string{
		"--inline-claude-md", claudeMD,
		"--milestone-dir", mDir,
		"--manifest-name", customName,
	})
	// Should succeed silently (idempotent) and exercise defaultManifestName(override).
	if err := cmd.Execute(); err != nil {
		t.Errorf("idempotent migrate with custom manifest name should succeed, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// loadDagState — $MILESTONE_MANIFEST_FILE env fallback path
// ---------------------------------------------------------------------------

// TestLoadDagState_ViaEnv exercises the env-var fallback branch of
// resolveManifestPath inside loadDagState: when --path is empty the function
// must pick up $MILESTONE_MANIFEST_FILE.
func TestLoadDagState_ViaEnv(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	t.Setenv("MILESTONE_MANIFEST_FILE", path)

	s, err := loadDagState("") // empty path — must resolve from env
	if err != nil {
		t.Fatalf("loadDagState via $MILESTONE_MANIFEST_FILE: %v", err)
	}
	if s == nil {
		t.Fatal("loadDagState returned nil state")
	}
	// Sanity: the loaded state produces the same frontier as the --path variant.
	frontier := s.Frontier()
	if len(frontier) == 0 {
		t.Error("frontier should be non-empty for the dagCLIFixture")
	}
	ids := make([]string, 0, len(frontier))
	for _, e := range frontier {
		ids = append(ids, e.ID)
	}
	// dagCLIFixture: m01=done, m02=in_progress, m03=pending(dep m02), m04=pending(dep m01 done)
	// Frontier: m02 (actionable, dep m01 done) and m04 (actionable, dep m01 done).
	found := map[string]bool{}
	for _, id := range ids {
		found[id] = true
	}
	if !found["m02"] {
		t.Errorf("expected m02 in frontier; got %v", ids)
	}
	if !found["m04"] {
		t.Errorf("expected m04 in frontier; got %v", ids)
	}
}

// TestDagFrontierCmd_ViaEnv exercises the full frontier subcommand path
// without --path, relying solely on $MILESTONE_MANIFEST_FILE.
func TestDagFrontierCmd_ViaEnv(t *testing.T) {
	path := writeFixture(t, dagCLIFixture)
	t.Setenv("MILESTONE_MANIFEST_FILE", path)

	cmd := newDagFrontierCmd()
	cmd.SetArgs([]string{}) // no --path
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("frontier via env: %v", err)
		}
	})
	if !strings.Contains(out, "m02") {
		t.Errorf("frontier via env: want m02 in output, got %q", out)
	}
	if !strings.Contains(out, "m04") {
		t.Errorf("frontier via env: want m04 in output, got %q", out)
	}
}
