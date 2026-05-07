package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/prompt"
)

// writePromptFixture seeds <name>.prompt.md inside a fresh promptsDir.
func writePromptFixture(t *testing.T, name, body string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, name+".prompt.md"), []byte(body), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	return dir
}

// runPromptCmd executes `tekhton prompt render` with the supplied args and
// returns stdout, stderr, and the resulting error.
func runPromptCmd(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	cmd := newPromptCmd()
	var stdout, stderr bytes.Buffer
	cmd.SetOut(&stdout)
	cmd.SetErr(&stderr)
	cmd.SetArgs(args)
	err := cmd.Execute()
	return stdout.String(), stderr.String(), err
}

// ---------------------------------------------------------------------------
// resolvePromptsDir
// ---------------------------------------------------------------------------

func TestResolvePromptsDir_Explicit(t *testing.T) {
	t.Setenv("TEKHTON_PROMPTS_DIR", "/from/env")
	t.Setenv("TEKHTON_HOME", "/from/home")
	got, err := resolvePromptsDir("/explicit")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != "/explicit" {
		t.Errorf("got %q, want /explicit", got)
	}
}

func TestResolvePromptsDir_EnvFallback(t *testing.T) {
	t.Setenv("TEKHTON_PROMPTS_DIR", "/from/env")
	t.Setenv("TEKHTON_HOME", "/from/home")
	got, err := resolvePromptsDir("")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != "/from/env" {
		t.Errorf("got %q, want /from/env", got)
	}
}

func TestResolvePromptsDir_HomeFallback(t *testing.T) {
	t.Setenv("TEKHTON_PROMPTS_DIR", "")
	t.Setenv("TEKHTON_HOME", "/tekhton")
	got, err := resolvePromptsDir("")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got != "/tekhton/prompts" {
		t.Errorf("got %q, want /tekhton/prompts", got)
	}
}

func TestResolvePromptsDir_AllEmpty(t *testing.T) {
	t.Setenv("TEKHTON_PROMPTS_DIR", "")
	t.Setenv("TEKHTON_HOME", "")
	if _, err := resolvePromptsDir(""); err == nil {
		t.Errorf("expected error when no source provided")
	}
}

// ---------------------------------------------------------------------------
// loadPromptVars
// ---------------------------------------------------------------------------

func TestLoadPromptVars_FromEnv(t *testing.T) {
	t.Setenv("TEKHTON_PROMPT_TEST_X", "from-env")
	got, err := loadPromptVars("")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got["TEKHTON_PROMPT_TEST_X"] != "from-env" {
		t.Errorf("expected env passthrough; got %q", got["TEKHTON_PROMPT_TEST_X"])
	}
}

func TestLoadPromptVars_FromJSONFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "vars.json")
	if err := os.WriteFile(path, []byte(`{"NAME":"foo","TASK":"do thing"}`), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	got, err := loadPromptVars(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got["NAME"] != "foo" || got["TASK"] != "do thing" {
		t.Errorf("got %v", got)
	}
}

func TestLoadPromptVars_EmptyFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "vars.json")
	if err := os.WriteFile(path, []byte{}, 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	got, err := loadPromptVars(path)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if len(got) != 0 {
		t.Errorf("expected empty map, got %v", got)
	}
}

func TestLoadPromptVars_FileMissing(t *testing.T) {
	if _, err := loadPromptVars("/nope/missing.json"); err == nil {
		t.Errorf("expected error for missing file")
	}
}

func TestLoadPromptVars_BadJSON(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "vars.json")
	if err := os.WriteFile(path, []byte(`not json`), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := loadPromptVars(path); err == nil {
		t.Errorf("expected parse error")
	}
}

// ---------------------------------------------------------------------------
// render subcommand
// ---------------------------------------------------------------------------

