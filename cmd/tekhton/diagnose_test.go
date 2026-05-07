package main

import (
	"bytes"
	stderrs "errors"
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
