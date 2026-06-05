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

// newAdapter builds an adapter rooted at home/proj with no extra lib helpers
// sourced — the unit tests below stub only common.sh and stage_envelope.sh,
// so we explicitly opt out of the production DefaultLibHelpers list and the
// per-stage Helpers slices in DefaultStageDefs (both sets reference lib/*.sh
// files the harness does not write). New tests that exercise helper sourcing
// override Stages explicitly.
func newAdapter(home, proj string) *BashAdapter {
	stages := make(map[string]StageDef, len(DefaultStageDefs))
	for k, v := range DefaultStageDefs {
		script := v.Script
		// m36.3 cleanup: stages ported to Go (docs/cleanup/security/architect/
		// intake) have no bash Script in DefaultStageDefs. The adapter tests
		// stage-harness writes stages/<name>.sh; default the override path
		// so those tests can drive the bash dispatch path against the stub.
		if script == "" {
			script = "stages/" + k + ".sh"
		}
		stages[k] = StageDef{Script: script}
	}
	return &BashAdapter{
		TekhtonHome: home,
		ProjectDir:  proj,
		LibHelpers:  []string{},
		Stages:      stages,
	}
}

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

	a := newAdapter(home, proj)
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

	a := newAdapter(home, proj)
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
	a := newAdapter(home, proj)
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
	if _, ok := (&BashAdapter{}).stageDefFor("does-not-exist"); ok {
		t.Fatalf("stageDefFor should reject unknown stage")
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
	a := newAdapter(home, proj)

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
	a := newAdapter(home, proj)
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
	a := newAdapter(home, proj)
	a.LogWriter = &buf
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
	a := newAdapter(home, proj)
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

// TestBashAdapter_Run_GoDispatch asserts the m34.1 dispatch wedge: when a
// stage's StageDef carries a non-nil GoImpl, BashAdapter.Run invokes it and
// never reaches the bash subprocess path. The recording GoImpl flips a flag
// and the BashBin is a sentinel that would fail with ENOENT if the bash path
// ran — so a successful pass result proves the wedge short-circuited.
func TestBashAdapter_Run_GoDispatch(t *testing.T) {
	called := false
	gotStage := ""
	a := &BashAdapter{
		BashBin: "/nonexistent/bash",
		Stages: map[string]StageDef{
			proto.StageIntake: {
				GoImpl: func(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
					called = true
					gotStage = req.Stage
					return &proto.StageResultV1{
						Proto:      proto.StageResultProtoV1,
						Stage:      req.Stage,
						Verdict:    proto.VerdictPass,
						ExitReason: "ok",
					}, nil
				},
			},
		},
	}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: "/tmp/x",
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if !called {
		t.Fatal("GoImpl not invoked")
	}
	if gotStage != proto.StageIntake {
		t.Fatalf("GoImpl saw stage=%q want %q", gotStage, proto.StageIntake)
	}
	if res.Verdict != proto.VerdictPass {
		t.Fatalf("verdict=%q want pass", res.Verdict)
	}
	if res.Proto != proto.StageResultProtoV1 {
		t.Fatalf("proto not stamped: %q", res.Proto)
	}
}

// TestBashAdapter_Run_GoDispatch_NilResult asserts the wedge gracefully
// handles a Go stage that returns (nil, err). The adapter must propagate the
// error rather than dereferencing nil.
func TestBashAdapter_Run_GoDispatch_NilResult(t *testing.T) {
	wantErr := errors.New("go-stage-error")
	a := &BashAdapter{
		BashBin: "/nonexistent/bash",
		Stages: map[string]StageDef{
			proto.StageIntake: {
				GoImpl: func(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
					return nil, wantErr
				},
			},
		},
	}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: "/tmp/x",
	}
	res, err := a.Run(context.Background(), req)
	if err == nil || err.Error() != wantErr.Error() {
		t.Fatalf("err=%v want %v", err, wantErr)
	}
	if res != nil {
		t.Fatalf("expected nil result, got %+v", res)
	}
}

// TestBashAdapter_Run_GoDispatch_StampsDuration asserts the wedge fills in
// DurationSec when the Go stage left it zero, using the BashAdapter.Now hook
// so the timing math is deterministic.
func TestBashAdapter_Run_GoDispatch_StampsDuration(t *testing.T) {
	t0 := time.Date(2026, 6, 1, 0, 0, 0, 0, time.UTC)
	calls := 0
	a := &BashAdapter{
		BashBin: "/nonexistent/bash",
		Now: func() time.Time {
			calls++
			// First call (start) → t0; subsequent calls (end) → t0 + 7s.
			if calls == 1 {
				return t0
			}
			return t0.Add(7 * time.Second)
		},
		Stages: map[string]StageDef{
			proto.StageIntake: {
				GoImpl: func(ctx context.Context, req *proto.StageRequestV1) (*proto.StageResultV1, error) {
					return &proto.StageResultV1{
						Stage:   req.Stage,
						Verdict: proto.VerdictPass,
					}, nil
				},
			},
		},
	}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageIntake,
		ResultFile: "/tmp/x",
	}
	res, err := a.Run(context.Background(), req)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}
	if res.DurationSec != 7 {
		t.Fatalf("DurationSec=%d want 7", res.DurationSec)
	}
}

func TestStageDefForFallback(t *testing.T) {
	a := &BashAdapter{}
	if _, ok := a.stageDefFor(proto.StageCoder); !ok {
		t.Fatalf("default fallback should resolve coder")
	}
	if _, ok := a.stageDefFor("nope"); ok {
		t.Fatalf("stageDefFor should reject unknown")
	}
	a.Stages = map[string]StageDef{proto.StageCoder: {Script: "stages/custom.sh"}}
	def, ok := a.stageDefFor(proto.StageCoder)
	if !ok || def.Script != "stages/custom.sh" {
		t.Fatalf("override path lost: %q ok=%v", def.Script, ok)
	}
}
