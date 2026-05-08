package stagerunner

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// stageHarness writes a fake TekhtonHome layout under t.TempDir() with:
//   - lib/common.sh and lib/stage_envelope.sh (no-op stubs)
//   - stages/<name>.sh defining run_stage_<name>
//
// The stage script is plain bash so tests don't need a real tekhton binary;
// it writes the result envelope itself via a heredoc to TEKHTON_STAGE_RESULT_FILE.
func stageHarness(t *testing.T, stage, body string) (string, string) {
	t.Helper()
	home := t.TempDir()
	proj := t.TempDir()

	if err := os.MkdirAll(filepath.Join(home, "lib"), 0o755); err != nil {
		t.Fatalf("mkdir lib: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(home, "stages"), 0o755); err != nil {
		t.Fatalf("mkdir stages: %v", err)
	}
	writeFile(t, filepath.Join(home, "lib", "common.sh"), "# stub\n")
	writeFile(t, filepath.Join(home, "lib", "stage_envelope.sh"), "# stub\n")
	writeFile(t, filepath.Join(home, "stages", stage+".sh"), body)
	return home, proj
}

func writeFile(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestBashAdapterRoundTrip(t *testing.T) {
	body := `run_stage_intake() {
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<'JSON'
{
  "proto": "tekhton.stage.result.v1",
  "stage": "intake",
  "verdict": "pass",
  "exit_reason": "ok",
  "agent_calls": 1,
  "duration_sec": 0,
  "human_action_required": false,
  "next_action": "accept"
}
JSON
}
`
	home, proj := stageHarness(t, "intake", body)
	resultPath := filepath.Join(proj, "result.json")

	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		Task:       "x",
		ResultFile: resultPath,
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict: got %q want pass", res.Verdict)
	}
	if res.NextAction != "accept" {
		t.Fatalf("next_action: got %q want accept", res.NextAction)
	}
}

func TestBashAdapterMissingResultFile(t *testing.T) {
	body := `run_stage_intake() {
  : # do nothing — leaves result file empty
}
`
	home, proj := stageHarness(t, "intake", body)
	resultPath := filepath.Join(proj, "result.json")

	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: resultPath,
	}
	res, err := a.Run(context.Background(), req)
	if err == nil {
		t.Fatalf("expected error for missing result file")
	}
	if !errors.Is(err, ErrMissingResultFile) {
		t.Fatalf("error not ErrMissingResultFile: %v", err)
	}
	// Synthetic fail result should be returned so callers can short-circuit.
	if res == nil {
		t.Fatalf("expected synthetic fail result, got nil")
	}
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("synthetic verdict: got %q want fail", res.Verdict)
	}
}

func TestBashAdapterSubprocessError(t *testing.T) {
	// Stage exits non-zero without writing envelope.
	body := `run_stage_intake() {
  return 7
}
`
	home, proj := stageHarness(t, "intake", body)
	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	res, err := a.Run(context.Background(), req)
	if err == nil {
		t.Fatalf("expected error from non-zero subprocess exit")
	}
	if !errors.Is(err, ErrSubprocess) && !errors.Is(err, ErrMissingResultFile) {
		t.Fatalf("error not subprocess/missing-result: %v", err)
	}
	if res == nil || res.Verdict != proto.VerdictFail {
		t.Fatalf("expected synthetic fail result, got %+v", res)
	}
}

func TestBashAdapterUnknownStage(t *testing.T) {
	// scriptFor's fallback to DefaultStageScripts means we cannot reach
	// ErrUnknownStage by passing a known stage name; the only way is via
	// scriptFor returning false directly for an unknown stage. The Run path
	// would reject that earlier in StageRequestV1.Validate (IsKnownStage).
	// Cover scriptFor's negative branch here.
	if _, ok := (&BashAdapter{}).scriptFor("does-not-exist"); ok {
		t.Fatalf("scriptFor should reject unknown stage")
	}
}

