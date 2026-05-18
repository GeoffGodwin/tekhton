package finalize

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestBashShimHook_PassesEnvAndExitCodeThrough(t *testing.T) {
	dir := t.TempDir()
	// Write a stub shim script that prints env vars to stdout so the test
	// can assert what the dispatcher would see.
	script := filepath.Join(dir, "shim.sh")
	body := "#!/usr/bin/env bash\n" +
		"echo HOOK=$1\n" +
		"echo PIPELINE_EXIT_CODE=${PIPELINE_EXIT_CODE}\n" +
		"echo TEKHTON_RUN_DISPOSITION=${TEKHTON_RUN_DISPOSITION}\n" +
		"echo TEKHTON_RUN_RESULT_FILE=${TEKHTON_RUN_RESULT_FILE}\n" +
		"echo PROJECT_DIR=${PROJECT_DIR}\n" +
		"echo TEKHTON_HOME=${TEKHTON_HOME}\n" +
		"echo _CURRENT_MILESTONE=${_CURRENT_MILESTONE}\n" +
		"echo MILESTONE_MODE=${MILESTONE_MODE}\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	h := &BashShimHook{
		HookName:    "_hook_demo",
		TekhtonHome: dir,
		ProjectDir:  dir,
		ScriptPath:  script,
	}
	in := &Input{
		ExitCode:      7,
		Disposition:   "failure",
		ResultPath:    "/tmp/RUN_RESULT.json",
		TekhtonHome:   dir,
		ProjectDir:    dir,
		Milestone:     "m21",
		MilestoneMode: true,
		Log:           &out,
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("BashShimHook.Run: %v", err)
	}
	want := []string{
		"HOOK=_hook_demo",
		"PIPELINE_EXIT_CODE=7",
		"TEKHTON_RUN_DISPOSITION=failure",
		"TEKHTON_RUN_RESULT_FILE=/tmp/RUN_RESULT.json",
		"_CURRENT_MILESTONE=m21",
		"MILESTONE_MODE=true",
	}
	got := out.String()
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Errorf("expected output to contain %q; got %q", w, got)
		}
	}
}

func TestBashShimHook_ErrorsWhenScriptMissing(t *testing.T) {
	h := &BashShimHook{
		HookName:    "_hook_x",
		TekhtonHome: "/tmp",
		ScriptPath:  "/nonexistent/shim.sh",
	}
	if err := h.Run(context.Background(), &Input{ProjectDir: "/tmp"}); err == nil {
		t.Errorf("expected error when shim script missing")
	}
}

func TestBashShimHook_PropagatesNonZeroExit(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "shim.sh")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\nexit 5\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	h := &BashShimHook{
		HookName:    "_hook_fail",
		TekhtonHome: dir,
		ProjectDir:  dir,
		ScriptPath:  script,
	}
	err := h.Run(context.Background(), &Input{ProjectDir: dir})
	if err == nil {
		t.Errorf("expected error when shim exits non-zero")
	}
}

func TestBashShimHook_Name(t *testing.T) {
	h := &BashShimHook{HookName: "_hook_x"}
	if got := h.Name(); got != "_hook_x" {
		t.Errorf("Name() = %q, want _hook_x", got)
	}
}

func TestBashShimHook_ErrorsWhenTekhtonHomeEmpty(t *testing.T) {
	h := &BashShimHook{
		HookName:   "_hook_x",
		TekhtonHome: "", // empty — should return error
	}
	err := h.Run(context.Background(), &Input{ProjectDir: "/tmp"})
	if err == nil {
		t.Errorf("expected error when TekhtonHome is empty")
	}
}

func TestBashShimHook_PassesLogDirTimestampMilestoneDisposition(t *testing.T) {
	dir := t.TempDir()
	script := filepath.Join(dir, "shim.sh")
	body := "#!/usr/bin/env bash\n" +
		"echo LOG_DIR=${LOG_DIR}\n" +
		"echo TIMESTAMP=${TIMESTAMP}\n" +
		"echo _CACHED_DISPOSITION=${_CACHED_DISPOSITION}\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	h := &BashShimHook{
		HookName:    "_hook_test",
		TekhtonHome: dir,
		ProjectDir:  dir,
		ScriptPath:  script,
	}
	in := &Input{
		ExitCode:             0,
		ProjectDir:           dir,
		LogDir:               "/tmp/logs",
		Timestamp:            "20260518_120000",
		MilestoneDisposition: "COMPLETE_AND_WAIT",
		Log:                  &out,
	}
	if err := h.Run(context.Background(), in); err != nil {
		t.Fatalf("BashShimHook.Run: %v", err)
	}
	want := []string{
		"LOG_DIR=/tmp/logs",
		"TIMESTAMP=20260518_120000",
		"_CACHED_DISPOSITION=COMPLETE_AND_WAIT",
	}
	got := out.String()
	for _, w := range want {
		if !strings.Contains(got, w) {
			t.Errorf("expected output to contain %q; got %q", w, got)
		}
	}
}
