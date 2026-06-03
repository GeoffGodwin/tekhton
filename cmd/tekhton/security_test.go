package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

var (
	tekhtonBinOnce sync.Once
	tekhtonBinPath string
	tekhtonBinErr  error
)

// buildTekhtonBinary builds the tekhton binary into a tempdir once per
// `go test` invocation and returns the path. Tests that need to assert on
// exit codes drive the binary directly because Cobra/os.Exit cannot be
// intercepted in-process.
func buildTekhtonBinary(t *testing.T) string {
	t.Helper()
	tekhtonBinOnce.Do(func() {
		dir, err := os.MkdirTemp("", "tekhton-bin-")
		if err != nil {
			tekhtonBinErr = err
			return
		}
		path := filepath.Join(dir, "tekhton")
		cmd := exec.Command("go", "build", "-o", path, "github.com/geoffgodwin/tekhton/cmd/tekhton")
		if out, err := cmd.CombinedOutput(); err != nil {
			tekhtonBinErr = fmt.Errorf("go build: %w\n%s", err, out)
			_ = os.RemoveAll(dir)
			return
		}
		tekhtonBinPath = path
	})
	if tekhtonBinErr != nil {
		t.Fatalf("build tekhton binary: %v", tekhtonBinErr)
	}
	return tekhtonBinPath
}

func writeFile(path, body string) error {
	return os.WriteFile(path, []byte(body), 0o644)
}

