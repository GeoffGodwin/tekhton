package tui

import (
	"testing"
	"time"
)

func TestStageBeginAllocatesLifecycleID(t *testing.T) {
	st := NewState()
	now := time.Unix(2000, 0)
	id := st.StageBegin(StageBeginInput{Label: "Coder", Model: "claude-opus"}, now)
	if id != "Coder#1" {
		t.Errorf("first allocation: got %q, want Coder#1", id)
	}
	if st.Payload.StageLabel != "Coder" {
		t.Errorf("stage_label: got %q", st.Payload.StageLabel)
	}
	if st.Payload.AgentModel != "claude-opus" {
		t.Errorf("agent_model: got %q", st.Payload.AgentModel)
	}
	if st.Payload.StageStartTS != 2000 {
		t.Errorf("stage_start_ts: got %d, want 2000", st.Payload.StageStartTS)
	}
	if st.Payload.CurrentAgentStatus != "running" {
		t.Errorf("current_agent_status: got %q, want running", st.Payload.CurrentAgentStatus)
	}
	// Second begin of same label allocates Coder#2.
	id2 := st.StageBegin(StageBeginInput{Label: "Coder"}, now)
	if id2 != "Coder#2" {
		t.Errorf("second allocation: got %q, want Coder#2", id2)
	}
}

func TestStageEndAutoClosesSubstage(t *testing.T) {
	st := NewState()
	now := time.Unix(2000, 0)
	st.StageBegin(StageBeginInput{Label: "Coder"}, now)
	st.SubstageBegin("build-fix", now)
	st.StageEnd(StageEndInput{Label: "Coder", Verdict: "FAIL"}, time.Unix(2042, 0))

	if st.Payload.CurrentSubstageLabel != "" {
		t.Errorf("substage should be cleared after parent end, got %q", st.Payload.CurrentSubstageLabel)
	}
	if len(st.Payload.RecentEvents) == 0 {
		t.Fatalf("expected auto-close warn event")
	}
	last := st.Payload.RecentEvents[len(st.Payload.RecentEvents)-1]
	if last.Level != "warn" {
		t.Errorf("warn event level: got %q", last.Level)
	}
	if len(st.Payload.StagesComplete) != 1 {
		t.Fatalf("expected 1 completion record")
	}
	if st.Payload.CurrentLifecycleID != "" {
		t.Errorf("current_lifecycle_id should clear: got %q", st.Payload.CurrentLifecycleID)
	}
	if !st.IsLifecycleClosed("Coder#1") {
		t.Errorf("Coder#1 should be marked closed")
	}
}

func TestUpdateAgentDropsStaleLifecycleID(t *testing.T) {
	st := NewState()
	now := time.Unix(2000, 0)
	st.StageBegin(StageBeginInput{Label: "Coder"}, now)
	st.StageEnd(StageEndInput{Label: "Coder"}, time.Unix(2042, 0))
	st.StageBegin(StageBeginInput{Label: "Review"}, time.Unix(2042, 0))

	// Late tick from the closed Coder#1 cycle should be dropped.
	applied := st.UpdateAgent(UpdateAgentInput{TurnsUsed: 99, LifecycleID: "Coder#1"})
	if applied {
		t.Errorf("late tick from closed cycle should be dropped")
	}
	if st.Payload.AgentTurnsUsed == 99 {
		t.Errorf("closed-cycle update polluted current state")
	}
}

func TestSubstageBeginEndDoesNotMutateParent(t *testing.T) {
	st := NewState()
	now := time.Unix(2000, 0)
	parentID := st.StageBegin(StageBeginInput{Label: "Coder"}, now)
	parentLabel := st.Payload.StageLabel
	parentStart := st.Payload.StageStartTS

	st.SubstageBegin("scout", time.Unix(2010, 0))
	if st.Payload.StageLabel != parentLabel {
		t.Errorf("stage_label should not change on substage begin: got %q", st.Payload.StageLabel)
	}
	if st.Payload.StageStartTS != parentStart {
		t.Errorf("stage_start_ts should not change: got %d, want %d", st.Payload.StageStartTS, parentStart)
	}
	if st.Payload.CurrentLifecycleID != parentID {
		t.Errorf("lifecycle id should not change on substage: got %q, want %q", st.Payload.CurrentLifecycleID, parentID)
	}
	st.SubstageEnd("scout", "PASS")
	if st.Payload.CurrentSubstageLabel != "" {
		t.Errorf("substage label should clear: got %q", st.Payload.CurrentSubstageLabel)
	}
}
