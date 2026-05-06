package main

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/manifest"
)

const cliFixture = `# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|done||m01.md|p1
m02|Second|in_progress|m01|m02.md|p1
m03|Third|pending|m02|m03.md|p2
`

func writeFixture(t *testing.T, body string) string {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "MANIFEST.cfg")
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	return path
}

// captureStdout runs fn while os.Stdout is redirected to a pipe, returning
// the captured bytes. Mirrors the pattern used by orchestrate_test.go.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	old := os.Stdout
	os.Stdout = w
	done := make(chan []byte)
	go func() {
		buf, _ := io.ReadAll(r)
		done <- buf
	}()
	fn()
	w.Close()
	os.Stdout = old
	return string(<-done)
}

// ---------------------------------------------------------------------------
// resolveManifestPath
// ---------------------------------------------------------------------------

func TestResolveManifestPath_Explicit(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "/env/MANIFEST.cfg")
	if got := resolveManifestPath("/explicit/MANIFEST.cfg"); got != "/explicit/MANIFEST.cfg" {
		t.Errorf("got %q, want explicit", got)
	}
}

func TestResolveManifestPath_EnvFallback(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "/env/MANIFEST.cfg")
	if got := resolveManifestPath(""); got != "/env/MANIFEST.cfg" {
		t.Errorf("got %q, want env value", got)
	}
}