func readFileTrimNothing(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// TestSecurityCmd_RegisterAndVisibility asserts the m35.2 visibility
// rewire: parent is visible (operator tools), `parse-findings` +
// `meets-threshold` are visible, `build-block` + `is-docs-only` stay
// Hidden as debug helpers, and `handle-unfixable` is gone entirely.
func TestSecurityCmd_RegisterAndVisibility(t *testing.T) {
	c := newSecurityCmd()
	if c.Hidden {
		t.Error("security parent command should be visible after m35.2")
	}
	wantVisible := map[string]bool{
		"parse-findings":  false,
		"meets-threshold": false,
	}
	wantHidden := map[string]bool{
		"build-block":  false,
		"is-docs-only": false,
	}
	for _, x := range c.Commands() {
		name := strings.SplitN(x.Use, " ", 2)[0]
		if _, ok := wantVisible[name]; ok {
			wantVisible[name] = true
			if x.Hidden {
				t.Errorf("subcommand %q must be visible after m35.2", name)
			}
		}
		if _, ok := wantHidden[name]; ok {
			wantHidden[name] = true
			if !x.Hidden {
				t.Errorf("subcommand %q must stay Hidden as a debug-only tool", name)
			}
		}
		if name == "handle-unfixable" {
			t.Error("handle-unfixable subcommand must be deleted after m35.2 (was shim-only)")
		}
	}
	for sub, found := range wantVisible {
		if !found {
			t.Errorf("operator subcommand %q missing", sub)
		}
	}
	for sub, found := range wantHidden {
		if !found {
			t.Errorf("debug subcommand %q missing", sub)
		}
	}
}

func TestSecurityCmd_AllSubcommandsHelp(t *testing.T) {
	c := newSecurityCmd()
	for _, sub := range c.Commands() {
		sub := sub
		t.Run(strings.SplitN(sub.Use, " ", 2)[0], func(t *testing.T) {
			sub.SetArgs([]string{"--help"})
			if err := sub.Execute(); err != nil {
				t.Errorf("%s --help: %v", sub.Use, err)
			}
		})
	}
}

func TestSecurityParseFindings_TSV(t *testing.T) {
	stdout, _, err := runRoot(t, "",
		"security", "parse-findings",
		"--report", "../../internal/security/testdata/reports/04-mixed-fixable.md",
		"--format", "tsv",
	)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	lines := strings.Split(strings.TrimSuffix(stdout, "\n"), "\n")
	if len(lines) != 4 {
		t.Fatalf("expected 4 TSV rows, got %d: %q", len(lines), stdout)
	}
	for i, line := range lines {
		cols := strings.Split(line, "\t")
		if len(cols) != 3 {
			t.Errorf("row %d: want 3 tab-separated columns, got %d: %q", i, len(cols), line)
		}
	}
	wantPrefixes := []string{"CRITICAL\tyes\t", "HIGH\tno\t", "MEDIUM\tyes\t", "LOW\tunknown\t"}
	for i, want := range wantPrefixes {
		if !strings.HasPrefix(lines[i], want) {
			t.Errorf("row %d: want prefix %q, got %q", i, want, lines[i])
		}
	}
}

func TestSecurityParseFindings_JSON(t *testing.T) {
	stdout, _, err := runRoot(t, "",
		"security", "parse-findings",
		"--report", "../../internal/security/testdata/reports/03-all-low.md",
		"--format", "json",
	)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if !strings.Contains(stdout, "\"Severity\": \"LOW\"") {
		t.Errorf("JSON output missing LOW severity entry: %q", stdout)
	}
}

// TestSecurityMeetsThreshold_ExitCodes drives the CLI via the actual binary
// to verify exit-code behavior (os.Exit cannot be intercepted by Cobra
// in-process). The binary is built once into a tempdir.
func TestSecurityMeetsThreshold_ExitCodes(t *testing.T) {
	bin := buildTekhtonBinary(t)
	cases := []struct {
		sev, thr string
		want     int
	}{
		{"CRITICAL", "HIGH", 0},
		{"HIGH", "CRITICAL", 1},
		{"HIGH", "HIGH", 0},
		{"LOW", "LOW", 0},
		{"BOGUS", "LOW", 1},
		{"LOW", "BOGUS", 0},
	}
	for _, c := range cases {
		cmd := exec.Command(bin, "security", "meets-threshold",
			"--severity", c.sev, "--threshold", c.thr)
		err := cmd.Run()
		got := 0
		if exit, ok := err.(*exec.ExitError); ok {
			got = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("(%s,%s): unexpected run err: %v", c.sev, c.thr, err)
		}
		if got != c.want {
			t.Errorf("(%s vs %s) exit = %d, want %d", c.sev, c.thr, got, c.want)
		}
	}
}

func TestSecurityBuildBlock_AgainstFixtures(t *testing.T) {
	cases := []struct {
		fixture, kind string
	}{
		{"04-mixed-fixable", "fixable"},
		{"04-mixed-fixable", "unfixable"},
		{"04-mixed-fixable", "notes"},
		{"03-all-low", "notes"},
		{"01-empty", "fixable"},
	}
	for _, c := range cases {
		stdout, _, err := runRoot(t, "",
			"security", "build-block",
			"--report", "../../internal/security/testdata/reports/"+c.fixture+".md",
			"--kind", c.kind,
			"--threshold", "HIGH",
		)
		if err != nil {
			t.Errorf("%s/%s: err: %v", c.fixture, c.kind, err)
			continue
		}
		baseline := "../../internal/security/testdata/baselines/" + c.fixture + "-" + c.kind + ".txt"
		want, err := readFileTrimNothing(baseline)
		if err != nil {
			t.Errorf("%s/%s: baseline read err: %v", c.fixture, c.kind, err)
			continue
		}
		if stdout != want {
			t.Errorf("%s/%s mismatch:\n got  %q\n want %q", c.fixture, c.kind, stdout, want)
		}
	}
}

func TestSecurityIsDocsOnly_ExitCodes(t *testing.T) {
	bin := buildTekhtonBinary(t)
	dir := t.TempDir()
	docsOnly := filepath.Join(dir, "docs.md")
	codeOnly := filepath.Join(dir, "code.md")
	must := func(p, body string) {
		t.Helper()
		if err := writeFile(p, body); err != nil {
			t.Fatal(err)
		}
	}
	must(docsOnly, "# x\n## Files Modified\n- README.md\n- docs/api.yaml\n")
	must(codeOnly, "# x\n## Files Modified\n- internal/security/findings.go\n")

	for _, c := range []struct {
		path string
		want int
	}{
		{docsOnly, 0},
		{codeOnly, 1},
	} {
		cmd := exec.Command(bin, "security", "is-docs-only", "--summary", c.path)
		err := cmd.Run()
		got := 0
		if exit, ok := err.(*exec.ExitError); ok {
			got = exit.ExitCode()
		} else if err != nil {
			t.Fatalf("run err: %v", err)
		}
		if got != c.want {
			t.Errorf("%s: exit = %d, want %d", c.path, got, c.want)
		}
	}
}

// m35.2: TestSecurityHandleUnfixable_* tests are deleted alongside the
// handle-unfixable subcommand. The shim's escalate/halt branches are now
// covered by internal/stages/security/run_test.go::TestRunStage_UnfixableHalt
// and TestRunStage_UnfixableEscalate, which exercise the in-process path
// the Go stage actually uses. The Escalator routing logic itself stays
// covered by internal/security/escalation_test.go (unchanged from m35.1).

// TestSecurityHandleUnfixable_Removed asserts the contract change is
// permanent: the deleted subcommand is not registered under the security
// parent. Cobra's default behavior on an unknown subcommand is to print
// help and exit 0, so this test asserts on the registered subcommand
// list directly rather than on subprocess exit codes.
func TestSecurityHandleUnfixable_Removed(t *testing.T) {
	c := newSecurityCmd()
	for _, sub := range c.Commands() {
		name := strings.SplitN(sub.Use, " ", 2)[0]
		if name == "handle-unfixable" {
			t.Fatal("handle-unfixable subcommand must be deleted after m35.2 (was shim-only)")
		}
	}
}
