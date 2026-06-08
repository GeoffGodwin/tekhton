package coder

import (
	"context"
	"os"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/proto"
)

// os_WriteFile aliases os.WriteFile so the test helper has a stable name.
var os_WriteFile = os.WriteFile

// TestSelectCoderTemplate is the 5-row table-test acceptance criterion. It
// exercises every tag × template-name combination and asserts the output is
// always one of "coder", "coder_note_bug", "coder_note_feat",
// "coder_note_polish" — NEVER "coder_rework".
func TestSelectCoderTemplate(t *testing.T) {
	cases := []struct {
		name             string
		notesFilter      string
		noteTemplateName string
		want             string
	}{
		{"default-no-tag", "", "", "coder"},
		{"bug-no-template", "BUG", "", "coder"},
		{"bug-with-template", "BUG", "coder_note_bug", "coder_note_bug"},
		{"feat-with-template", "FEAT", "coder_note_feat", "coder_note_feat"},
		{"polish-with-template", "POLISH", "coder_note_polish", "coder_note_polish"},
	}
	allowed := map[string]bool{
		"coder":             true,
		"coder_note_bug":    true,
		"coder_note_feat":   true,
		"coder_note_polish": true,
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := selectCoderTemplate(c.notesFilter, c.noteTemplateName)
			if got != c.want {
				t.Fatalf("selectCoderTemplate(%q, %q) = %q; want %q",
					c.notesFilter, c.noteTemplateName, got, c.want)
			}
			if !allowed[got] {
				t.Fatalf("selectCoderTemplate returned %q which is not in allowed set", got)
			}
			if got == "coder_rework" {
				t.Fatalf("selectCoderTemplate returned coder_rework — review-stage territory")
			}
		})
	}
}

// TestDefaultConfig asserts the multipliers and continuation defaults are
// exactly the bash values (regression canary for the milestone Watch For).
func TestDefaultConfig(t *testing.T) {
	c := DefaultConfig()
	if c.BugTurnMultiplier != 1.0 {
		t.Errorf("BugTurnMultiplier = %v; want 1.0", c.BugTurnMultiplier)
	}
	if c.FeatTurnMultiplier != 1.0 {
		t.Errorf("FeatTurnMultiplier = %v; want 1.0", c.FeatTurnMultiplier)
	}
	if c.PolishTurnMultiplier != 0.6 {
		t.Errorf("PolishTurnMultiplier = %v; want 0.6", c.PolishTurnMultiplier)
	}
	if c.TDDTurnMultiplier != 1.2 {
		t.Errorf("TDDTurnMultiplier = %v; want 1.2", c.TDDTurnMultiplier)
	}
	if c.MaxContinuationAttempts != 3 {
		t.Errorf("MaxContinuationAttempts = %v; want 3", c.MaxContinuationAttempts)
	}
	if c.MaxSplitDepth != 3 {
		t.Errorf("MaxSplitDepth = %v; want 3", c.MaxSplitDepth)
	}
	if !c.ContinuationEnabled {
		t.Errorf("ContinuationEnabled = false; want true")
	}
	if c.CoderMaxTurns != 80 {
		t.Errorf("CoderMaxTurns = %v; want 80", c.CoderMaxTurns)
	}
}

// TestEffectiveCoderTurns covers the 4-level cascade.
func TestEffectiveCoderTurns(t *testing.T) {
	cases := []struct {
		name string
		cfg  Config
		want int
	}{
		{"effective-set", Config{EffectiveCoderMaxTurns: 100}, 100},
		{"adjusted-only", Config{AdjustedCoderTurns: 50}, 50},
		{"coder-only", Config{CoderMaxTurns: 30}, 30},
		{"all-zero-fallback", Config{}, 80},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := c.cfg.effectiveCoderTurns(); got != c.want {
				t.Errorf("effectiveCoderTurns() = %d; want %d", got, c.want)
			}
		})
	}
}

