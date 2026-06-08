package prerun

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestShouldAbortNewFailures_Threshold is the +2 threshold table test
// referenced in the acceptance criteria. The +2 threshold is load-bearing
// (Watch For); the table guarantees a regression to +1 or +3 fails red.
//
// Logic under test: newCount > initialCount + 2 → abort.
func TestShouldAbortNewFailures_Threshold(t *testing.T) {
	rows := []struct {
		name        string
		initial     int
		newCount    int
		wantAbort   bool
		explanation string
	}{
		{"same-count", 5, 5, false, "no change → continue"},
		{"plus-one", 5, 6, false, "noisy +1 → tolerate"},
		{"plus-two", 5, 7, false, "+2 is the EQ boundary → tolerate"},
		{"plus-three", 5, 8, true, "+3 > +2 → real regression, abort"},
		{"zero-initial", 0, 2, false, "0 → 2 is at boundary, tolerate"},
		{"zero-to-three", 0, 3, true, "0 → 3 crosses threshold, abort"},
		{"new-is-less", 10, 4, false, "new < initial → progress, never abort"},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			got := shouldAbortNewFailures(row.initial, row.newCount)
			if got != row.wantAbort {
				t.Fatalf("shouldAbortNewFailures(%d, %d) = %v, want %v (%s)",
					row.initial, row.newCount, got, row.wantAbort, row.explanation)
			}
		})
	}
}

// TestCountFailures verifies the regex port of grep -ciE
// '(FAIL|ERROR|error|failure)'. Case-insensitive line count.
func TestCountFailures(t *testing.T) {
	rows := []struct {
		name string
		in   string
		want int
	}{
		{"empty", "", 0},
		{"single-fail", "FAIL TestFoo", 1},
		{"single-error", "ERROR: bad input", 1},
		{"case-insensitive", "failure: something", 1},
		{"mixed-passing", "PASS\nFAIL Foo\nPASS\nERROR Bar", 2},
		{"no-matches", "PASS\nok    foo  0.001s", 0},
		// One line with multiple matches still counts as one line.
		{"multi-on-line", "ERROR FAIL failure", 1},
	}
	for _, row := range rows {
		t.Run(row.name, func(t *testing.T) {
			if got := countFailures(row.in); got != row.want {
				t.Fatalf("countFailures(%q) = %d, want %d", row.in, got, row.want)
			}
		})
	}
}

// TestTailLines verifies the tail -120 port. The n <= 0 branch and the
// "input shorter than n" branch are the load-bearing edges; preserving
// trailing-newline behavior matches the bash `tail` semantics.
func TestTailLines(t *testing.T) {
	t.Run("n-zero", func(t *testing.T) {
		if got := tailLines("a\nb\n", 0); got != "" {
			t.Fatalf("tailLines(_, 0) = %q, want empty", got)
		}
	})
	t.Run("shorter-than-n", func(t *testing.T) {
		got := tailLines("a\nb\nc", 10)
		if got != "a\nb\nc" {
			t.Fatalf("tailLines = %q, want full input", got)
		}
	})
	t.Run("trailing-newline-stripped", func(t *testing.T) {
		// "a\nb\n" splits to ["a", "b", ""] — strip the trailing empty
		// element so n=2 returns "a\nb", not "b\n".
		got := tailLines("a\nb\n", 2)
		if got != "a\nb" {
			t.Fatalf("tailLines = %q, want %q", got, "a\nb")
		}
	})
	t.Run("truncated", func(t *testing.T) {
		got := tailLines("a\nb\nc\nd\ne", 2)
		if got != "d\ne" {
			t.Fatalf("tailLines = %q, want %q", got, "d\ne")
		}
	})
}

// TestRunFixAgent_AttemptCapHonored constructs a fix-agent scenario where
// MaxAttempts=1 (the default) means the loop must run exactly once and
// return StatusFixFailed when the verify still fails.
func TestRunFixAgent_AttemptCapHonored(t *testing.T) {
	var calls int
	deps := &Deps{
		RunAgent: func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			calls++
			return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) {
			return "body", nil
		},
		RunTestCmd: func(context.Context, string) (string, int, error) {
			return "FAIL", 1, nil
		},
	}
	cfg := &Config{Enabled: true, TestCmd: "go test", MaxAttempts: 1, MaxTurns: 20}

	out, err := runFixAgent(context.Background(), cfg, deps, "FAIL", 1)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if calls != 1 {
		t.Fatalf("agent calls = %d, want 1 (MaxAttempts=1)", calls)
	}
	if out.Status != StatusFixFailed {
		t.Fatalf("status = %q, want %q", out.Status, StatusFixFailed)
	}
	if out.AttemptsUsed != 1 {
		t.Fatalf("AttemptsUsed = %d, want 1", out.AttemptsUsed)
	}
}

// TestRunFixAgent_AbortOnNewFailures verifies the +2 threshold trips
// after a single attempt that introduces 3 net-new failures.
func TestRunFixAgent_AbortOnNewFailures(t *testing.T) {
	deps := &Deps{
		RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) { return "x", nil },
		RunTestCmd: func(context.Context, string) (string, int, error) {
			return "FAIL one\nFAIL two\nFAIL three\nFAIL four\nFAIL five", 1, nil
		},
	}
	cfg := &Config{Enabled: true, TestCmd: "go test", MaxAttempts: 3, MaxTurns: 20}
	// initial has 1 failure; new has 5; delta = 4 > +2 → abort.
	out, _ := runFixAgent(context.Background(), cfg, deps, "FAIL one", 1)
	if out.Status != StatusFixFailed {
		t.Fatalf("status = %q, want %q", out.Status, StatusFixFailed)
	}
	if out.AbortReason != "introduced_new_failures" {
		t.Fatalf("abort reason = %q, want introduced_new_failures", out.AbortReason)
	}
	if out.AttemptsUsed != 1 {
		t.Fatalf("AttemptsUsed = %d, want 1 (aborted at attempt 1)", out.AttemptsUsed)
	}
}

