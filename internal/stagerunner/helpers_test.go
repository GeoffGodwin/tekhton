package stagerunner

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestBashAdapterMissingHelperFailsOnce reproduces the exit-127 bug from the
// HUMAN_NOTES.md report: a stage that calls a function defined in an un-sourced
// helper must fail once with ErrSubprocess. The subprocess wrapper itself
// must not retry — that's the orchestrator's job — so a single Run() invocation
// produces exactly one log entry, not 147.
func TestBashAdapterMissingHelperFailsOnce(t *testing.T) {
	body := `run_stage_intake() {
  _missing_helper_func
}
`
	home, proj := stageHarness(t, "intake", body)
	logFile := filepath.Join(proj, "stage.log")
	a := newAdapter(home, proj)
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		LogFile:    logFile,
		ResultFile: filepath.Join(proj, "result.json"),
	}

	res, err := a.Run(context.Background(), req)
	if err == nil {
		t.Fatalf("expected error from missing helper, got nil")
	}
	if !errors.Is(err, ErrSubprocess) && !errors.Is(err, ErrMissingResultFile) {
		t.Fatalf("error not subprocess/missing-result: %v", err)
	}
	if res == nil || res.Verdict != proto.VerdictFail {
		t.Fatalf("expected synthetic fail result, got %+v", res)
	}

	logBytes, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	count := strings.Count(string(logBytes), "_missing_helper_func")
	if count == 0 {
		t.Fatalf("log did not record the missing helper call: %q", string(logBytes))
	}
	// `set -e` aborts on the first failure, so the bash subprocess sees the
	// error exactly once. The 147-retry bug from HUMAN_NOTES.md happens above
	// the adapter; the adapter itself must not contribute extra invocations.
	if count > 2 {
		t.Fatalf("missing helper logged %d times; expected 1-2 (single subprocess invocation)", count)
	}
}

// TestBashAdapterPerStageHelperSourced proves the fix: when a stage's StageDef
// declares a helper, that helper is sourced before run_stage_<name> runs and
// functions defined in it resolve normally.
func TestBashAdapterPerStageHelperSourced(t *testing.T) {
	home, proj := stageHarness(t, "intake", `run_stage_intake() {
  local out
  out=$(_intake_get_milestone_content)
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<JSON
{"proto":"tekhton.stage.result.v1","stage":"intake","verdict":"pass","exit_reason":"$out","agent_calls":0,"duration_sec":0,"human_action_required":false}
JSON
}
`)
	// Write a stub helper that defines the function the stage calls.
	helperPath := filepath.Join(home, "lib", "intake_helpers.sh")
	if err := os.WriteFile(helperPath, []byte(`_intake_get_milestone_content() { echo "from-helper"; }
`), 0o644); err != nil {
		t.Fatalf("write helper: %v", err)
	}

	a := newAdapter(home, proj)
	a.Stages[proto.StageIntake] = StageDef{
		Script:  "stages/intake.sh",
		Helpers: []string{"lib/intake_helpers.sh"},
	}

	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
	if res.ExitReason != "from-helper" {
		t.Fatalf("helper output not propagated: exit_reason=%q", res.ExitReason)
	}
}

// TestBashAdapterLibHelpersSourced exercises the common base helper list so a
// stage that calls into a function from DefaultLibHelpers (via override here)
// runs successfully. The fix delivers V3 parity by recreating the legacy
// global source block; this test asserts the wiring works.
func TestBashAdapterLibHelpersSourced(t *testing.T) {
	home, proj := stageHarness(t, "coder", `run_stage_coder() {
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<JSON
{"proto":"tekhton.stage.result.v1","stage":"coder","verdict":"pass","exit_reason":"$(common_marker)","agent_calls":0,"duration_sec":0,"human_action_required":false}
JSON
}
`)
	commonHelper := filepath.Join(home, "lib", "shared_marker.sh")
	if err := os.WriteFile(commonHelper, []byte(`common_marker() { echo "lib-helper-ran"; }
`), 0o644); err != nil {
		t.Fatalf("write helper: %v", err)
	}

	a := newAdapter(home, proj)
	a.LibHelpers = []string{"lib/shared_marker.sh"}

	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ExitReason != "lib-helper-ran" {
		t.Fatalf("LibHelpers not sourced: exit_reason=%q", res.ExitReason)
	}
}

