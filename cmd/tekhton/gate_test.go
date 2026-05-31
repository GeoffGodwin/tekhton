package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestGateCmd_RegistersAllThree verifies the Cobra tree carries the three
// expected subcommands. The parent `gate` command is Hidden so it stays
// out of `tekhton --help`; the children are visible under
// `tekhton gate --help` so the m31.1 acceptance criterion's help listing
// requirement is met.
func TestGateCmd_RegistersAllThree(t *testing.T) {
	c := newGateCmd()
	want := map[string]bool{"build": false, "completion": false, "ui": false}
	for _, sub := range c.Commands() {
		if _, ok := want[sub.Name()]; ok {
			want[sub.Name()] = true
		}
	}
	for name, seen := range want {
		if !seen {
			t.Errorf("subcommand %q not registered under `tekhton gate`", name)
		}
	}
	if !c.Hidden {
		t.Error("gate root should be Hidden — internal developer tool")
	}
}

// TestGateCmd_HelpListsAllSubcommands ensures `tekhton gate --help`
// renders the three subcommands in its output (relied on by the
// acceptance criterion).
func TestGateCmd_HelpListsAllSubcommands(t *testing.T) {
	c := newGateCmd()
	var buf bytes.Buffer
	c.SetOut(&buf)
	c.SetArgs([]string{"--help"})
	if err := c.Execute(); err != nil {
		t.Fatalf("Execute(--help) = %v", err)
	}
	out := buf.String()
	for _, name := range []string{"build", "completion", "ui"} {
		if !strings.Contains(out, name) {
			t.Errorf("`gate --help` output missing subcommand %q\nout:\n%s", name, out)
		}
	}
}

// TestGateUI_StubReturnsNonZero asserts the m31.1 stub.
func TestGateUI_StubReturnsNonZero(t *testing.T) {
	c := newGateUICmd()
	c.SetOut(new(bytes.Buffer))
	c.SetErr(new(bytes.Buffer))
	err := c.RunE(c, nil)
	if err == nil {
		t.Fatal("gate ui should return non-nil error in m31.1")
	}
	var ec errExitCode
	if !errors.As(err, &ec) {
		t.Fatalf("error = %v, want errExitCode", err)
	}
	if ec.ExitCode() != exitUsage {
		t.Errorf("gate ui exit code = %d, want %d", ec.ExitCode(), exitUsage)
	}
}

// TestEnvOr / TestEnvBool / TestEnvSeconds cover the small env helpers
// in cmd/tekhton/gate.go.
func TestEnvOr(t *testing.T) {
	t.Setenv("FOO_TEST_KEY", "v")
	if got := envOr("FOO_TEST_KEY", "fallback"); got != "v" {
		t.Errorf("envOr set = %q, want v", got)
	}
	if got := envOr("FOO_TEST_KEY_MISSING", "fallback"); got != "fallback" {
		t.Errorf("envOr unset = %q, want fallback", got)
	}
}

func TestEnvBool(t *testing.T) {
	cases := []struct {
		val      string
		fallback bool
		want     bool
	}{
		{"true", false, true},
		{"True", false, true},
		{"1", false, true},
		{"yes", false, true},
		{"false", true, false},
		{"0", true, false},
		{"anything", false, false},
		{"", true, true},
		{"", false, false},
	}
	for _, tc := range cases {
		t.Setenv("GATE_BOOL_TEST", tc.val)
		got := envBool("GATE_BOOL_TEST", tc.fallback)
		if got != tc.want {
			t.Errorf("envBool(%q, %v) = %v, want %v", tc.val, tc.fallback, got, tc.want)
		}
	}
}

func TestEnvSeconds(t *testing.T) {
	t.Setenv("GATE_SEC_TEST", "")
	if got := envSeconds("GATE_SEC_TEST", 120); got != 120*time.Second {
		t.Errorf("envSeconds(unset, 120) = %v, want 120s", got)
	}
	t.Setenv("GATE_SEC_TEST", "30")
	if got := envSeconds("GATE_SEC_TEST", 120); got != 30*time.Second {
		t.Errorf("envSeconds(30, 120) = %v, want 30s", got)
	}
	t.Setenv("GATE_SEC_TEST", "garbage")
	if got := envSeconds("GATE_SEC_TEST", 120); got != 120*time.Second {
		t.Errorf("envSeconds(garbage, 120) = %v, want 120s (fallback)", got)
	}
	t.Setenv("GATE_SEC_TEST", "0")
	if got := envSeconds("GATE_SEC_TEST", 120); got != 120*time.Second {
		t.Errorf("envSeconds(0, 120) = %v, want 120s (zero rejected)", got)
	}
}

// TestReadValidationCmd_StripsQuotes verifies the bash sed/tr pipeline.
func TestReadValidationCmd_StripsQuotes(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "constraints.yaml")
	body := "layer: foo\nvalidation_command: \"./scripts/check.sh\"\nrules:\n"
	if err := writeFileTest(p, body); err != nil {
		t.Fatal(err)
	}
	got := readValidationCmd(p)
	if got != "./scripts/check.sh" {
		t.Errorf("readValidationCmd = %q, want %q (quotes stripped)", got, "./scripts/check.sh")
	}
}

