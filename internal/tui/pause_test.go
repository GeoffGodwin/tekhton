package tui

import (
	"testing"
	"time"
)

func TestEnterPauseSetsStatusAndEmitsWarn(t *testing.T) {
	st := NewState()
	now := time.Unix(3000, 0)
	st.EnterPause(EnterPauseInput{Reason: "quota exhausted", RetryInterval: 300, MaxDuration: 18900}, now)

	if st.Payload.CurrentAgentStatus != "paused" {
		t.Errorf("agent status: got %q, want paused", st.Payload.CurrentAgentStatus)
	}
	if st.Payload.PauseReason != "quota exhausted" {
		t.Errorf("pause reason: got %q", st.Payload.PauseReason)
	}
	if st.Payload.PauseStartedAt != 3000 {
		t.Errorf("pause_started_at: got %d", st.Payload.PauseStartedAt)
	}
	if st.Payload.PauseNextProbeAt != 3300 {
		t.Errorf("pause_next_probe_at: got %d, want 3300", st.Payload.PauseNextProbeAt)
	}
	if len(st.Payload.RecentEvents) != 1 || st.Payload.RecentEvents[0].Level != "warn" {
		t.Errorf("expected single warn event, got %+v", st.Payload.RecentEvents)
	}
}

func TestUpdatePauseSkippedWhenNotPaused(t *testing.T) {
	st := NewState()
	now := time.Unix(3000, 0)
	applied := st.UpdatePause(120, now)
	if applied {
		t.Errorf("UpdatePause should be a no-op when not paused")
	}
	if st.Payload.PauseNextProbeAt != 0 {
		t.Errorf("PauseNextProbeAt should not change: got %d", st.Payload.PauseNextProbeAt)
	}
}

func TestExitPauseClearsState(t *testing.T) {
	st := NewState()
	now := time.Unix(3000, 0)
	st.EnterPause(EnterPauseInput{Reason: "rate-limited", RetryInterval: 60}, now)
	st.ExitPause("refreshed", time.Unix(3120, 0))

	if st.Payload.PauseReason != "" {
		t.Errorf("pause reason should clear: got %q", st.Payload.PauseReason)
	}
	if st.Payload.CurrentAgentStatus != "idle" {
		t.Errorf("agent status should reset to idle: got %q", st.Payload.CurrentAgentStatus)
	}
	if st.Payload.PauseStartedAt != 0 {
		t.Errorf("pause_started_at should clear: got %d", st.Payload.PauseStartedAt)
	}
}
