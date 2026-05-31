package gates

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixedTime returns a stable timestamp used across writer tests so the
// asserted strings can hard-code the expected "Build Errors — YYYY-...".
func fixedTime() time.Time {
	t, _ := time.Parse(time.RFC3339, "2026-05-31T12:00:00Z")
	return t
}

func newWriter(t *testing.T) *FSErrorsWriter {
	t.Helper()
	dir := t.TempDir()
	return &FSErrorsWriter{
		ErrorsFile:       filepath.Join(dir, "BUILD_ERRORS.md"),
		RawErrorsFile:    filepath.Join(dir, "BUILD_RAW_ERRORS.txt"),
		UITestErrorsFile: filepath.Join(dir, "UI_TEST_ERRORS.md"),
	}
}

func TestFSErrorsWriter_Reset(t *testing.T) {
	w := newWriter(t)
	if err := os.WriteFile(w.ErrorsFile, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(w.RawErrorsFile, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.Reset()
	if _, err := os.Stat(w.ErrorsFile); !os.IsNotExist(err) {
		t.Errorf("BUILD_ERRORS.md not removed; err = %v", err)
	}
	if _, err := os.Stat(w.RawErrorsFile); !os.IsNotExist(err) {
		t.Errorf("BUILD_RAW_ERRORS.txt not removed; err = %v", err)
	}
}

func TestFSErrorsWriter_AnalyzeAndCompile_StructuralEquivalence(t *testing.T) {
	w := newWriter(t)
	now := fixedTime()
	w.Reset()
	w.WriteAnalyze("post-coder", "error TS2304: cannot find X", "full output 1\nerror TS2304: cannot find X\n", now)

	b, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatalf("read errors md: %v", err)
	}
	body := string(b)
	for _, want := range []string{
		"# Build Errors — 2026-05-31 12:00:00",
		"## Stage\npost-coder",
		"## Analyze Errors",
		"error TS2304: cannot find X",
		"## Full Analyze Output",
		"full output 1",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("BUILD_ERRORS.md missing expected substring %q\nbody:\n%s", want, body)
		}
	}

	raw, err := os.ReadFile(w.RawErrorsFile)
	if err != nil {
		t.Fatalf("read raw errors: %v", err)
	}
	if string(raw) != "error TS2304: cannot find X\n" {
		t.Errorf("BUILD_RAW_ERRORS.txt = %q, want analyze-truncate single trailing newline", string(raw))
	}

	// Now follow up with compile errors — the BUILD_RAW_ERRORS.txt must
	// APPEND (not truncate). The bash side uses `>` for analyze, `>>` for
	// compile (gates_phases.sh:20 vs :116).
	w.WriteCompile("post-coder", "ERROR: link failed at line 42", now)
	raw2, err := os.ReadFile(w.RawErrorsFile)
	if err != nil {
		t.Fatalf("read raw errors after compile: %v", err)
	}
	wantRaw := "error TS2304: cannot find X\nERROR: link failed at line 42\n"
	if string(raw2) != wantRaw {
		t.Errorf("BUILD_RAW_ERRORS.txt after compile = %q, want %q (append mode)", string(raw2), wantRaw)
	}

	b2, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatalf("read errors md after compile: %v", err)
	}
	body2 := string(b2)
	if !strings.Contains(body2, "## Compile Errors") {
		t.Errorf("BUILD_ERRORS.md missing ## Compile Errors after compile write\nbody:\n%s", body2)
	}
	if !strings.Contains(body2, "ERROR: link failed at line 42") {
		t.Errorf("BUILD_ERRORS.md missing compile error line\nbody:\n%s", body2)
	}
	// Critical bash parity: when both analyze and compile fire, there is
	// only ONE # Build Errors H1 (the compile writer must not double-write
	// the header).
	if strings.Count(body2, "# Build Errors — ") != 1 {
		t.Errorf("BUILD_ERRORS.md has %d H1 headers, want 1\nbody:\n%s", strings.Count(body2, "# Build Errors — "), body2)
	}
}

// TestFSErrorsWriter_CompileWritesH1WhenAnalyzePassed: when only compile
// fails (analyze passed), the compile writer is responsible for the H1.
func TestFSErrorsWriter_CompileWritesH1WhenAnalyzePassed(t *testing.T) {
	w := newWriter(t)
	w.Reset()
	w.WriteCompile("post-coder", "ERROR: link fail", fixedTime())
	b, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatalf("read errors md: %v", err)
	}
	body := string(b)
	if !strings.HasPrefix(body, "# Build Errors — ") {
		t.Errorf("compile-only output missing H1 prefix\nbody:\n%s", body)
	}
	if !strings.Contains(body, "## Stage\npost-coder") {
		t.Errorf("compile-only output missing ## Stage block")
	}
}