// TestReadValidationCmd_EmptyPathReturnsEmpty.
func TestReadValidationCmd_EmptyPathReturnsEmpty(t *testing.T) {
	if got := readValidationCmd(""); got != "" {
		t.Errorf("readValidationCmd(empty) = %q, want empty", got)
	}
	if got := readValidationCmd("/path/that/does/not/exist"); got != "" {
		t.Errorf("readValidationCmd(missing) = %q, want empty", got)
	}
}

// TestBuildGateFromEnv_AssemblesAllPhases is a smoke test that exercises
// the env-to-BuildGate construction without spawning a real subprocess.
// Every env-derived field is empty here, so every phase factory returns a
// Skip-shape phase — Run completes quickly and clean.
func TestBuildGateFromEnv_AssemblesAllPhases(t *testing.T) {
	// Clear every env key the assembler reads so the test is hermetic.
	for _, k := range []string{
		"ANALYZE_CMD", "BUILD_CHECK_CMD", "UI_TEST_CMD",
		"DEPENDENCY_CONSTRAINTS_FILE", "ANALYZE_ERROR_PATTERN", "BUILD_ERROR_PATTERN",
	} {
		t.Setenv(k, "")
	}
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := buildGateFromEnv("post-coder-test")
	if g == nil {
		t.Fatal("buildGateFromEnv returned nil")
	}
	if len(g.Phases) != 5 {
		t.Errorf("expected 5 registered phases, got %d", len(g.Phases))
	}
	if err := g.Run(context.Background(), "post-coder-test"); err != nil {
		t.Fatalf("Run with all-skip phases = %v, want nil", err)
	}
}

func writeFileTest(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}

// TestCompletionGateFromEnv_PassOnPreexistingTrue verifies that the
// TEST_BASELINE_PASS_ON_PREEXISTING env var is read and propagated to
// CompletionGate.PassOnPreexisting. The field is a prerequisite for M92
// pre-existing-failure acceptance; if it's not read the feature cannot work
// regardless of whether a BaselineComparator is wired.
func TestCompletionGateFromEnv_PassOnPreexistingTrue(t *testing.T) {
	t.Setenv("TEST_BASELINE_PASS_ON_PREEXISTING", "true")
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := completionGateFromEnv()
	if !g.PassOnPreexisting {
		t.Error("PassOnPreexisting = false, want true (TEST_BASELINE_PASS_ON_PREEXISTING=true not propagated)")
	}
}

// TestCompletionGateFromEnv_PassOnPreexistingDefaultFalse verifies the M92
// default: TEST_BASELINE_PASS_ON_PREEXISTING defaults to false so
// pre-existing failures are rejected until explicitly opted out.
func TestCompletionGateFromEnv_PassOnPreexistingDefaultFalse(t *testing.T) {
	t.Setenv("TEST_BASELINE_PASS_ON_PREEXISTING", "")
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := completionGateFromEnv()
	if g.PassOnPreexisting {
		t.Error("PassOnPreexisting = true, want false (M92 default is reject pre-existing failures)")
	}
}

// TestCompletionGateFromEnv_NilBaselinePreventsM92Accept documents that
// completionGateFromEnv() leaves Baseline nil (Reviewer non-blocking note,
// m31.1 known gap). With Baseline == nil, TEST_BASELINE_PASS_ON_PREEXISTING=true
// has no effect — the M92 accept-pre-existing path in CompletionGate.runTestCmd
// is guarded by `g.Baseline != nil`, so the flag is silently inert. This test
// will fail (and should be updated) once a concrete BaselineComparator is wired
// in completionGateFromEnv.
func TestCompletionGateFromEnv_NilBaselinePreventsM92Accept(t *testing.T) {
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := completionGateFromEnv()
	if g.Baseline != nil {
		t.Error("Baseline is now wired in completionGateFromEnv — update this test and the M92 parity scenario")
	}
}

// TestCompletionGateFromEnv_DedupNilDocumentsM105Gap documents that
// completionGateFromEnv() leaves Dedup nil. With Dedup == nil, the M105
// working-tree fingerprint fast-path (CanSkip → skip TEST_CMD invocation)
// never fires: TEST_CMD always runs even on an unchanged working tree.
// This test will fail (and should be updated) once a concrete TestDedup
// implementation is wired in completionGateFromEnv.
func TestCompletionGateFromEnv_DedupNilDocumentsM105Gap(t *testing.T) {
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := completionGateFromEnv()
	if g.Dedup != nil {
		t.Error("Dedup is now wired in completionGateFromEnv — update this test and add an M105 parity scenario")
	}
}

// TestCompletionGateFromEnv_SubstantiveNilDocumentsM86Gap documents that
// completionGateFromEnv() leaves Substantive nil. With Substantive == nil,
// the M86 substantive-work probe never fires — a CODER_SUMMARY.md with no
// Status field always routes to ErrCompletionNoStatus rather than the more
// informative ErrCompletionSubstantiveNoStatus, regardless of whether the
// working tree has real changes.
// This test will fail (and should be updated) once a concrete SubstantiveProbe
// is wired in completionGateFromEnv.
func TestCompletionGateFromEnv_SubstantiveNilDocumentsM86Gap(t *testing.T) {
	t.Setenv("TEKHTON_DIR", t.TempDir())
	g := completionGateFromEnv()
	if g.Substantive != nil {
		t.Error("Substantive is now wired in completionGateFromEnv — update this test and the M86 parity scenario")
	}
}
