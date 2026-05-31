package main

import (
	"bytes"
	stderrs "errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func runDiagnose(t *testing.T, stdin string, args ...string) (out, errOut string, exitCode int) {
	t.Helper()
	cmd := newRootCmd()
	cmd.SetArgs(append([]string{"diagnose"}, args...))
	var stdoutBuf, stderrBuf bytes.Buffer
	cmd.SetOut(&stdoutBuf)
	cmd.SetErr(&stderrBuf)
	cmd.SetIn(strings.NewReader(stdin))
	err := cmd.Execute()
	exitCode = 0
	if err != nil {
		var ec errExitCode
		if stderrs.As(err, &ec) {
			exitCode = ec.code
		} else {
			exitCode = 1
		}
	}
	return stdoutBuf.String(), stderrBuf.String(), exitCode
}

func TestDiagnoseClassify_Routing(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name, in, want string
	}{
		{"code", "error TS2304: Cannot find name 'foo'", "code_dominant"},
		{"noncode", "ECONNREFUSED 127.0.0.1:5432\nECONNREFUSED 127.0.0.1:6379", "noncode_dominant"},
		{"unknown", "completely unrecognised banner one\nanother mystery line", "unknown_only"},
	}
	for _, tc := range cases {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			out, _, code := runDiagnose(t, tc.in, "classify")
			if code != 0 {
				t.Fatalf("non-zero exit %d", code)
			}
			if strings.TrimSpace(out) != tc.want {
				t.Fatalf("want %q got %q", tc.want, strings.TrimSpace(out))
			}
		})
	}
}

func TestDiagnoseClassify_HasCode(t *testing.T) {
	t.Parallel()
	_, _, code := runDiagnose(t, "error TS2304: foo", "classify", "--has-code")
	if code != 0 {
		t.Fatalf("has-code with code line: want exit 0 got %d", code)
	}
	_, _, code = runDiagnose(t, "ECONNREFUSED 127.0.0.1:5432", "classify", "--has-code")
	if code != 1 {
		t.Fatalf("has-code with noncode: want exit 1 got %d", code)
	}
}

func TestDiagnoseClassify_HasOnlyNoncode(t *testing.T) {
	t.Parallel()
	_, _, code := runDiagnose(t, "ECONNREFUSED 127.0.0.1:5432\nsome unknown banner", "classify", "--has-only-noncode")
	if code != 0 {
		t.Fatalf("has-only-noncode bifl shape: want 0 got %d", code)
	}
	_, _, code = runDiagnose(t, "error TS2304: foo", "classify", "--has-only-noncode")
	if code != 1 {
		t.Fatalf("has-only-noncode with code: want 1 got %d", code)
	}
}

func TestDiagnoseClassify_StatsMode(t *testing.T) {
	t.Parallel()
	out, _, _ := runDiagnose(t, "ECONNREFUSED 127.0.0.1:5432", "classify", "--mode", "stats")
	line := strings.TrimSpace(out)
	if !strings.HasPrefix(line, "service_dep|") {
		t.Fatalf("want service_dep prefix, got %q", line)
	}
	if strings.Count(line, "|") != 7 {
		t.Fatalf("legacy stats record needs 8 fields (7 pipes), got %q", line)
	}
}

func TestDiagnoseClassifyAgent(t *testing.T) {
	t.Parallel()
	out, _, code := runDiagnose(t, "", "classify-agent", "--exit", "137")
	if code != 0 {
		t.Fatalf("exit %d", code)
	}
	if !strings.HasPrefix(strings.TrimSpace(out), "ENVIRONMENT|oom|true|") {
		t.Fatalf("OOM classification: %q", out)
	}
}

func TestDiagnoseRecovery(t *testing.T) {
	t.Parallel()
	out, _, _ := runDiagnose(t, "", "recovery", "UPSTREAM", "api_rate_limit")
	if !strings.Contains(out, "rate limit") {
		t.Fatalf("recovery missing rate-limit text: %q", out)
	}
}

