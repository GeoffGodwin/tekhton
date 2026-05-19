package finalize

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestShimEnvHasContract is the m26 acceptance criterion for the
// finalize/shim consumer side. Every finalize hook must see the full
// composed env when the runner populates Input.EnvKV — not just the
// MILESTONE_MODE/_CURRENT_MILESTONE subset the legacy buildEnv synthesized.
//
// Inputs mirror what runner.BashHookRunner.Finalize hands the orchestrator
// after wiring runner.EnvBuilder into the chain: EnvKV pre-composed via
// AsKV, including config keys, runtime flags, and the LOG_FILE the chain
// resolved.
func TestShimEnvHasContract(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "shim.sh")
	body := "#!/usr/bin/env bash\n" +
		"set -u\n" +
		"echo MILESTONE_MODE=${MILESTONE_MODE}\n" +
		"echo _CURRENT_MILESTONE=${_CURRENT_MILESTONE}\n" +
		"echo TASK=${TASK}\n" +
		"echo AUTO_ADVANCE=${AUTO_ADVANCE}\n" +
		"echo HUMAN_MODE=${HUMAN_MODE}\n" +
		"echo HUMAN_NOTES_TAG=${HUMAN_NOTES_TAG}\n" +
		"echo LOG_FILE=${LOG_FILE}\n" +
		"echo PROJECT_NAME=${PROJECT_NAME}\n" +
		"echo ANALYZE_CMD=${ANALYZE_CMD}\n" +
		"echo PIPELINE_EXIT_CODE=${PIPELINE_EXIT_CODE}\n" +
		"echo TEKHTON_RUN_DISPOSITION=${TEKHTON_RUN_DISPOSITION}\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	// Pre-composed EnvKV — what runner.BashHookRunner.Finalize would build
	// via EnvBuilder.AsKV in production.
	envKV := []string{
		"MILESTONE_MODE=true",
		"_CURRENT_MILESTONE=m26",
		"TASK=stage env contract",
		"AUTO_ADVANCE=true",
		"HUMAN_MODE=false",
		"HUMAN_NOTES_TAG=",
		"LOG_DIR=/tmp/logs",
		"TIMESTAMP=20260519_120000",
		"LOG_FILE=/tmp/logs/20260519_120000_m26.log",
		"PROJECT_NAME=tekhton",
		"ANALYZE_CMD=shellcheck tekhton.sh",
		"CLAUDE_STANDARD_MODEL=claude-opus-4-7",
	}

	var out bytes.Buffer
	h := &BashShimHook{
		HookName:    "_hook_demo",
		TekhtonHome: dir,
		ProjectDir:  dir,
		ScriptPath:  script,
	}
	in := &Input{
		ExitCode:    0,
		Disposition: "success",
		ProjectDir:  dir,
		TekhtonHome: dir,
		EnvKV:       envKV,
		Log:         &out,
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("BashShimHook.Run: %v\noutput: %s", err, out.String())
	}

	got := out.String()
	wants := []string{
		"MILESTONE_MODE=true",
		"_CURRENT_MILESTONE=m26",
		"TASK=stage env contract",
		"AUTO_ADVANCE=true",
		"HUMAN_MODE=false",
		"LOG_FILE=/tmp/logs/20260519_120000_m26.log",
		"PROJECT_NAME=tekhton",
		"ANALYZE_CMD=shellcheck tekhton.sh",
		"PIPELINE_EXIT_CODE=0",
		"TEKHTON_RUN_DISPOSITION=success",
	}
	for _, w := range wants {
		if !strings.Contains(got, w) {
			t.Errorf("env contract: expected %q in shim output; got:\n%s", w, got)
		}
	}
}

// TestShimEnvLegacyFallback — when EnvKV is nil (the migration-window
// compat path), the shim must still synthesize MILESTONE_MODE / TASK so
// existing tests and the `tekhton finalize` debug subcommand keep
// working. Guards against accidentally deleting the fallback when the
// last in-process caller migrates.
func TestShimEnvLegacyFallback_PopulatesMinimumRuntimeFlags(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "shim.sh")
	body := "#!/usr/bin/env bash\n" +
		"set -u\n" +
		"echo MILESTONE_MODE=${MILESTONE_MODE}\n" +
		"echo _CURRENT_MILESTONE=${_CURRENT_MILESTONE:-}\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	h := &BashShimHook{
		HookName:    "_hook_x",
		TekhtonHome: dir,
		ProjectDir:  dir,
		ScriptPath:  script,
	}
	in := &Input{
		ProjectDir:    dir,
		Milestone:     "m26",
		MilestoneMode: true,
		Log:           &out,
		// EnvKV deliberately omitted — exercises legacyEnvFallback.
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("BashShimHook.Run: %v\noutput: %s", err, out.String())
	}
	got := out.String()
	if !strings.Contains(got, "MILESTONE_MODE=true") {
		t.Errorf("legacy fallback should still export MILESTONE_MODE=true; got %q", got)
	}
	if !strings.Contains(got, "_CURRENT_MILESTONE=m26") {
		t.Errorf("legacy fallback should still export _CURRENT_MILESTONE=m26; got %q", got)
	}
}