func TestBashAdapterContextCanceled(t *testing.T) {
	body := `run_stage_intake() {
  sleep 2
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<'JSON'
{"proto":"tekhton.stage.result.v1","stage":"intake","verdict":"pass","exit_reason":"ok","agent_calls":0,"duration_sec":0,"human_action_required":false}
JSON
}
`
	home, proj := stageHarness(t, "intake", body)
	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	_, err := a.Run(ctx, req)
	if err == nil {
		t.Fatalf("expected error on context cancel")
	}
}

func TestBashAdapterEnvOverridesPropagate(t *testing.T) {
	body := `run_stage_intake() {
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<JSON
{"proto":"tekhton.stage.result.v1","stage":"intake","verdict":"pass","exit_reason":"FOO=${FOO:-unset}","agent_calls":0,"duration_sec":0,"human_action_required":false}
JSON
}
`
	home, proj := stageHarness(t, "intake", body)
	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}
	req := &proto.StageRequestV1{
		Proto:        proto.StageRequestProtoV1,
		Stage:        proto.StageIntake,
		EnvOverrides: map[string]string{"FOO": "bar"},
		ResultFile:   filepath.Join(proj, "result.json"),
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.ExitReason != "FOO=bar" {
		t.Fatalf("env override did not propagate: exit_reason=%q", res.ExitReason)
	}
}

func TestBashAdapterLogTeed(t *testing.T) {
	body := `run_stage_intake() {
  echo "hello from stage"
  cat > "$TEKHTON_STAGE_RESULT_FILE" <<'JSON'
{"proto":"tekhton.stage.result.v1","stage":"intake","verdict":"pass","exit_reason":"ok","agent_calls":0,"duration_sec":0,"human_action_required":false}
JSON
}
`
	home, proj := stageHarness(t, "intake", body)
	logFile := filepath.Join(proj, "stage.log")
	var buf bytes.Buffer
	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj, LogWriter: &buf}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		LogFile:    logFile,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	if _, err := a.Run(context.Background(), req); err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !bytes.Contains(buf.Bytes(), []byte("hello from stage")) {
		t.Fatalf("LogWriter did not receive stdout; got %q", buf.String())
	}
	logBytes, err := os.ReadFile(logFile)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if !bytes.Contains(logBytes, []byte("hello from stage")) {
		t.Fatalf("LogFile did not receive stdout; got %q", string(logBytes))
	}
}

func TestBashAdapterInvalidResult(t *testing.T) {
	body := `run_stage_intake() {
  echo "not json" > "$TEKHTON_STAGE_RESULT_FILE"
}
`
	home, proj := stageHarness(t, "intake", body)
	a := &BashAdapter{TekhtonHome: home, ProjectDir: proj}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: filepath.Join(proj, "result.json"),
	}
	res, err := a.Run(context.Background(), req)
	if err == nil {
		t.Fatalf("expected ErrInvalidResult")
	}
	if !errors.Is(err, ErrInvalidResult) {
		t.Fatalf("error not ErrInvalidResult: %v", err)
	}
	if res == nil || res.Verdict != proto.VerdictFail {
		t.Fatalf("expected synthetic fail result, got %+v", res)
	}
}

func TestBashAdapterNilRequest(t *testing.T) {
	a := &BashAdapter{TekhtonHome: t.TempDir(), ProjectDir: t.TempDir()}
	if _, err := a.Run(context.Background(), nil); err == nil {
		t.Fatalf("expected error for nil request")
	}
}

func TestScriptForFallback(t *testing.T) {
	a := &BashAdapter{}
	if _, ok := a.scriptFor(proto.StageCoder); !ok {
		t.Fatalf("default fallback should resolve coder")
	}
	if _, ok := a.scriptFor("nope"); ok {
		t.Fatalf("scriptFor should reject unknown")
	}
	a.StageScript = map[string]string{proto.StageCoder: "stages/custom.sh"}
	p, ok := a.scriptFor(proto.StageCoder)
	if !ok || p != "stages/custom.sh" {
		t.Fatalf("override path lost: %q ok=%v", p, ok)
	}
}