// TestDefaultStageDefsCoverage asserts every stage in proto.KnownStages has a
// definition in DefaultStageDefs — keeps the registry in sync with the proto
// vocabulary so a new StageX constant can't ship without a script mapping.
// Ranges over proto.KnownStages (the canonical source) rather than a local
// copy so adding a new constant fails this test until DefaultStageDefs grows
// the corresponding entry.
func TestDefaultStageDefsCoverage(t *testing.T) {
	for _, s := range proto.KnownStages {
		def, ok := DefaultStageDefs[s]
		if !ok {
			t.Errorf("DefaultStageDefs missing stage %q", s)
			continue
		}
		if def.Script == "" {
			t.Errorf("DefaultStageDefs[%q].Script is empty", s)
		}
	}
}

// TestStageDefForOverridePreservesHelpers asserts that overriding Stages with
// a definition that includes Helpers carries those helpers through to
// stageDefFor (and thus to the bash wrapper). The legacy adapter only stored
// the script path; this is the new contract.
func TestStageDefForOverridePreservesHelpers(t *testing.T) {
	a := &BashAdapter{
		Stages: map[string]StageDef{
			proto.StageIntake: {
				Script:  "stages/intake.sh",
				Helpers: []string{"lib/foo.sh", "lib/bar.sh"},
			},
		},
	}
	def, ok := a.stageDefFor(proto.StageIntake)
	if !ok {
		t.Fatalf("stageDefFor returned not-found for known stage")
	}
	if len(def.Helpers) != 2 || def.Helpers[0] != "lib/foo.sh" {
		t.Fatalf("Helpers not preserved through override: %#v", def.Helpers)
	}
}

// TestBuildBashScriptOrdering asserts the source order: lib/common.sh first,
// then DefaultLibHelpers, then per-stage Helpers, then lib/stage_envelope.sh,
// then the stage script. Matters because lib/failure_context.sh must precede
// lib/diagnose_output.sh, etc. (see legacy tekhton.sh comments).
func TestBuildBashScriptOrdering(t *testing.T) {
	out := buildBashScript(
		"/home", "/proj", "/home/stages/intake.sh", "intake",
		[]string{"lib/lib_a.sh", "lib/lib_b.sh"},
		[]string{"lib/stage_a.sh"},
	)
	libA := strings.Index(out, "/home/lib/lib_a.sh")
	libB := strings.Index(out, "/home/lib/lib_b.sh")
	stageA := strings.Index(out, "/home/lib/stage_a.sh")
	envelope := strings.Index(out, "stage_envelope.sh")
	script := strings.Index(out, "/home/stages/intake.sh")
	common := strings.Index(out, "/lib/common.sh")
	for _, c := range []struct {
		name string
		idx  int
	}{
		{"common", common}, {"libA", libA}, {"libB", libB},
		{"stageA", stageA}, {"envelope", envelope}, {"script", script},
	} {
		if c.idx < 0 {
			t.Fatalf("ordering token %s not present in script:\n%s", c.name, out)
		}
	}
	if !(common < libA && libA < libB && libB < stageA && stageA < envelope && envelope < script) {
		t.Fatalf("source order violated:\ncommon=%d libA=%d libB=%d stageA=%d envelope=%d script=%d\n%s",
			common, libA, libB, stageA, envelope, script, out)
	}
}

// TestBuildBashScriptExportsRequiredEnv asserts the wrapper exports both
// TEKHTON_HOME and PROJECT_DIR before any source line. lib/config.sh:14
// references ${PROJECT_DIR} without a default at file-scope, so under the
// `set -u` enforced at the top of the wrapper, an unset PROJECT_DIR causes
// the very first DefaultLibHelpers source to die — the entire stage subprocess
// then exits before run_stage_<name> ever runs. Regression guard for the
// post-a42c30b BashAdapter bug (test_pipeline_runner.sh started failing).
func TestBuildBashScriptExportsRequiredEnv(t *testing.T) {
	out := buildBashScript(
		"/home", "/proj", "/home/stages/intake.sh", "intake",
		[]string{"lib/config.sh"},
		nil,
	)
	tekhtonExport := strings.Index(out, `export TEKHTON_HOME="/home"`)
	projectExport := strings.Index(out, `export PROJECT_DIR="/proj"`)
	firstSource := strings.Index(out, "source ")
	if tekhtonExport < 0 {
		t.Fatalf("TEKHTON_HOME export missing from wrapper:\n%s", out)
	}
	if projectExport < 0 {
		t.Fatalf("PROJECT_DIR export missing from wrapper (lib/config.sh requires it under set -u):\n%s", out)
	}
	if firstSource < 0 {
		t.Fatalf("no source line found in wrapper:\n%s", out)
	}
	if !(tekhtonExport < firstSource && projectExport < firstSource) {
		t.Fatalf("env exports must precede first source line: tekhtonExport=%d projectExport=%d firstSource=%d\n%s",
			tekhtonExport, projectExport, firstSource, out)
	}
}
