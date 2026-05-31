package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/geoffgodwin/tekhton/internal/gates"
)

// uiBashRunner shells back into the still-bash gates_ui.sh + gates_ui_helpers.sh
// for the UI test phase. m31.1 keeps the bash UI gate alive through this
// shim; m31.2 will delete this file and the source lines in tekhton-legacy.sh
// when the native UI phase lands in internal/gates/ui.go.
//
// Invocation shape:
//
//	bash -c "source <tekhton_home>/lib/gates_ui_helpers.sh; source
//	         <tekhton_home>/lib/gates_ui.sh; _run_ui_test_phase '<stage_label>'"
//
// Exit code 0 → StatusPass; non-zero → StatusFail.
type uiBashRunner struct {
	TekhtonHome string
	StageLabel  string
}

// newUIBashRunner constructs the shim runner. Returns nil when
// $TEKHTON_HOME is unset (the shim cannot resolve the bash libs without
// it), which causes UIBashShim.Run to return StatusSkip — matching the
// bash-side guard that aborts the UI phase when its libs are missing.
func newUIBashRunner(stageLabel string) gates.BashShimRunner {
	home := os.Getenv("TEKHTON_HOME")
	if home == "" {
		return nil
	}
	if _, err := os.Stat(filepath.Join(home, "lib", "gates_ui.sh")); err != nil {
		return nil
	}
	return &uiBashRunner{TekhtonHome: home, StageLabel: stageLabel}
}

// Run implements gates.BashShimRunner.
func (r *uiBashRunner) Run(ctx context.Context, stageLabel string, _ map[string]string) (gates.PhaseResult, error) {
	if stageLabel == "" {
		stageLabel = r.StageLabel
	}
	if stageLabel == "" {
		stageLabel = "unknown"
	}
	script := "set -uo pipefail\n" +
		"# shellcheck source=/dev/null\n" +
		"source \"${TEKHTON_HOME}/lib/common.sh\"\n" +
		"# shellcheck source=/dev/null\n" +
		"source \"${TEKHTON_HOME}/lib/gates_ui_helpers.sh\"\n" +
		"# shellcheck source=/dev/null\n" +
		"source \"${TEKHTON_HOME}/lib/gates_ui.sh\"\n" +
		"_run_ui_test_phase \"$1\""
	c := exec.CommandContext(ctx, "bash", "-c", script, "_ui_phase", stageLabel)
	c.Stdin = nil
	c.Stdout = os.Stdout
	c.Stderr = os.Stderr
	c.Env = append(os.Environ(), "TEKHTON_HOME="+r.TekhtonHome)
	err := c.Run()
	if err == nil {
		return gates.PhaseResult{Status: gates.StatusPass}, nil
	}
	if _, ok := err.(*exec.ExitError); ok {
		return gates.PhaseResult{Status: gates.StatusFail, Err: err}, nil
	}
	return gates.PhaseResult{Status: gates.StatusFail, Err: err}, err
}