func TestDiagnoseRedact(t *testing.T) {
	t.Parallel()
	out, _, _ := runDiagnose(t, "X-Api-Key: sk-ant-test", "redact")
	if strings.Contains(out, "sk-ant-test") {
		t.Fatalf("api key not redacted: %q", out)
	}
}

func TestDiagnoseIsTransient(t *testing.T) {
	t.Parallel()
	_, _, code := runDiagnose(t, "", "is-transient", "UPSTREAM", "api_rate_limit")
	if code != 0 {
		t.Fatalf("api_rate_limit: want 0 got %d", code)
	}
	_, _, code = runDiagnose(t, "", "is-transient", "UPSTREAM", "api_auth")
	if code != 1 {
		t.Fatalf("api_auth: want 1 got %d", code)
	}
}

func TestDiagnoseClassify_AllMode(t *testing.T) {
	t.Parallel()
	// --mode all exercises ClassifyAll + FormatAllLegacy (4 fields, 3 pipes).
	out, _, code := runDiagnose(t, "ECONNREFUSED 127.0.0.1:5432\nunmatched banner here", "classify", "--mode", "all")
	if code != 0 {
		t.Fatalf("non-zero exit %d", code)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) < 1 {
		t.Fatal("want at least one output line")
	}
	for _, l := range lines {
		if strings.Count(l, "|") != 3 {
			t.Errorf("FormatAllLegacy must produce 4 fields (3 pipes): %q", l)
		}
	}
}

func TestDiagnoseClassify_FilterCodeMode(t *testing.T) {
	t.Parallel()
	in := "error TS2304: Cannot find name 'foo'\nECONNREFUSED 127.0.0.1:5432"
	out, _, code := runDiagnose(t, in, "classify", "--mode", "filter-code")
	if code != 0 {
		t.Fatalf("non-zero exit %d", code)
	}
	if !strings.Contains(out, "## Code Errors to Fix") {
		t.Errorf("filter-code: want Code Errors section in:\n%s", out)
	}
	if !strings.Contains(out, "## Already Handled") {
		t.Errorf("filter-code: want Already Handled section in:\n%s", out)
	}
}

func TestDiagnoseClassify_AnnotateMode(t *testing.T) {
	t.Parallel()
	in := "error TS2304: Cannot find name 'foo'"
	out, _, code := runDiagnose(t, in, "classify", "--mode", "annotate", "--stage", "compile")
	if code != 0 {
		t.Fatalf("non-zero exit %d", code)
	}
	if !strings.Contains(out, "# Build Errors") {
		t.Errorf("annotate: want Build Errors header in:\n%s", out)
	}
	if !strings.Contains(out, "compile") {
		t.Errorf("annotate: want stage name 'compile' in:\n%s", out)
	}
}

func TestDiagnoseClassify_UnknownModeExits(t *testing.T) {
	t.Parallel()
	_, _, code := runDiagnose(t, "some input", "classify", "--mode", "bogus_mode")
	if code == 0 {
		t.Fatal("unknown --mode must produce non-zero exit code")
	}
}

// TestDiagnoseRun_HelpExits0 — m32.1 smoke check that `tekhton diagnose run
// --help` is wired through the Cobra tree.
func TestDiagnoseRun_HelpExits0(t *testing.T) {
	t.Parallel()
	out, _, code := runDiagnose(t, "", "run", "--help")
	if code != 0 {
		t.Fatalf("run --help exit=%d", code)
	}
	if !strings.Contains(out, "Run the diagnose engine") {
		t.Errorf("help text missing usage: %q", out)
	}
}

