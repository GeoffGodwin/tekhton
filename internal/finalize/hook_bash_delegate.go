package finalize

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
)

// runBashHookFn execs `bash -c "source SCRIPT; FN"` so a Go-native
// hook can delegate the residual bash portion of its work to a single
// file rather than going through finalize_shim.sh. Used by the three
// m24 hooks that touch subsystems still owned by bash (test_baseline,
// express, failure_context) while their respective ports land in
// later milestones (m25+).
//
// Logging mirrors BashShimHook: stdout and stderr from the bash
// subprocess go to the hook's logWriter. The function does not return
// an error — bash hook bodies historically swallowed failures, and
// the finalize chain is continue-on-error anyway.
func runBashHookFn(ctx context.Context, in *Input, sourceScript, fnName string) {
	if sourceScript == "" || fnName == "" {
		return
	}
	if _, err := os.Stat(sourceScript); err != nil {
		// The script is optional — if it's missing we treat the hook
		// as a no-op rather than logging noise.
		return
	}
	cmd := exec.CommandContext(ctx, "bash", "-c",
		fmt.Sprintf(". %q; if declare -f %s >/dev/null 2>&1; then %s %d; fi",
			sourceScript, fnName, fnName, in.ExitCode))
	cmd.Dir = in.ProjectDir
	cmd.Stdout = logWriter(in)
	cmd.Stderr = logWriter(in)
	cmd.Env = bashDelegateEnv(in)
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(logWriter(in), "%s: %v\n", fnName, err)
	}
}

// bashDelegateEnv builds the env for a bash delegate. Includes the
// parent process env, then layers PROJECT_DIR / TEKHTON_HOME /
// PIPELINE_EXIT_CODE so the function sees the same shell globals it
// would have when sourced through finalize_shim.sh.
func bashDelegateEnv(in *Input) []string {
	env := append([]string(nil), os.Environ()...)
	if in.ProjectDir != "" {
		env = append(env, "PROJECT_DIR="+in.ProjectDir)
	}
	if in.TekhtonHome != "" {
		env = append(env, "TEKHTON_HOME="+in.TekhtonHome)
	}
	env = append(env, fmt.Sprintf("PIPELINE_EXIT_CODE=%d", in.ExitCode))
	if in.Milestone != "" {
		env = append(env, "_CURRENT_MILESTONE="+in.Milestone)
	}
	if in.LogDir != "" {
		env = append(env, "LOG_DIR="+in.LogDir)
	}
	if in.Timestamp != "" {
		env = append(env, "TIMESTAMP="+in.Timestamp)
	}
	if in.MilestoneMode {
		env = append(env, "MILESTONE_MODE=true")
	}
	if in.MilestoneDisposition != "" {
		env = append(env, "_CACHED_DISPOSITION="+in.MilestoneDisposition)
	}
	for _, kv := range in.EnvKV {
		env = append(env, kv)
	}
	for _, kv := range in.Env {
		env = append(env, kv)
	}
	return env
}

// fileExists is a tiny stat wrapper used by the hooks before they
// invoke runBashHookFn, so they can skip the exec entirely when the
// target file is absent.
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// resolveTekhtonLib joins the tekhton home with a lib path. Returns
// the empty string when home is unset.
func resolveTekhtonLib(home, name string) string {
	if home == "" {
		return ""
	}
	return filepath.Join(home, "lib", name)
}