func TestResolveManifestPath_BothEmpty(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	if got := resolveManifestPath(""); got != "" {
		t.Errorf("got %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// formatEntryLine + lookupEntryField
// ---------------------------------------------------------------------------

func TestFormatEntryLine_AllFields(t *testing.T) {
	e := &manifest.Entry{
		ID: "m04", Title: "Fourth", Status: "pending",
		Depends: []string{"m02", "m03"}, File: "m04.md", Group: "p2",
	}
	got := formatEntryLine(e)
	want := "m04|Fourth|pending|m02,m03|m04.md|p2"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestFormatEntryLine_EmptyDeps(t *testing.T) {
	e := &manifest.Entry{ID: "m01", Title: "First", Status: "done", File: "m01.md", Group: "p1"}
	got := formatEntryLine(e)
	want := "m01|First|done||m01.md|p1"
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestLookupEntryField_All(t *testing.T) {
	e := &manifest.Entry{
		ID: "m04", Title: "Fourth", Status: "pending",
		Depends: []string{"m02", "m03"}, File: "m04.md", Group: "p2",
	}
	cases := map[string]string{
		"id":             "m04",
		"title":          "Fourth",
		"status":         "pending",
		"depends":        "m02,m03",
		"depends_on":     "m02,m03",
		"file":           "m04.md",
		"group":          "p2",
		"parallel_group": "p2",
		"STATUS":         "pending",
	}
	for field, want := range cases {
		if got := lookupEntryField(e, field); got != want {
			t.Errorf("lookupEntryField(%q) = %q, want %q", field, got, want)
		}
	}
}

func TestLookupEntryField_Unknown(t *testing.T) {
	e := &manifest.Entry{ID: "m01"}
	if got := lookupEntryField(e, "nope"); got != "" {
		t.Errorf("unknown field: got %q, want empty", got)
	}
}

// ---------------------------------------------------------------------------
// list subcommand
// ---------------------------------------------------------------------------

func TestManifestListCmd_PipeFormat(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestListCmd()
	cmd.SetArgs([]string{"--path", path})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	want := "m01|First|done||m01.md|p1\nm02|Second|in_progress|m01|m02.md|p1\nm03|Third|pending|m02|m03.md|p2\n"
	if out != want {
		t.Errorf("got %q, want %q", out, want)
	}
}

func TestManifestListCmd_JSON(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestListCmd()
	cmd.SetArgs([]string{"--path", path, "--json"})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	if !strings.Contains(out, `"proto": "tekhton.manifest.v1"`) {
		t.Errorf("missing proto envelope: %s", out)
	}
	if !strings.Contains(out, `"id": "m02"`) || !strings.Contains(out, `"status": "in_progress"`) {
		t.Errorf("missing m02/in_progress: %s", out)
	}
}

func TestManifestListCmd_NotFound_ExitCode1(t *testing.T) {
	cmd := newManifestListCmd()
	cmd.SetArgs([]string{"--path", filepath.Join(t.TempDir(), "missing.cfg")})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

func TestManifestListCmd_MissingPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	cmd := newManifestListCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when path is unset")
	}
}

// ---------------------------------------------------------------------------
// get subcommand
// ---------------------------------------------------------------------------

func TestManifestGetCmd_FullEntry(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestGetCmd()
	cmd.SetArgs([]string{"--path", path, "m02"})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	want := "m02|Second|in_progress|m01|m02.md|p1\n"
	if out != want {
		t.Errorf("got %q, want %q", out, want)
	}
}

func TestManifestGetCmd_SingleField(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestGetCmd()
	cmd.SetArgs([]string{"--path", path, "--field", "status", "m02"})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	if strings.TrimSpace(out) != "in_progress" {
		t.Errorf("got %q, want in_progress", strings.TrimSpace(out))
	}
}

func TestManifestGetCmd_UnknownID_ExitCode1(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestGetCmd()
	cmd.SetArgs([]string{"--path", path, "m999"})
	cmd.SetOut(&bytes.Buffer{})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for unknown id")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

func TestManifestGetCmd_EmptyField_ExitCode1(t *testing.T) {
	// Group is empty for a row written without one — exits 1.
	path := writeFixture(t, "m01|Title|done||x.md|\n")
	cmd := newManifestGetCmd()
	cmd.SetArgs([]string{"--path", path, "--field", "group", "m01"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for empty field")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

// ---------------------------------------------------------------------------
// set-status subcommand
// ---------------------------------------------------------------------------

func TestManifestSetStatusCmd_Updates(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestSetStatusCmd()
	cmd.SetArgs([]string{"--path", path, "m03", "done"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	m, err := manifest.Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	e, _ := m.Get("m03")
	if e.Status != "done" {
		t.Errorf("status = %q, want done", e.Status)
	}
}

func TestManifestSetStatusCmd_UnknownID(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestSetStatusCmd()
	cmd.SetArgs([]string{"--path", path, "m999", "done"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for unknown id")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

func TestManifestSetStatusCmd_PipeInStatus(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestSetStatusCmd()
	cmd.SetArgs([]string{"--path", path, "m01", "bad|value"})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for pipe in status")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitUsage {
		t.Errorf("err = %v, want errExitCode{exitUsage}", err)
	}
}

func TestManifestSetStatusCmd_PreservesComments(t *testing.T) {
	original := `# header
# fields

m01|First|pending||m01.md|p1
m02|Second|pending|m01|m02.md|p1
`
	path := writeFixture(t, original)
	cmd := newManifestSetStatusCmd()
	cmd.SetArgs([]string{"--path", path, "m01", "done"})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	got, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(got), "# header\n# fields\n\n") {
		t.Errorf("comments/blanks not preserved: %q", string(got))
	}
	if !strings.Contains(string(got), "m01|First|done||m01.md|p1") {
		t.Errorf("status not updated: %q", string(got))
	}
}

// ---------------------------------------------------------------------------
// frontier subcommand
// ---------------------------------------------------------------------------

func TestManifestFrontierCmd(t *testing.T) {
	path := writeFixture(t, cliFixture)
	cmd := newManifestFrontierCmd()
	cmd.SetArgs([]string{"--path", path})
	out := captureStdout(t, func() {
		if err := cmd.Execute(); err != nil {
			t.Fatalf("Execute: %v", err)
		}
	})
	// m01 is done → excluded; m02 in_progress with dep m01=done → included;
	// m03 pending with dep m02=in_progress → excluded.
	if strings.TrimSpace(out) != "m02" {
		t.Errorf("got %q, want m02", strings.TrimSpace(out))
	}
}

func TestManifestFrontierCmd_NotFound(t *testing.T) {
	cmd := newManifestFrontierCmd()
	cmd.SetArgs([]string{"--path", filepath.Join(t.TempDir(), "missing.cfg")})
	err := cmd.Execute()
	var ec errExitCode
	if err == nil || !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
}

// ---------------------------------------------------------------------------
// mapManifestError
// ---------------------------------------------------------------------------

func TestMapManifestError(t *testing.T) {
	cases := []struct {
		name     string
		err      error
		wantCode int
	}{
		{"NotFound", manifest.ErrNotFound, exitNotFound},
		{"Empty", manifest.ErrEmpty, exitNotFound},
		{"InvalidField", manifest.ErrInvalidField, exitCorrupt},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			out := mapManifestError(tc.err)
			var ec errExitCode
			if !errors.As(out, &ec) || ec.ExitCode() != tc.wantCode {
				t.Errorf("got %v (code=%d), want exit %d", out, exitCodeOrZero(out), tc.wantCode)
			}
		})
	}
}

func TestMapManifestError_Passthrough(t *testing.T) {
	other := errors.New("other failure")
	if got := mapManifestError(other); got != other {
		t.Errorf("non-sentinel error should pass through unchanged, got %v", got)
	}
}

func exitCodeOrZero(err error) int {
	var ec errExitCode
	if errors.As(err, &ec) {
		return ec.ExitCode()
	}
	return 0
}

// ---------------------------------------------------------------------------
// missing-path branches for get / set-status / frontier
// ---------------------------------------------------------------------------

func TestManifestGetCmd_MissingPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	cmd := newManifestGetCmd()
	cmd.SetArgs([]string{"m01"})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when path is unset")
	}
}

func TestManifestSetStatusCmd_MissingPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	cmd := newManifestSetStatusCmd()
	cmd.SetArgs([]string{"m01", "done"})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when path is unset")
	}
}

func TestManifestFrontierCmd_MissingPath(t *testing.T) {
	t.Setenv("MILESTONE_MANIFEST_FILE", "")
	cmd := newManifestFrontierCmd()
	cmd.SetArgs([]string{})
	if err := cmd.Execute(); err == nil {
		t.Error("expected error when path is unset")
	}
}