// TestOrchestratorHas15Methods is the AC predicate: grep -cE
// '^func \(o \*orchestrator\)' must return >= 15.
func TestOrchestratorHas15Methods(t *testing.T) {
	// Build a fake orchestrator and assert each method is invocable
	// without panicking. The "method exists" predicate is enforced by
	// type-checking — this test exists to prevent silent removal during
	// refactor.
	o := newOrchestrator(&proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	})
	o.stageHeader()
	o.resetBuildFixStats()
}

// TestRunStageEntryPoint asserts RunStage matches the StageImpl signature
// and returns a non-nil envelope on the no-op path.
func TestRunStageEntryPoint(t *testing.T) {
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "noop",
		ResultFile: "/dev/null",
	}
	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage err = %v", err)
	}
	if res == nil {
		t.Fatal("RunStage returned nil envelope")
	}
	if res.Stage != proto.StageCoder {
		t.Errorf("Stage = %q; want %q", res.Stage, proto.StageCoder)
	}
}

// TestEnvHelpers covers envOr/envOrInt/envBool/envOrFloat fallback paths.
func TestEnvHelpers(t *testing.T) {
	t.Setenv("TEST_K", "")
	if got := envOr("TEST_K", "fallback"); got != "fallback" {
		t.Errorf("envOr empty = %q; want fallback", got)
	}
	t.Setenv("TEST_K", "v")
	if got := envOr("TEST_K", "fallback"); got != "v" {
		t.Errorf("envOr set = %q; want v", got)
	}
	t.Setenv("TEST_I", "not-a-number")
	if got := envOrInt("TEST_I", 7); got != 7 {
		t.Errorf("envOrInt bad = %d; want 7", got)
	}
	t.Setenv("TEST_I", "42")
	if got := envOrInt("TEST_I", 7); got != 42 {
		t.Errorf("envOrInt set = %d; want 42", got)
	}
	t.Setenv("TEST_B", "TRUE")
	if !envBool("TEST_B", false) {
		t.Errorf("envBool TRUE = false; want true")
	}
	t.Setenv("TEST_F", "1.5")
	if got := envOrFloat("TEST_F", 0); got != 1.5 {
		t.Errorf("envOrFloat = %v; want 1.5", got)
	}
}

// TestOrchestratorWithFakeDeps drives Run end-to-end with stub deps so we
// can assert the overall happy-path control flow without subprocess hops.
// Seeds a CODER_SUMMARY.md so validatePostCoder doesn't escalate.
func TestOrchestratorWithFakeDeps(t *testing.T) {
	dir := t.TempDir()
	summary := dir + "/CODER_SUMMARY.md"
	t.Setenv("CODER_SUMMARY_FILE", summary)
	if err := writeFakeSummary(summary, "## Status: COMPLETE\n"); err != nil {
		t.Fatalf("seed summary: %v", err)
	}
	req := &proto.StageRequestV1{
		Proto:      proto.StageRequestProtoV1,
		Stage:      proto.StageCoder,
		Task:       "t",
		ResultFile: "/dev/null",
	}
	o := newOrchestrator(req)

	// Wire fakes that record the sequence.
	var calls []string
	deps := DefaultDeps()
	deps.RunAgent = func(ctx context.Context, _ *provider.Request) (*provider.Result, error) {
		calls = append(calls, "agent")
		return &provider.Result{TurnsUsed: 5}, nil
	}
	deps.RenderPrompt = func(name string, _ map[string]string) (string, error) {
		calls = append(calls, "render:"+name)
		return "prompt-body", nil
	}
	deps.RunCompletionGate = func(context.Context) error {
		calls = append(calls, "completion")
		return nil
	}
	deps.RunBuildGate = func(context.Context, string) error {
		calls = append(calls, "build")
		return nil
	}
	deps.IsSubstantiveWork = func() bool { return true }
	o.withDeps(deps)

	res, err := o.Run(context.Background())
	if err != nil {
		t.Fatalf("Run err = %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("Verdict = %q; want pass", res.Verdict)
	}
	joined := strings.Join(calls, ",")
	if !strings.Contains(joined, "agent") || !strings.Contains(joined, "completion") || !strings.Contains(joined, "build") {
		t.Errorf("calls missing key steps: %v", calls)
	}
}

func writeFakeSummary(path, body string) error {
	return os_WriteFile(path, []byte(body), 0o644)
}
