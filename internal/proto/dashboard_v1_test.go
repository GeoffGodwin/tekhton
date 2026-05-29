package proto

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestDashboardRunStateV1_RoundTrip(t *testing.T) {
	wf := "coder agent response"
	end := "2026-05-29T17:00:00Z"
	rem := 120
	p := DashboardRunStateV1{
		PipelineStatus: "running",
		CurrentStage:   "coder",
		ActiveMilestone: &DashboardMilestoneRef{
			ID:    "m33.1",
			Title: "Dashboard Emitters",
		},
		Stages: map[string]DashboardStageState{
			"intake": {Status: "pass", Turns: 3, Budget: 10, DurationS: 5},
			"coder":  {Status: "active", Turns: 12, Budget: 50, DurationS: 240},
		},
		WaitingFor:          &wf,
		StartedAt:           "2026-05-29T16:00:00Z",
		CompletedAt:         &end,
		ElapsedS:            900,
		EstimatedRemainingS: &rem,
		RefreshIntervalMs:   5000,
		QuotaStatus:         "ok",
		ParallelMode:        false,
		Teams:               map[string]DashboardTeamState{},
	}
	if err := p.Validate(); err != nil {
		t.Fatalf("happy-path Validate err: %v", err)
	}
	b, err := json.Marshal(&p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got DashboardRunStateV1
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.PipelineStatus != "running" || got.CurrentStage != "coder" {
		t.Fatalf("round-trip lost top-level fields: %+v", got)
	}
	if got.ActiveMilestone == nil || got.ActiveMilestone.ID != "m33.1" {
		t.Fatalf("round-trip lost active_milestone: %+v", got.ActiveMilestone)
	}
	if got.Stages["coder"].Status != "active" {
		t.Fatalf("round-trip lost stages map: %+v", got.Stages)
	}
}

func TestDashboardRunStateV1_RejectInvalidStatus(t *testing.T) {
	p := DashboardRunStateV1{PipelineStatus: "bogus"}
	err := p.Validate()
	if err == nil {
		t.Fatal("expected Validate to reject bogus pipeline_status")
	}
	if !errors.Is(err, ErrDashboardInvalid) {
		t.Fatalf("expected ErrDashboardInvalid, got %v", err)
	}
	if !strings.Contains(err.Error(), "pipeline_status") {
		t.Fatalf("error must name the offending field; got %q", err.Error())
	}
}

func TestDashboardTimelineV1_BareArray(t *testing.T) {
	p := DashboardTimelineV1{
		Events: []json.RawMessage{
			json.RawMessage(`{"id":"coder.001","type":"stage_start"}`),
		},
	}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.HasPrefix(string(b), "[") || !strings.HasSuffix(string(b), "]") {
		t.Fatalf("timeline must marshal as a bare array, got %s", b)
	}
	// Nil events → []
	empty := DashboardTimelineV1{}
	b2, _ := json.Marshal(empty)
	if string(b2) != "[]" {
		t.Fatalf("empty timeline must marshal as []; got %s", b2)
	}
}

func TestDashboardMilestonesV1_BareArray(t *testing.T) {
	p := DashboardMilestonesV1{
		Entries: []DashboardMilestoneEntry{
			{ID: "m01", Title: "Foundation", Status: "done"},
		},
	}
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.HasPrefix(string(b), `[{"id":"m01"`) {
		t.Fatalf("milestones shape unexpected: %s", b)
	}
}

func TestDashboardSecurityV1_EmptyFindings(t *testing.T) {
	p := DashboardSecurityV1{Findings: []DashboardFinding{}}
	b, _ := json.Marshal(&p)
	if string(b) != `{"findings":[]}` {
		t.Fatalf("empty security must marshal as {\"findings\":[]}; got %s", b)
	}
}

func TestDashboardReportsV1_RoundTrip(t *testing.T) {
	p := DashboardReportsV1{
		Intake:   DashboardIntakeReport{Verdict: "PASS", Confidence: 82, TaskText: "test"},
		Coder:    DashboardCoderReport{Status: "COMPLETE", FilesModified: 5},
		Reviewer: DashboardReviewerReport{Verdict: "APPROVED"},
		TestAudit: DashboardTestAudit{Verdict: "PASS"},
		Backlog:  DashboardNotesBacklog{Total: 3, Bug: 1, Feat: 2},
		Teams:    map[string]DashboardTeamReports{},
	}
	b, err := json.Marshal(&p)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got DashboardReportsV1
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Intake.Confidence != 82 || got.Coder.FilesModified != 5 {
		t.Fatalf("round-trip lost numeric fields: %+v", got)
	}
}

func TestDashboardHealthV1_RejectMismatch(t *testing.T) {
	p := DashboardHealthV1{Available: false, Data: json.RawMessage(`{"composite":80}`)}
	if err := p.Validate(); err == nil {
		t.Fatal("expected Validate to reject available=false + data present")
	}
}

func TestDashboardNotesV1_RejectInvalidStatus(t *testing.T) {
	p := DashboardNotesV1{Notes: []DashboardNote{{ID: "n1", Status: "bogus"}}}
	if err := p.Validate(); err == nil {
		t.Fatal("expected Validate to reject invalid note status")
	}
}

func TestDashboardActionItemsV1_RejectInvalidSeverity(t *testing.T) {
	p := DashboardActionItemsV1{
		Nonblocking: DashboardSeverityCount{Count: 1, Severity: "bogus"},
	}
	if err := p.Validate(); err == nil {
		t.Fatal("expected Validate to reject invalid severity")
	}
}

func TestDashboardConstants(t *testing.T) {
	// Spot-check the JS var name constants — these are part of the contract
	// because the browser reader addresses them.
	if DashboardVarRunState != "TK_RUN_STATE" {
		t.Fatalf("DashboardVarRunState changed: %q", DashboardVarRunState)
	}
	if DashboardV1 == "" {
		t.Fatal("DashboardV1 envelope tag must be non-empty")
	}
}
