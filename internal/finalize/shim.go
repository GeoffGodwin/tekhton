package finalize

import (
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
)

// BashShimHook implements Hook by execing lib/finalize_shim.sh once with the
// hook name as $1. The shim dispatcher sources the bash files this hook
// needs, then calls the bash hook function. One process per hook is
// intentional — follow-up milestones (m22..m25) replace BashShimHook
// instances with pure-Go bodies one entry at a time without disturbing the
// remaining shim cases.
type BashShimHook struct {
	HookName    string
	TekhtonHome string
	ProjectDir  string

	// ScriptPath overrides the default lib/finalize_shim.sh location.
	// Tests use this to point at a stub shim.
	ScriptPath string

	// LookPath overrides exec.LookPath for tests.
	LookPath func(name string) (string, error)
}

// Name returns the bash hook function name.
func (b *BashShimHook) Name() string { return b.HookName }

// Run execs the shim dispatcher with the hook name. The shim is responsible
// for sourcing the right bash files and invoking the function — this Go
// side passes through Env, ExitCode (as PIPELINE_EXIT_CODE), and the result
// file path so existing bash bodies see the same environment they did when
// the orchestrator was bash.
func (b *BashShimHook) Run(ctx context.Context, in *Input) error {
	if b.TekhtonHome == "" {
		return fmt.Errorf("shim: tekhton home not configured for hook %q", b.HookName)
	}
	script := b.ScriptPath
	if script == "" {
		script = filepath.Join(b.TekhtonHome, "lib", "finalize_shim.sh")
	}
	if _, err := os.Stat(script); err != nil {
		// Shim missing is treated as a no-op during the m21 cutover window.
		// The orchestrator logs the per-hook error itself — we surface a
		// typed error rather than swallow it so tests can assert behavior.
		return fmt.Errorf("shim: dispatcher missing at %s: %w", script, err)
	}
	bashPath := "bash"
	if b.LookPath != nil {
		if p, err := b.LookPath("bash"); err == nil {
			bashPath = p
		}
	}
	cmd := exec.CommandContext(ctx, bashPath, script, b.HookName)
	cmd.Dir = in.ProjectDir
	if cmd.Dir == "" {
		cmd.Dir = b.ProjectDir
	}
	cmd.Stdout = orWriter(in.Log, os.Stderr)
	cmd.Stderr = orWriter(in.Log, os.Stderr)
	cmd.Env = b.buildEnv(in)
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("shim: hook %q failed: %w", b.HookName, err)
	}
	return nil
}

// buildEnv composes the environment passed to the bash subprocess. It layers
// in.Env over the current process env so callers can override specific keys
// without losing PATH, HOME, etc. The PIPELINE_EXIT_CODE / TEKHTON_RUN_*
// variables are stamped last so in.Env cannot accidentally shadow them.
func (b *BashShimHook) buildEnv(in *Input) []string {
	env := os.Environ()
	if len(in.Env) > 0 {
		env = append(env, in.Env...)
	}
	tekhtonHome := b.TekhtonHome
	if tekhtonHome == "" {
		tekhtonHome = in.TekhtonHome
	}
	projectDir := b.ProjectDir
	if projectDir == "" {
		projectDir = in.ProjectDir
	}
	env = append(env,
		"TEKHTON_HOME="+tekhtonHome,
		"PROJECT_DIR="+projectDir,
		"PIPELINE_EXIT_CODE="+strconv.Itoa(in.ExitCode),
		"TEKHTON_RUN_DISPOSITION="+in.Disposition,
	)
	if in.ResultPath != "" {
		env = append(env, "TEKHTON_RUN_RESULT_FILE="+in.ResultPath)
	}
	if in.LogDir != "" {
		env = append(env, "LOG_DIR="+in.LogDir)
	}
	if in.Timestamp != "" {
		env = append(env, "TIMESTAMP="+in.Timestamp)
	}
	// LOG_FILE is constructed by tekhton-legacy.sh as
	// "${LOG_DIR}/${TIMESTAMP}_${TASK_SLUG}.log". The Go orchestrator owns
	// neither variable name nor a task slug, so we synthesize a finalize-
	// scoped log file from LogDir + Timestamp. Hooks like _hook_final_checks
	// (lib/finalize_core_hooks.sh:26 → run_final_checks "$LOG_FILE") rely on
	// LOG_FILE being a writable path; without it `set -u` trips immediately.
	if in.LogDir != "" {
		ts := in.Timestamp
		if ts == "" {
			ts = "run"
		}
		env = append(env, "LOG_FILE="+filepath.Join(in.LogDir, ts+"_finalize.log"))
	}
	if in.Milestone != "" {
		env = append(env, "_CURRENT_MILESTONE="+in.Milestone)
	}
	if in.MilestoneMode {
		env = append(env, "MILESTONE_MODE=true")
	}
	if in.MilestoneDisposition != "" {
		env = append(env, "_CACHED_DISPOSITION="+in.MilestoneDisposition)
	}
	return env
}

func orWriter(w io.Writer, fallback io.Writer) io.Writer {
	if w != nil {
		return w
	}
	return fallback
}
