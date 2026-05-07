package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/config"
)

func writeConfigFixture(t *testing.T, body string) (path, projectDir string) {
	t.Helper()
	d := t.TempDir()
	p := filepath.Join(d, "pipeline.conf")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	return p, d
}

func TestConfigLoad_EmitShell(t *testing.T) {
	clearCIEnvTest(t)
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
CODER_MAX_TURNS=42
`)
	cmd := newRootCmd()
	var stdout, stderr bytes.Buffer
	cmd.SetArgs([]string{"config", "load", "--path", p, "--project-dir", pd, "--emit", "shell", "--no-warn"})
	cmd.SetOut(&stdout)
	cmd.SetErr(&stderr)
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v\nstderr: %s", err, stderr.String())
	}
	out := stdout.String()
	if !strings.Contains(out, "export PROJECT_NAME='t'") {
		t.Errorf("missing PROJECT_NAME: %s", out)
	}
	if !strings.Contains(out, "export CODER_MAX_TURNS='42'") {
		t.Errorf("missing CODER_MAX_TURNS=42: %s", out)
	}
}

func TestConfigLoad_EmitJSON(t *testing.T) {
	clearCIEnvTest(t)
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	cmd := newRootCmd()
	var stdout bytes.Buffer
	cmd.SetArgs([]string{"config", "load", "--path", p, "--project-dir", pd, "--emit", "json", "--indent", "--no-warn"})
	cmd.SetOut(&stdout)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !strings.Contains(stdout.String(), `"envelope_ver": "tekhton.config.v1"`) {
		t.Errorf("missing envelope marker: %s", stdout.String())
	}
}

func TestConfigLoad_MissingPipelineConf(t *testing.T) {
	cmd := newRootCmd()
	cmd.SetArgs([]string{"config", "load", "--path", "/no/such/file.conf"})
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for missing file")
	}
	if ec, ok := err.(errExitCode); !ok || ec.code != exitNotFound {
		t.Errorf("expected exitNotFound, got %v", err)
	}
}

func TestConfigLoad_MissingRequired(t *testing.T) {
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
ANALYZE_CMD="echo ok"
`)
	cmd := newRootCmd()
	cmd.SetArgs([]string{"config", "load", "--path", p, "--project-dir", pd, "--no-warn"})
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected error for missing required key")
	}
	if ec, ok := err.(errExitCode); !ok || ec.code != exitCorrupt {
		t.Errorf("expected exitCorrupt, got %v", err)
	}
}

func TestConfigValidate_StrictPromotesWarnings(t *testing.T) {
	clearCIEnvTest(t)
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
CODER_MAX_TURNS=99999
`)
	cmd := newRootCmd()
	cmd.SetArgs([]string{"config", "validate", "--path", p, "--project-dir", pd, "--strict"})
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetErr(&bytes.Buffer{})
	err := cmd.Execute()
	if err == nil {
		t.Fatal("expected strict-mode failure on clamp warning")
	}
	if ec, ok := err.(errExitCode); !ok || ec.code != exitUsage {
		t.Errorf("expected exitUsage, got %v", err)
	}
}

func TestConfigValidate_HealthyPasses(t *testing.T) {
	clearCIEnvTest(t)
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	cmd := newRootCmd()
	var stdout bytes.Buffer
	cmd.SetArgs([]string{"config", "validate", "--path", p, "--project-dir", pd})
	cmd.SetOut(&stdout)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("validate failed unexpectedly: %v", err)
	}
	if !strings.Contains(stdout.String(), "ok —") {
		t.Errorf("expected ok line: %s", stdout.String())
	}
}

func TestConfigDefaults_EmitShell(t *testing.T) {
	clearCIEnvTest(t)
	cmd := newRootCmd()
	var stdout bytes.Buffer
	cmd.SetArgs([]string{"config", "defaults", "--emit", "shell"})
	cmd.SetOut(&stdout)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	out := stdout.String()
	if !strings.Contains(out, "export CLAUDE_STANDARD_MODEL='claude-sonnet-4-6'") {
		t.Errorf("missing CLAUDE_STANDARD_MODEL default: %s", out)
	}
	if !strings.Contains(out, "export CODER_MAX_TURNS='80'") {
		t.Errorf("missing CODER_MAX_TURNS default: %s", out)
	}
}

func TestConfigShow_Default(t *testing.T) {
	clearCIEnvTest(t)
	p, pd := writeConfigFixture(t, `PROJECT_NAME="t"
CLAUDE_STANDARD_MODEL="x"
ANALYZE_CMD="echo ok"
`)
	cmd := newRootCmd()
	var stdout bytes.Buffer
	cmd.SetArgs([]string{"config", "show", "--path", p, "--project-dir", pd, "--no-warn"})
	cmd.SetOut(&stdout)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !strings.Contains(stdout.String(), `"PROJECT_NAME": "t"`) {
		t.Errorf("expected PROJECT_NAME in JSON: %s", stdout.String())
	}
}

func TestConfigDefaults_MilestoneMode(t *testing.T) {
	clearCIEnvTest(t)
	cmd := newRootCmd()
	var stdout bytes.Buffer
	cmd.SetArgs([]string{"config", "defaults", "--emit", "shell", "--milestone-mode"})
	cmd.SetOut(&stdout)
	cmd.SetErr(&bytes.Buffer{})
	if err := cmd.Execute(); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	out := stdout.String()
	// applyMilestoneOverrides replaces CODER_MAX_TURNS with MILESTONE_CODER_MAX_TURNS
	// (CODER_MAX_TURNS * 2 = 80 * 2 = 160).
	if !strings.Contains(out, "export CODER_MAX_TURNS='160'") {
		t.Errorf("expected CODER_MAX_TURNS=160 in milestone-mode defaults, got:\n%s", out)
	}
	// REVIEWER_MAX_TURNS replaced by MILESTONE_REVIEWER_MAX_TURNS (20 + 5 = 25).
	if !strings.Contains(out, "export REVIEWER_MAX_TURNS='25'") {
		t.Errorf("expected REVIEWER_MAX_TURNS=25 in milestone-mode defaults, got:\n%s", out)
	}
	// AGENT_ACTIVITY_TIMEOUT multiplied by MILESTONE_ACTIVITY_TIMEOUT_MULTIPLIER (600 * 3 = 1800).
	if !strings.Contains(out, "export AGENT_ACTIVITY_TIMEOUT='1800'") {
		t.Errorf("expected AGENT_ACTIVITY_TIMEOUT=1800 in milestone-mode defaults, got:\n%s", out)
	}
}

func clearCIEnvTest(t *testing.T) {
	t.Helper()
	keys := []string{"GITHUB_ACTIONS", "GITLAB_CI", "CIRCLECI", "TRAVIS",
		"BUILDKITE", "JENKINS_URL", "TF_BUILD", "TEAMCITY_VERSION",
		"BITBUCKET_BUILD_NUMBER", "CI"}
	keys = append(keys, config.DefaultKeys()...)
	for _, k := range keys {
		old, ok := os.LookupEnv(k)
		_ = os.Unsetenv(k)
		if ok {
			oldCopy := old
			t.Cleanup(func() { _ = os.Setenv(k, oldCopy) })
		}
	}
}
