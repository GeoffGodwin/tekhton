package claude

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/provider"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// stubSup is a test double for supervisorRunner.
type stubSup struct {
	result *proto.AgentResultV1
	err    error
}

func (s *stubSup) Run(_ context.Context, _ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	return s.result, s.err
}

// successResult builds a minimal success AgentResultV1.
func successResult(turns int) *proto.AgentResultV1 {
	return &proto.AgentResultV1{
		Proto:     proto.AgentResultProtoV1,
		ExitCode:  0,
		TurnsUsed: turns,
		Outcome:   proto.OutcomeSuccess,
	}
}

func TestProvider_Name(t *testing.T) {
	p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
	if got := p.Name(); got != "claude" {
		t.Errorf("Name: want claude, got %s", got)
	}
}

func TestProvider_NilRequest(t *testing.T) {
	p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
	_, err := p.RunAgent(context.Background(), nil)
	if err == nil {
		t.Error("RunAgent(nil): want error, got nil")
	}
}

func TestProvider_NilSupervisor(t *testing.T) {
	p := &Provider{}
	_, err := p.RunAgent(context.Background(), &provider.Request{
		Prompt: "test",
		Model:  "claude-sonnet",
		Label:  "test",
	})
	if err == nil {
		t.Error("nil Supervisor: want error, got nil")
	}
}

// TestProvider_StreamingEvents asserts the provider emits TurnStart, TurnEnd,
// RunEnd in that order, then closes the channel.
func TestProvider_StreamingEvents(t *testing.T) {
	stub := &stubSup{result: successResult(3)}
	p := &Provider{Supervisor: stub}

	ch := make(chan provider.Event, 10)
	req := &provider.Request{
		Prompt:    "test prompt",
		MaxTurns:  10,
		Model:     "claude-sonnet",
		Label:     "streaming-test",
		EventChan: ch,
	}

	if _, err := p.RunAgent(context.Background(), req); err != nil {
		t.Fatalf("RunAgent: %v", err)
	}

	var events []provider.Event
	for ev := range ch {
		events = append(events, ev)
	}

	wantKinds := []provider.EventKind{
		provider.EventTurnStart,
		provider.EventTurnEnd,
		provider.EventRunEnd,
	}
	if len(events) != len(wantKinds) {
		t.Fatalf("event count: want %d, got %d", len(wantKinds), len(events))
	}
	for i, want := range wantKinds {
		if events[i].Kind != want {
			t.Errorf("events[%d].Kind: want %v, got %v", i, want, events[i].Kind)
		}
	}
	if events[0].Turn != 1 {
		t.Errorf("TurnStart.Turn: want 1, got %d", events[0].Turn)
	}
	if events[1].Turn != 3 {
		t.Errorf("TurnEnd.Turn: want 3 (from stub), got %d", events[1].Turn)
	}
	// Reviewer coverage gap: Timestamp must be set on TurnStart and RunEnd.
	// A struct-literal change that drops time.Now() would produce a zero Timestamp,
	// causing callers that compute elapsed duration to report nonsense values.
	if events[0].Timestamp.IsZero() {
		t.Errorf("TurnStart.Timestamp is zero — provider must set time.Now() on emission")
	}
	if events[2].Timestamp.IsZero() {
		t.Errorf("RunEnd.Timestamp is zero — provider must set time.Now() on emission")
	}
}

// TestTranslateOutcome_NullRun asserts exit!=0 with turns<=threshold maps
// to OutcomeNullRun.
func TestTranslateOutcome_NullRun(t *testing.T) {
	res := supervisor.FromProto(&proto.AgentResultV1{
		ExitCode:  1,
		TurnsUsed: 1,
		Outcome:   proto.OutcomeFatalError,
	})
	if got := translateOutcome(res); got != provider.OutcomeNullRun {
		t.Errorf("NullRun: want %d, got %d", provider.OutcomeNullRun, got)
	}
}

// TestTranslateOutcome_Upstream asserts UPSTREAM error category maps to
// OutcomeUpstreamError.
func TestTranslateOutcome_Upstream(t *testing.T) {
	res := supervisor.FromProto(&proto.AgentResultV1{
		ExitCode:      1,
		TurnsUsed:     5,
		Outcome:       proto.OutcomeTransientError,
		ErrorCategory: supervisor.CategoryUpstream,
	})
	if got := translateOutcome(res); got != provider.OutcomeUpstreamError {
		t.Errorf("UPSTREAM: want %d, got %d", provider.OutcomeUpstreamError, got)
	}
}

// TestTranslateOutcome_MaxTurns asserts turn_exhausted maps to OutcomeMaxTurns.
func TestTranslateOutcome_MaxTurns(t *testing.T) {
	res := supervisor.FromProto(&proto.AgentResultV1{
		ExitCode:  0,
		TurnsUsed: 10,
		Outcome:   proto.OutcomeTurnExhausted,
	})
	if got := translateOutcome(res); got != provider.OutcomeMaxTurns {
		t.Errorf("TurnExhausted: want %d, got %d", provider.OutcomeMaxTurns, got)
	}
}

// TestTranslateOutcome_Timeout asserts activity_timeout maps to OutcomeTimeout.
func TestTranslateOutcome_Timeout(t *testing.T) {
	res := supervisor.FromProto(&proto.AgentResultV1{
		ExitCode:  1,
		TurnsUsed: 5,
		Outcome:   proto.OutcomeActivityTimeout,
	})
	if got := translateOutcome(res); got != provider.OutcomeTimeout {
		t.Errorf("ActivityTimeout: want %d, got %d", provider.OutcomeTimeout, got)
	}
}