// TestDiagnoseRun_EmptyProjectDirReportsNoState — `tekhton diagnose run
// --project-dir <empty>` must NOT crash and must report the "no pipeline
// runs found" path on a fresh directory.
//
// Cannot t.Parallel() because we t.Setenv to neutralize PIPELINE_STATE_FILE /
// CAUSAL_LOG_FILE / MIGRATION_BACKUP_DIR — these may be set by the parent
// shell when the suite is run inside a pipeline.
func TestDiagnoseRun_EmptyProjectDirReportsNoState(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", "")
	t.Setenv("MIGRATION_BACKUP_DIR", "")
	dir := t.TempDir()
	_, errOut, code := runDiagnose(t, "", "run", "--project-dir", dir)
	if code != 0 {
		t.Fatalf("expected exit 0 on empty project, got %d", code)
	}
	if !strings.Contains(errOut, "No pipeline runs found") {
		t.Errorf("empty-project path should report no runs; got stderr=%q", errOut)
	}
}

// TestDiagnoseRun_PopulatedFixtureOutputsClassification materialises a minimal
// project directory containing LAST_FAILURE_CONTEXT.json and drives
// `tekhton diagnose run --project-dir <dir>` through cmd.Execute(). It closes
// the reviewer gap between the engine integration test (which calls the engine
// directly) and the CLI smoke test (which only exercises the no-state path).
//
// The test does not assert a specific classification beyond non-empty: the
// rule that fires depends on which fields the m32.2 Go registry's rules look
// for. What matters here is that:
//  1. ReadContext successfully parses the fixture and does NOT report "no runs found".
//  2. The CLI prints "Classification:" on stdout (the engine ran to completion).
//  3. Exit code is 0 (the CLI path is fully wired).
//
// Cannot t.Parallel() — t.Setenv neutralises env vars that may be set by the
// parent pipeline shell.
func TestDiagnoseRun_PopulatedFixtureOutputsClassification(t *testing.T) {
	t.Setenv("PIPELINE_STATE_FILE", "")
	t.Setenv("CAUSAL_LOG_FILE", "")
	t.Setenv("MIGRATION_BACKUP_DIR", "")

	dir := t.TempDir()

	// Materialise a minimal LAST_FAILURE_CONTEXT.json so ReadContext finds state.
	claudeDir := filepath.Join(dir, ".claude")
	if err := os.MkdirAll(claudeDir, 0o755); err != nil {
		t.Fatalf("mkdir .claude: %v", err)
	}
	failureCtx := filepath.Join(claudeDir, "LAST_FAILURE_CONTEXT.json")
	body := `{
  "schema_version": 2,
  "classification": "MAX_TURNS_EXHAUSTED",
  "stage": "coder",
  "outcome": "failure",
  "task": "Port the diagnose engine to Go",
  "consecutive_count": 1
}`
	if err := os.WriteFile(failureCtx, []byte(body), 0o644); err != nil {
		t.Fatalf("write LAST_FAILURE_CONTEXT.json: %v", err)
	}

	out, errOut, code := runDiagnose(t, "", "run", "--project-dir", dir)

	if code != 0 {
		t.Fatalf("run with populated fixture: want exit 0, got %d (stderr=%q)", code, errOut)
	}
	// ReadContext found state — the "no pipeline runs" branch must NOT be taken.
	if strings.Contains(errOut, "No pipeline runs found") {
		t.Errorf("fixture has LAST_FAILURE_CONTEXT.json; engine must not report no-state (stderr=%q)", errOut)
	}
	// Engine ran to completion — stdout must start with the Classification line.
	if !strings.Contains(out, "Classification:") {
		t.Errorf("CLI output must contain 'Classification:' line; got stdout=%q", out)
	}
	// Confidence and Stage lines are always emitted by the cmd.
	if !strings.Contains(out, "Confidence:") {
		t.Errorf("CLI output must contain 'Confidence:' line; got stdout=%q", out)
	}
	if !strings.Contains(out, "Stage:") {
		t.Errorf("CLI output must contain 'Stage:' line; got stdout=%q", out)
	}
}
