package gates

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	terr "github.com/geoffgodwin/tekhton/internal/errors"
)

// ErrorsWriter owns the BUILD_ERRORS.md + BUILD_RAW_ERRORS.txt write
// surface. Phases call WriteAnalyze / WriteCompile to append their
// classified failure sections; BuildGate calls Reset at the top of every
// gate run, ClearOnPass at the end of a successful run, and WriteTimeout
// when the omnibus budget runs out.
//
// Two production implementations live here:
//   - FSErrorsWriter writes to BUILD_ERRORS_FILE / BUILD_RAW_ERRORS_FILE on
//     disk. Used at the CLI seam.
//   - NoopErrorsWriter discards every write. Used by direct-construction
//     tests that don't care about disk state.
type ErrorsWriter interface {
	// Reset removes stale artifacts from previous runs. Idempotent on a
	// clean working tree (missing files are not an error).
	Reset()

	// WriteAnalyze writes the analyze phase's raw stream (truncate mode)
	// and BUILD_ERRORS.md section. Called by AnalyzePhase on failure.
	WriteAnalyze(stageLabel string, rawErrors, fullOutput string, now time.Time)

	// WriteCompile appends the compile phase's raw stream (append mode so
	// the analyze stream survives) and BUILD_ERRORS.md section. Called by
	// CompilePhase on failure.
	WriteCompile(stageLabel string, rawErrors string, now time.Time)

	// WriteConstraints appends the dependency-constraint violation section
	// to BUILD_ERRORS.md. Called by ConstraintsPhase on failure.
	WriteConstraints(output string)

	// WriteTimeout writes the synthetic ## Gate Timeout BUILD_ERRORS.md
	// when the omnibus budget expires.
	WriteTimeout(stageLabel string, budget time.Duration, now time.Time)

	// WriteUIFailure is called by UIPhase on failure. Truncates
	// BUILD_RAW_ERRORS.txt with the UI output, writes a fresh
	// UI_TEST_ERRORS.md, and appends a ## UI Test Failures section to
	// BUILD_ERRORS.md (creating the file header if it does not yet exist).
	WriteUIFailure(stageLabel, uiTestCmd, output string, exitCode int, now time.Time)

	// WriteUIDiagnosis appends a ## UI Gate Diagnosis block to
	// UI_TEST_ERRORS.md AND BUILD_ERRORS.md. Called by UIPhase after
	// WriteUIFailure so the diagnosis block lands at the end of both files.
	WriteUIDiagnosis(block string)

	// ClearOnPass removes BUILD_ERRORS.md and UI_TEST_ERRORS.md after a
	// fully-passing gate run. Called by BuildGate.Run on success.
	ClearOnPass()
}

// FSErrorsWriter is the production implementation that writes to the env-
// configured BUILD_ERRORS_FILE / BUILD_RAW_ERRORS_FILE paths.
type FSErrorsWriter struct {
	ErrorsFile          string // BUILD_ERRORS_FILE (default .tekhton/BUILD_ERRORS.md)
	RawErrorsFile       string // BUILD_RAW_ERRORS_FILE (default .tekhton/BUILD_RAW_ERRORS.txt)
	UITestErrorsFile    string // UI_TEST_ERRORS_FILE (default .tekhton/UI_TEST_ERRORS.md)
	UIValidationReport  string // UI_VALIDATION_REPORT_FILE (default .tekhton/UI_VALIDATION_REPORT.md, m31.2)
	compileWriteInRound bool   // true once WriteCompile fires this round (controls H1)
	analyzeWriteInRound bool   // true once WriteAnalyze fires this round (controls compile append vs truncate)
}

// Reset removes the per-round artifacts. Mirrors the rm -f pair at the
// top of run_build_gate.
func (w *FSErrorsWriter) Reset() {
	if w == nil {
		return
	}
	w.compileWriteInRound = false
	w.analyzeWriteInRound = false
	if w.ErrorsFile != "" {
		_ = os.Remove(w.ErrorsFile)
	}
	if w.RawErrorsFile != "" {
		_ = os.Remove(w.RawErrorsFile)
	}
}

// WriteAnalyze writes the analyze phase's BUILD_ERRORS.md + BUILD_RAW_ERRORS.txt.
//
// Critical bash parity:
//   - printf '%s\n' "$analyze_errors" > "$BUILD_RAW_ERRORS_FILE" — truncate
//     mode with a single trailing newline.
//   - The markdown section opens with the annotated header (timestamp +
//     stage + classification block) followed by ## Analyze Errors and
//     ## Full Analyze Output fenced code blocks.
func (w *FSErrorsWriter) WriteAnalyze(stageLabel string, rawErrors, fullOutput string, now time.Time) {
	if w == nil {
		return
	}
	if w.RawErrorsFile != "" {
		// Truncate: analyze is the FIRST phase; subsequent compile writes
		// append on top of this.
		_ = writeFile(w.RawErrorsFile, []byte(rawErrors+"\n"), false)
	}
	if w.ErrorsFile == "" {
		return
	}
	ts := now.Format("2006-01-02 15:04:05")
	var b strings.Builder
	b.WriteString(terr.AnnotateBuildErrors(rawErrors, stageLabel, ts))
	b.WriteString("\n## Analyze Errors\n")
	b.WriteString("```\n")
	b.WriteString(rawErrors)
	b.WriteString("\n```\n")
	b.WriteString("\n## Full Analyze Output\n")
	b.WriteString("```\n")
	b.WriteString(fullOutput)
	b.WriteString("\n```\n")
	_ = writeFile(w.ErrorsFile, []byte(b.String()), false)
	w.analyzeWriteInRound = true
}