func TestPromptRenderCmd_FromEnv(t *testing.T) {
	dir := writePromptFixture(t, "greet", "Hello {{NAME}}.\n")
	t.Setenv("NAME", "tekhton")
	stdout, _, err := runPromptCmd(t, "render", "--template", "greet", "--prompts-dir", dir)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if stdout != "Hello tekhton.\n" {
		t.Errorf("got %q", stdout)
	}
}

func TestPromptRenderCmd_FromVarsFile(t *testing.T) {
	dir := writePromptFixture(t, "greet", "Hello {{NAME}}.\n")
	tmp := t.TempDir()
	varsPath := filepath.Join(tmp, "v.json")
	if err := os.WriteFile(varsPath, []byte(`{"NAME":"file-value"}`), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	stdout, _, err := runPromptCmd(t, "render",
		"--template", "greet",
		"--prompts-dir", dir,
		"--vars-file", varsPath,
	)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if stdout != "Hello file-value.\n" {
		t.Errorf("got %q", stdout)
	}
}

func TestPromptRenderCmd_TaskWrapping(t *testing.T) {
	dir := writePromptFixture(t, "task", "Run: {{TASK}}\n")
	t.Setenv("TASK", "ship m15")
	stdout, _, err := runPromptCmd(t, "render", "--template", "task", "--prompts-dir", dir)
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !strings.Contains(stdout, "--- BEGIN USER TASK") || !strings.Contains(stdout, "--- END USER TASK ---") {
		t.Errorf("expected TASK wrapping; got %q", stdout)
	}
}

func TestPromptRenderCmd_TemplateMissing_ExitCode1(t *testing.T) {
	dir := t.TempDir()
	_, _, err := runPromptCmd(t, "render", "--template", "no_such", "--prompts-dir", dir)
	if err == nil {
		t.Fatal("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitNotFound {
		t.Errorf("err = %v, want errExitCode{exitNotFound}", err)
	}
	if !errors.Is(err, prompt.ErrTemplateNotFound) {
		t.Errorf("expected ErrTemplateNotFound underneath, got %v", err)
	}
}

func TestPromptRenderCmd_MissingTemplateFlag(t *testing.T) {
	dir := t.TempDir()
	_, _, err := runPromptCmd(t, "render", "--prompts-dir", dir)
	if err == nil {
		t.Fatal("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitUsage {
		t.Errorf("err = %v, want errExitCode{exitUsage}", err)
	}
}

func TestPromptRenderCmd_BadVarsFile_UsageExit(t *testing.T) {
	dir := writePromptFixture(t, "greet", "Hello {{NAME}}.\n")
	tmp := t.TempDir()
	varsPath := filepath.Join(tmp, "bad.json")
	if err := os.WriteFile(varsPath, []byte("not json"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, _, err := runPromptCmd(t, "render",
		"--template", "greet",
		"--prompts-dir", dir,
		"--vars-file", varsPath,
	)
	if err == nil {
		t.Fatal("expected error")
	}
	var ec errExitCode
	if !errors.As(err, &ec) || ec.ExitCode() != exitUsage {
		t.Errorf("err = %v, want errExitCode{exitUsage}", err)
	}
}

func TestPromptRenderCmd_ConditionalBlocks(t *testing.T) {
	dir := writePromptFixture(t, "tmpl", "head\n{{IF:X}}\nbody\n{{ENDIF:X}}\nfoot\n")
	t.Run("var set", func(t *testing.T) {
		t.Setenv("X", "1")
		stdout, _, err := runPromptCmd(t, "render", "--template", "tmpl", "--prompts-dir", dir)
		if err != nil {
			t.Fatalf("Execute: %v", err)
		}
		if stdout != "head\nbody\nfoot\n" {
			t.Errorf("got %q", stdout)
		}
	})
	t.Run("var empty", func(t *testing.T) {
		t.Setenv("X", "")
		stdout, _, err := runPromptCmd(t, "render", "--template", "tmpl", "--prompts-dir", dir)
		if err != nil {
			t.Fatalf("Execute: %v", err)
		}
		if stdout != "head\nfoot\n" {
			t.Errorf("got %q", stdout)
		}
	})
}