func TestWritePromptFile(t *testing.T) {
	const want = "hello\nworld\n"
	path, cleanup, err := writePromptFile(want)
	if err != nil {
		t.Fatalf("writePromptFile: %v", err)
	}
	defer cleanup()

	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != want {
		t.Errorf("content: want %q, got %q", want, string(got))
	}
}

func TestWritePromptFile_CleanupRemovesFile(t *testing.T) {
	path, cleanup, err := writePromptFile("data")
	if err != nil {
		t.Fatalf("writePromptFile: %v", err)
	}
	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("cleanup did not remove %s", path)
	}
}

// TestTranslateOutcome_UpstreamWithLowTurns pins the precedence rule:
// IsNullRun() is checked before ErrorCategory, so an upstream error with
// turns_used <= DefaultNullRunThreshold is classified as OutcomeNullRun,
// NOT OutcomeUpstreamError. This is an intentional design choice — a run
// that barely started (≤ threshold turns) before an upstream error is
// indistinguishable from a null run in terms of work produced.
func TestTranslateOutcome_UpstreamWithLowTurns(t *testing.T) {
	// turns_used=1 is at or below DefaultNullRunThreshold (2).
	// ErrorCategory=UPSTREAM would normally map to OutcomeUpstreamError,
	// but IsNullRun() wins because exit_code=1 and turns<=threshold.
	res := supervisor.FromProto(&proto.AgentResultV1{
		ExitCode:      1,
		TurnsUsed:     1,
		Outcome:       proto.OutcomeTransientError,
		ErrorCategory: supervisor.CategoryUpstream,
	})
	got := translateOutcome(res)
	if got != provider.OutcomeNullRun {
		t.Errorf("UPSTREAM with turns=1: want OutcomeNullRun (IsNullRun wins), got %d (%v)",
			got, got)
	}
	if got == provider.OutcomeUpstreamError {
		t.Error("UPSTREAM with turns=1: OutcomeUpstreamError must not be returned when IsNullRun is true")
	}
}

// TestProvider_EventChan_ClosedOnWritePromptFileError verifies that EventChan
// is closed even when writePromptFile fails. Before the m05 fix, the channel
// was closed only on the happy path — callers draining with `range ch` would
// block forever on a prompt-file write failure. The fix adds
// `defer close(req.EventChan)` before the writePromptFile call so all return
// paths close the channel.
func TestProvider_EventChan_ClosedOnWritePromptFileError(t *testing.T) {
	// Force os.CreateTemp to fail by pointing TMPDIR at a non-existent directory.
	nonExistentTmpDir := filepath.Join(t.TempDir(), "nonexistent-for-test")
	t.Setenv("TMPDIR", nonExistentTmpDir)

	p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
	ch := make(chan provider.Event, 10)
	req := &provider.Request{
		Prompt:    "test prompt",
		MaxTurns:  10,
		Model:     "claude-sonnet",
		Label:     "test",
		EventChan: ch,
	}

	_, err := p.RunAgent(context.Background(), req)
	if err == nil {
		t.Fatal("expected error from writePromptFile failure when TMPDIR is unwritable, got nil")
	}

	// Channel must be closed — drain it with a deadline to detect if close never fires.
	select {
	case ev, ok := <-ch:
		if ok {
			t.Errorf("channel not closed: received event %+v", ev)
		}
		// ok == false means channel closed with no events — correct new behavior.
	case <-time.After(200 * time.Millisecond):
		t.Error("EventChan not closed after writePromptFile error — callers using `range ch` would block forever")
	}
}

func TestLabelOrDefault(t *testing.T) {
	if got := labelOrDefault(""); got != "agent" {
		t.Errorf("empty: want agent, got %s", got)
	}
	if got := labelOrDefault("reviewer"); got != "reviewer" {
		t.Errorf("non-empty: want reviewer, got %s", got)
	}
}

// TestProvider_Tier_Default asserts Tier() returns "api" by default
// (post-June-15 Anthropic API-metered pricing).
func TestProvider_Tier_Default(t *testing.T) {
	t.Setenv("TEKHTON_CLAUDE_PRE_JUNE_15", "")
	p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
	if got := p.Tier(); got != provider.TierAPI {
		t.Errorf("Tier() default: want %q, got %q", provider.TierAPI, got)
	}
}

// TestProvider_Tier_PreJune15Override asserts Tier() returns "subscription"
// when TEKHTON_CLAUDE_PRE_JUNE_15=true.
func TestProvider_Tier_PreJune15Override(t *testing.T) {
	t.Setenv("TEKHTON_CLAUDE_PRE_JUNE_15", "true")
	p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
	if got := p.Tier(); got != provider.TierSubscription {
		t.Errorf("Tier() with env override: want %q, got %q", provider.TierSubscription, got)
	}
}

// TestProvider_Tier_EnvFalse asserts that non-"true" values for the override
// env do not activate the subscription tier override.
func TestProvider_Tier_EnvFalse(t *testing.T) {
	for _, v := range []string{"false", "1", "yes", "TRUE"} {
		t.Run(v, func(t *testing.T) {
			t.Setenv("TEKHTON_CLAUDE_PRE_JUNE_15", v)
			p := &Provider{Supervisor: &stubSup{result: successResult(1)}}
			if got := p.Tier(); got != provider.TierAPI {
				t.Errorf("Tier() with env=%q: want %q (only 'true' activates override), got %q",
					v, provider.TierAPI, got)
			}
		})
	}
}