// WriteCompile appends the compile phase's BUILD_ERRORS.md section.
//
// Critical bash parity:
//   - printf '%s\n' "$compile_errors" >> "$BUILD_RAW_ERRORS_FILE" — append
//     mode so the analyze stream survives below.
//   - If BUILD_ERRORS_FILE does not yet exist (analyze phase passed),
//     write the H1 + ## Stage header first. Otherwise append directly.
//   - The compile section includes its own classification block titled
//     "## Error Classification (compile)" listing each unique (cat, safety,
//     diagnosis) triple from the registry.
func (w *FSErrorsWriter) WriteCompile(stageLabel string, rawErrors string, now time.Time) {
	if w == nil {
		return
	}
	if w.RawErrorsFile != "" {
		_ = writeFile(w.RawErrorsFile, []byte(rawErrors+"\n"), true)
	}
	if w.ErrorsFile == "" {
		return
	}
	var b strings.Builder
	if !w.analyzeWriteInRound {
		if _, err := os.Stat(w.ErrorsFile); err != nil {
			ts := now.Format("2006-01-02 15:04:05")
			fmt.Fprintf(&b, "# Build Errors — %s\n", ts)
			b.WriteString("## Stage\n")
			b.WriteString(stageLabel + "\n\n")
		}
	}
	classifications := terr.ClassifyAll(rawErrors)
	if len(classifications) > 0 {
		b.WriteString("\n## Error Classification (compile)\n")
		for _, r := range classifications {
			fmt.Fprintf(&b, "- **%s** (%s): %s\n", r.Category, r.Safety, r.Diagnosis)
		}
	}
	b.WriteString("\n## Compile Errors\n")
	b.WriteString("```\n")
	b.WriteString(rawErrors)
	b.WriteString("\n```\n")
	_ = writeFile(w.ErrorsFile, []byte(b.String()), true)
	w.compileWriteInRound = true
}

// WriteConstraints appends the dependency-constraint violation section.
func (w *FSErrorsWriter) WriteConstraints(output string) {
	if w == nil || w.ErrorsFile == "" {
		return
	}
	var b strings.Builder
	b.WriteString("\n## Dependency Constraint Violations\n")
	b.WriteString("```\n")
	b.WriteString(output)
	b.WriteString("\n```\n")
	_ = writeFile(w.ErrorsFile, []byte(b.String()), true)
}

// WriteTimeout writes the synthetic ## Gate Timeout BUILD_ERRORS.md.
// Always truncates — a timeout is a terminal failure, no other phases
// produced output yet.
func (w *FSErrorsWriter) WriteTimeout(stageLabel string, budget time.Duration, now time.Time) {
	if w == nil || w.ErrorsFile == "" {
		return
	}
	ts := now.Format("2006-01-02 15:04:05")
	var b strings.Builder
	fmt.Fprintf(&b, "# Build Errors — %s\n", ts)
	b.WriteString("## Stage\n")
	b.WriteString(stageLabel + "\n\n")
	b.WriteString("## Gate Timeout\n")
	fmt.Fprintf(&b, "The build gate exceeded the overall timeout of %ds.\n", int(budget.Seconds()))
	b.WriteString("This typically indicates a hanging subprocess (e.g., static analysis,\n")
	b.WriteString("UI server, or headless browser). Check BUILD_GATE_TIMEOUT in pipeline.conf.\n")
	_ = writeFile(w.ErrorsFile, []byte(b.String()), false)
}