func TestFSErrorsWriter_Timeout(t *testing.T) {
	w := newWriter(t)
	w.WriteTimeout("post-coder", 600*time.Second, fixedTime())
	b, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatalf("read errors md: %v", err)
	}
	body := string(b)
	for _, want := range []string{
		"# Build Errors — 2026-05-31 12:00:00",
		"## Stage\npost-coder",
		"## Gate Timeout",
		"The build gate exceeded the overall timeout of 600s.",
		"BUILD_GATE_TIMEOUT in pipeline.conf.",
	} {
		if !strings.Contains(body, want) {
			t.Errorf("timeout BUILD_ERRORS.md missing %q\nbody:\n%s", want, body)
		}
	}
}

// TestFSErrorsWriter_ClearOnPass: passing gate removes both stale files.
func TestFSErrorsWriter_ClearOnPass(t *testing.T) {
	w := newWriter(t)
	if err := os.WriteFile(w.ErrorsFile, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(w.UITestErrorsFile, []byte("stale"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.ClearOnPass()
	if _, err := os.Stat(w.ErrorsFile); !os.IsNotExist(err) {
		t.Errorf("BUILD_ERRORS.md not cleared; err = %v", err)
	}
	if _, err := os.Stat(w.UITestErrorsFile); !os.IsNotExist(err) {
		t.Errorf("UI_TEST_ERRORS.md not cleared; err = %v", err)
	}
}

// TestNoopErrorsWriter_IsSilent.
func TestNoopErrorsWriter_IsSilent(t *testing.T) {
	w := NoopErrorsWriter{}
	w.Reset()
	w.WriteAnalyze("x", "y", "z", time.Now())
	w.WriteCompile("x", "y", time.Now())
	w.WriteConstraints("body")
	w.WriteTimeout("x", time.Second, time.Now())
	w.ClearOnPass()
	// Just exercising the no-op surface — assertion is that no panic fires.
}

// TestFSErrorsWriter_ResetIsIdempotent_OnMissingFiles.
func TestFSErrorsWriter_ResetIsIdempotent_OnMissingFiles(t *testing.T) {
	dir := t.TempDir()
	w := &FSErrorsWriter{
		ErrorsFile:    filepath.Join(dir, "does-not-exist.md"),
		RawErrorsFile: filepath.Join(dir, "also-missing.txt"),
	}
	w.Reset() // must not panic
}

// TestFSErrorsWriter_WriteUIFailure_FreshFile asserts the m31.2 failure-path
// shape when BUILD_ERRORS.md does not yet exist (no analyze/compile section
// before it).
func TestFSErrorsWriter_WriteUIFailure_FreshFile(t *testing.T) {
	w := newWriter(t)
	w.WriteUIFailure("post-coder", "npx playwright test", "Test timed out\n", 124, fixedTime())

	// BUILD_RAW_ERRORS.txt — truncate-mode, single trailing newline.
	raw, err := os.ReadFile(w.RawErrorsFile)
	if err != nil {
		t.Fatalf("read raw: %v", err)
	}
	if string(raw) != "Test timed out\n\n" {
		t.Errorf("raw stream = %q, want %q", string(raw), "Test timed out\n\n")
	}

	// UI_TEST_ERRORS.md — fixed-shape heredoc.
	uiBody, err := os.ReadFile(w.UITestErrorsFile)
	if err != nil {
		t.Fatalf("read ui errors: %v", err)
	}
	for _, want := range []string{
		"# UI Test Errors — 2026-05-31 12:00:00\n",
		"## Stage\npost-coder\n\n",
		"## UI Test Command\n`npx playwright test`\n\n",
		"## Exit Code\n124\n\n",
		"## Output (last 100 lines)\n",
		"```\nTest timed out\n\n```\n",
	} {
		if !strings.Contains(string(uiBody), want) {
			t.Errorf("UI_TEST_ERRORS.md missing %q\nbody:\n%s", want, string(uiBody))
		}
	}

	// BUILD_ERRORS.md — H1 created since file didn't exist, plus ## UI Test Failures.
	be, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatalf("read build errors: %v", err)
	}
	for _, want := range []string{
		"# Build Errors — 2026-05-31 12:00:00\n",
		"## Stage\npost-coder\n\n",
		"## UI Test Failures\n",
		"Command: `npx playwright test`\n",
		"Exit code: 124\n\n",
	} {
		if !strings.Contains(string(be), want) {
			t.Errorf("BUILD_ERRORS.md missing %q\nbody:\n%s", want, string(be))
		}
	}
}

// TestFSErrorsWriter_WriteUIFailure_AppendsToExistingBuildErrors asserts the
// case where BUILD_ERRORS.md already exists (analyze or compile wrote it
// earlier in the same gate run): the new ## UI Test Failures section
// appends without re-emitting the H1 header.
func TestFSErrorsWriter_WriteUIFailure_AppendsToExistingBuildErrors(t *testing.T) {
	w := newWriter(t)
	existing := "# Build Errors — 2026-05-31 12:00:00\n## Stage\npost-coder\n\n## Compile Errors\n```\nfoo\n```\n"
	if err := os.WriteFile(w.ErrorsFile, []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}
	w.WriteUIFailure("post-coder", "playwright test", "AssertionError", 1, fixedTime())

	be, err := os.ReadFile(w.ErrorsFile)
	if err != nil {
		t.Fatal(err)
	}
	body := string(be)
	if !strings.HasPrefix(body, existing) {
		t.Errorf("existing content not preserved; body:\n%s", body)
	}
	if !strings.Contains(body, "## UI Test Failures\n") {
		t.Errorf("missing ## UI Test Failures append; body:\n%s", body)
	}
	// H1 must appear exactly once (not duplicated by the append).
	if strings.Count(body, "# Build Errors —") != 1 {
		t.Errorf("H1 appears %d times, want 1", strings.Count(body, "# Build Errors —"))
	}
}

// TestFSErrorsWriter_WriteUIDiagnosis_OnlyAppendsWhenFilesExist asserts the
// bash _ui_write_gate_diagnosis tail behavior — the diagnosis block is only
// appended to files that already exist; missing files are not auto-created.
func TestFSErrorsWriter_WriteUIDiagnosis_OnlyAppendsWhenFilesExist(t *testing.T) {
	w := newWriter(t)
	block := "\n## UI Gate Diagnosis\n- Timeout class: none\n"

	// Neither file exists → diagnosis is a no-op.
	w.WriteUIDiagnosis(block)
	if _, err := os.Stat(w.ErrorsFile); !os.IsNotExist(err) {
		t.Error("BUILD_ERRORS.md auto-created by WriteUIDiagnosis; want no-op")
	}
	if _, err := os.Stat(w.UITestErrorsFile); !os.IsNotExist(err) {
		t.Error("UI_TEST_ERRORS.md auto-created by WriteUIDiagnosis; want no-op")
	}

	// Create the files, then call again — diagnosis should append to both.
	if err := os.WriteFile(w.ErrorsFile, []byte("existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(w.UITestErrorsFile, []byte("existing"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.WriteUIDiagnosis(block)
	be, _ := os.ReadFile(w.ErrorsFile)
	if !strings.Contains(string(be), block) {
		t.Errorf("BUILD_ERRORS.md missing diagnosis after append; body:\n%s", string(be))
	}
	ui, _ := os.ReadFile(w.UITestErrorsFile)
	if !strings.Contains(string(ui), block) {
		t.Errorf("UI_TEST_ERRORS.md missing diagnosis after append; body:\n%s", string(ui))
	}
}

// TestFSErrorsWriter_WriteUIDiagnosis_EmptyBlockIsNoop.
func TestFSErrorsWriter_WriteUIDiagnosis_EmptyBlockIsNoop(t *testing.T) {
	w := newWriter(t)
	if err := os.WriteFile(w.UITestErrorsFile, []byte("baseline"), 0o644); err != nil {
		t.Fatal(err)
	}
	w.WriteUIDiagnosis("")
	got, _ := os.ReadFile(w.UITestErrorsFile)
	if string(got) != "baseline" {
		t.Errorf("empty diagnosis modified file; got %q, want %q", string(got), "baseline")
	}
}

// TestTailLines exercises the head/tail helper used by WriteUIFailure.
func TestTailLines(t *testing.T) {
	if got := tailLines("a\nb\nc", 2); got != "b\nc" {
		t.Errorf("tailLines(2) = %q, want %q", got, "b\nc")
	}
	if got := tailLines("a\nb\nc", 100); got != "a\nb\nc" {
		t.Errorf("tailLines(100) = %q, want unchanged", got)
	}
	if got := tailLines("", 5); got != "" {
		t.Errorf("tailLines(empty) = %q, want empty", got)
	}
}

// TestFSErrorsWriter_NilReceiverIsSafe covers the nil-guard branches.
func TestFSErrorsWriter_NilReceiverIsSafe(t *testing.T) {
	var w *FSErrorsWriter
	w.WriteUIFailure("x", "cmd", "out", 1, fixedTime()) // must not panic
	w.WriteUIDiagnosis("block")                         // must not panic
}
