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

// filterEnv returns env with every NAME=... entry whose NAME is in the drop
// list removed. Used by handle-unfixable tests to isolate the subprocess
// from the developer's $HUMAN_ACTION_FILE override.
func filterEnv(env []string, drop ...string) []string {
	dropSet := make(map[string]bool, len(drop))
	for _, k := range drop {
		dropSet[k] = true
	}
	out := env[:0:0]
	for _, e := range env {
		eq := strings.IndexByte(e, '=')
		if eq > 0 && dropSet[e[:eq]] {
			continue
		}
		out = append(out, e)
	}
	return out
}

func readFileTrimNothing(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func TestSecurityCmd_Hidden(t *testing.T) {
	c := newSecurityCmd()
	if !c.Hidden {
		t.Error("security command should be Hidden")
	}
	want := map[string]bool{
		"parse-findings":   false,
		"meets-threshold":  false,
		"build-block":      false,
		"is-docs-only":     false,
		"handle-unfixable": false,
	}
	for _, x := range c.Commands() {
		name := strings.SplitN(x.Use, " ", 2)[0]
		if _, ok := want[name]; ok {
			want[name] = true
		}
	}
	for sub, found := range want {
		if !found {
			t.Errorf("security subcommand %q missing", sub)
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

func TestSecurityHandleUnfixable_EscalateWritesHumanAction(t *testing.T) {
	bin := buildTekhtonBinary(t)
	dir := t.TempDir()
	cmd := exec.Command(bin, "security", "handle-unfixable",
		"--policy", "escalate",
		"--block", "- [HIGH] cli escalation\n",
		"--project-dir", dir,
	)
	cmd.Env = filterEnv(os.Environ(), "HUMAN_ACTION_FILE")
	if err := cmd.Run(); err != nil {
		t.Fatalf("run err: %v", err)
	}
	// drift.go's humanActionPath defaults to ${projectDir}/HUMAN_ACTION_REQUIRED.md
	// (no .tekhton/ prefix) — matches the drift human-action append CLI path.
	body, err := readFileTrimNothing(filepath.Join(dir, "HUMAN_ACTION_REQUIRED.md"))
	if err != nil {
		t.Fatalf("read human-action: %v", err)
	}
	if !strings.Contains(body, "cli escalation") {
		t.Errorf("human-action file missing block content:\n%s", body)
	}
	if !strings.Contains(body, "Source: security") {
		t.Errorf("human-action file missing security source label:\n%s", body)
	}
}

func TestSecurityHandleUnfixable_HaltExits1(t *testing.T) {
	bin := buildTekhtonBinary(t)
	dir := t.TempDir()
	cmd := exec.Command(bin, "security", "handle-unfixable",
		"--policy", "halt",
		"--block", "- [HIGH] x\n",
		"--project-dir", dir,
	)
	err := cmd.Run()
	exit, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("expected non-nil exit error, got %v", err)
	}
	if exit.ExitCode() != 1 {
		t.Errorf("exit = %d, want 1", exit.ExitCode())
	}
}