// WriteUIFailure writes the failure-path artifacts for the UI gate:
//   - BUILD_RAW_ERRORS.txt truncated to the captured output (single
//     trailing newline, matches `printf '%s\n' "$out" > ...` from bash).
//   - UI_TEST_ERRORS.md is rewritten from scratch with the fixed-shape
//     bash heredoc (H1 + Stage + UI Test Command + Exit Code + Output).
//   - BUILD_ERRORS.md gets a ## UI Test Failures section appended; the
//     `# Build Errors — TS` header is created only when the file does
//     not yet exist (analyze/compile may have written it already).
//
// Byte-identical to the bash gates_ui.sh failure path.
func (w *FSErrorsWriter) WriteUIFailure(stageLabel, uiTestCmd, output string, exitCode int, now time.Time) {
	if w == nil {
		return
	}
	if w.RawErrorsFile != "" {
		_ = writeFile(w.RawErrorsFile, []byte(output+"\n"), false)
	}
	ts := now.Format("2006-01-02 15:04:05")
	tailed := tailLines(output, 100)

	if w.UITestErrorsFile != "" {
		var b strings.Builder
		fmt.Fprintf(&b, "# UI Test Errors — %s\n", ts)
		b.WriteString("## Stage\n")
		b.WriteString(stageLabel + "\n\n")
		b.WriteString("## UI Test Command\n")
		fmt.Fprintf(&b, "`%s`\n\n", uiTestCmd)
		b.WriteString("## Exit Code\n")
		fmt.Fprintf(&b, "%d\n\n", exitCode)
		b.WriteString("## Output (last 100 lines)\n")
		b.WriteString("```\n")
		b.WriteString(tailed)
		b.WriteString("\n```\n")
		_ = writeFile(w.UITestErrorsFile, []byte(b.String()), false)
	}

	if w.ErrorsFile != "" {
		var b strings.Builder
		if _, err := os.Stat(w.ErrorsFile); err != nil {
			fmt.Fprintf(&b, "# Build Errors — %s\n", ts)
			b.WriteString("## Stage\n")
			b.WriteString(stageLabel + "\n\n")
		}
		b.WriteString("## UI Test Failures\n")
		fmt.Fprintf(&b, "Command: `%s`\n", uiTestCmd)
		fmt.Fprintf(&b, "Exit code: %d\n\n", exitCode)
		b.WriteString("```\n")
		b.WriteString(tailed)
		b.WriteString("\n```\n")
		_ = writeFile(w.ErrorsFile, []byte(b.String()), true)
	}
}

// WriteUIDiagnosis appends a ## UI Gate Diagnosis block to UI_TEST_ERRORS.md
// AND BUILD_ERRORS.md when those files exist. Mirrors the bash
// _ui_write_gate_diagnosis tail behavior — the block is only appended when
// the target file is already present, so a missing UI_TEST_ERRORS.md does
// not get auto-created here.
func (w *FSErrorsWriter) WriteUIDiagnosis(block string) {
	if w == nil || block == "" {
		return
	}
	if w.UITestErrorsFile != "" {
		if _, err := os.Stat(w.UITestErrorsFile); err == nil {
			_ = writeFile(w.UITestErrorsFile, []byte(block), true)
		}
	}
	if w.ErrorsFile != "" {
		if _, err := os.Stat(w.ErrorsFile); err == nil {
			_ = writeFile(w.ErrorsFile, []byte(block), true)
		}
	}
}

// tailLines returns the last n newline-separated lines of s. Mirrors the
// bash `echo "$out" | tail -100` invocation in the UI gate failure path.
func tailLines(s string, n int) string {
	if s == "" {
		return ""
	}
	lines := strings.Split(s, "\n")
	if len(lines) <= n {
		return s
	}
	return strings.Join(lines[len(lines)-n:], "\n")
}

// ClearOnPass removes BUILD_ERRORS.md and UI_TEST_ERRORS.md on a fully
// passing gate. Mirrors the tail rm calls in run_build_gate.
func (w *FSErrorsWriter) ClearOnPass() {
	if w == nil {
		return
	}
	if w.ErrorsFile != "" {
		_ = os.Remove(w.ErrorsFile)
	}
	if w.UITestErrorsFile != "" {
		_ = os.Remove(w.UITestErrorsFile)
	}
}

// writeFile centralises the directory-creation + os.WriteFile pattern.
// append=true uses O_APPEND|O_CREATE|O_WRONLY; append=false uses
// O_TRUNC|O_CREATE|O_WRONLY. mkdir-on-write so callers don't need to
// preset the directory.
func writeFile(path string, body []byte, append bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	flag := os.O_WRONLY | os.O_CREATE | os.O_TRUNC
	if append {
		flag = os.O_WRONLY | os.O_CREATE | os.O_APPEND
	}
	f, err := os.OpenFile(path, flag, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write(body); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}

// NoopErrorsWriter is the discard sink used by direct-construction tests
// that don't care about disk state. Every method is a no-op.
type NoopErrorsWriter struct{}

// Reset implements ErrorsWriter.
func (NoopErrorsWriter) Reset() {}

// WriteAnalyze implements ErrorsWriter.
func (NoopErrorsWriter) WriteAnalyze(string, string, string, time.Time) {}

// WriteCompile implements ErrorsWriter.
func (NoopErrorsWriter) WriteCompile(string, string, time.Time) {}

// WriteConstraints implements ErrorsWriter.
func (NoopErrorsWriter) WriteConstraints(string) {}

// WriteTimeout implements ErrorsWriter.
func (NoopErrorsWriter) WriteTimeout(string, time.Duration, time.Time) {}

// WriteUIFailure implements ErrorsWriter.
func (NoopErrorsWriter) WriteUIFailure(string, string, string, int, time.Time) {}

// WriteUIDiagnosis implements ErrorsWriter.
func (NoopErrorsWriter) WriteUIDiagnosis(string) {}

// ClearOnPass implements ErrorsWriter.
func (NoopErrorsWriter) ClearOnPass() {}