// TestRunFixAgent_AgentInvocationFailureNonFatal verifies that a
// RunAgent error rotates to the next attempt instead of aborting the
// loop — matches the bash behavior where supervisor errors are logged
// but the outer loop proceeds.
func TestRunFixAgent_AgentInvocationFailureNonFatal(t *testing.T) {
	var verifyCalls int
	deps := &Deps{
		RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			return nil, errors.New("transient")
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) { return "x", nil },
		RunTestCmd: func(context.Context, string) (string, int, error) {
			verifyCalls++
			return "PASS", 0, nil // verify passes — even though agent errored
		},
	}
	cfg := &Config{Enabled: true, TestCmd: "go test", MaxAttempts: 1, MaxTurns: 20}
	out, _ := runFixAgent(context.Background(), cfg, deps, "FAIL", 1)
	if verifyCalls != 1 {
		t.Fatalf("verify calls = %d, want 1", verifyCalls)
	}
	if out.Status != StatusFixed {
		t.Fatalf("status = %q, want %q (verify passes after agent error)", out.Status, StatusFixed)
	}
}

// TestInvokeFixAgent_NoRunAgentDep verifies the error path when the
// orchestrator forgets to wire RunAgent.
func TestInvokeFixAgent_NoRunAgentDep(t *testing.T) {
	cfg := &Config{Enabled: true, MaxAttempts: 1, MaxTurns: 20}
	err := invokeFixAgent(context.Background(), cfg, &Deps{}, 1, "FAIL")
	if err == nil || !strings.Contains(err.Error(), "RunAgent") {
		t.Fatalf("err = %v, want RunAgent-nil error", err)
	}
}

// TestInvokeFixAgent_PromptRenderError verifies the render-error
// propagation path.
func TestInvokeFixAgent_PromptRenderError(t *testing.T) {
	deps := &Deps{
		RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			t.Fatal("RunAgent must not be invoked when render fails")
			return nil, nil
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) {
			return "", errors.New("template missing")
		},
	}
	cfg := &Config{Enabled: true, MaxAttempts: 1, MaxTurns: 20}
	err := invokeFixAgent(context.Background(), cfg, deps, 1, "FAIL")
	if err == nil || !strings.Contains(err.Error(), "render") {
		t.Fatalf("err = %v, want render error", err)
	}
}

// TestRun_NilConfigDoesNotPanic guards against the m39.4 wiring path
// passing nil by mistake.
func TestRun_NilConfigDoesNotPanic(t *testing.T) {
	defer func() {
		if r := recover(); r != nil {
			t.Fatalf("Run panicked: %v", r)
		}
	}()
	_, err := Run(context.Background(), nil, nil)
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
}

// TestBaselineJSONPath verifies the path-resolution helper used by the
// m39.4 orchestrator wiring.
func TestBaselineJSONPath(t *testing.T) {
	rows := []struct {
		dir  string
		want string
	}{
		{"/proj", "/proj/.claude/TEST_BASELINE.json"},
		{"", ".claude/TEST_BASELINE.json"},
	}
	for _, row := range rows {
		got := baselineJSONPath(row.dir)
		if got != row.want {
			t.Fatalf("baselineJSONPath(%q) = %q, want %q", row.dir, got, row.want)
		}
	}
}

// TestInvokeFixAgent_PromptVariablesPopulated verifies that the
// PREFLIGHT_TEST_OUTPUT variable is the tail (last 120 lines) of the
// input — a fingerprint of the bash version's `tail -120` behavior.
func TestInvokeFixAgent_PromptVariablesPopulated(t *testing.T) {
	var capturedVars map[string]string
	deps := &Deps{
		RunAgent: func(context.Context, *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess}, nil
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) {
			capturedVars = vars
			return "body", nil
		},
	}
	cfg := &Config{Enabled: true, MaxAttempts: 1, MaxTurns: 20}
	// Build an input of 130 lines so we exercise the truncation.
	var b strings.Builder
	for i := 1; i <= 130; i++ {
		fmt.Fprintf(&b, "line %d\n", i)
	}
	if err := invokeFixAgent(context.Background(), cfg, deps, 1, b.String()); err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	tail := capturedVars["PREFLIGHT_TEST_OUTPUT"]
	if strings.Count(tail, "\n")+1 != 120 {
		t.Fatalf("PREFLIGHT_TEST_OUTPUT line count = %d, want 120",
			strings.Count(tail, "\n")+1)
	}
	if !strings.Contains(tail, "line 11") {
		t.Fatalf("tail must start at line 11, got first line of %q", tail)
	}
	if !strings.Contains(tail, "line 130") {
		t.Fatalf("tail must include line 130, got %q", tail[len(tail)-50:])
	}
	if capturedVars["PREFLIGHT_CHANGED_FILES"] != "" {
		t.Fatalf("PREFLIGHT_CHANGED_FILES must be empty (pre-coder has no diff context)")
	}
}
