package review

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// TestRunStage_ApprovedCycleOne — first cycle returns APPROVED, no rework,
// specialist passthrough, verdict=pass / approved.
func TestRunStage_ApprovedCycleOne(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 5}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, &fakeSpecialist{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "approved" {
		t.Errorf("exit_reason=%q want approved", res.ExitReason)
	}
	if len(ag.Calls) != 1 {
		t.Errorf("agent calls=%d want 1", len(ag.Calls))
	}
	if len(gate.Calls) != 0 {
		t.Errorf("build gate called %d times, want 0", len(gate.Calls))
	}
}

// TestRunStage_BlockersRemainAtMaxCycles — every cycle CHANGES_REQUIRED with
// blockers; the stage returns verdict=fail / blockers_remain.
func TestRunStage_BlockersRemainAtMaxCycles(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	// Agent writes the same CHANGES_REQUIRED report on every cycle.
	always := func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		writeReport(t, dir, `## Verdict
CHANGES_REQUIRED

## Complex Blockers
- still broken

## Simple Blockers
- None
`)
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 8}, nil
	}
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){always, always, always},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, nil)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictFail {
		t.Errorf("verdict=%q want fail", res.Verdict)
	}
	if res.ExitReason != "blockers_remain" {
		t.Errorf("exit_reason=%q want blockers_remain", res.ExitReason)
	}
	if !strings.Contains(res.Error, "max_cycles=3") {
		t.Errorf("Error metadata missing max_cycles=3:\n%s", res.Error)
	}
	// Cycle 1+2 ran rework, cycle 3 didn't (last cycle). So agent calls =
	// reviewer×3 + coder_rework×2 = 5.
	if len(ag.Calls) != 5 {
		t.Errorf("agent calls=%d want 5 (3 reviewer + 2 rework)", len(ag.Calls))
	}
}

// TestRunStage_MaxReviewCyclesIsRespected — when Max=2, exactly 2 reviewer
// invocations occur on the all-blockers path. Locks in the off-by-one
// regression guard.
func TestRunStage_MaxReviewCyclesIsRespected(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "2")
	always := func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		writeReport(t, dir, `## Verdict
CHANGES_REQUIRED

## Complex Blockers
- still broken

## Simple Blockers
- None
`)
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 8}, nil
	}
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){always, always, always, always},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	_, _ = RunStage(context.Background(), req)

	reviewerCalls := 0
	for _, c := range ag.Calls {
		if strings.HasPrefix(c.Label, "Reviewer (cycle") {
			reviewerCalls++
		}
	}
	if reviewerCalls != 2 {
		t.Errorf("reviewer agent calls=%d want exactly 2", reviewerCalls)
	}
}

// TestRunStage_ChangesThenApproved — cycle 1 CHANGES_REQUIRED (one complex),
// cycle 2 APPROVED. Asserts the senior-rework routing, build-gate post-fix-pass,
// and verdict-flip on cycle 2.
func TestRunStage_ChangesThenApproved(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			// reviewer cycle 1
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nCHANGES_REQUIRED\n\n## Complex Blockers\n- bug X\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 10}, nil
			},
			// coder rework
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 20}, nil
			},
			// reviewer cycle 2
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 4}, nil
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil, &fakeSpecialist{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "approved" {
		t.Errorf("exit_reason=%q want approved", res.ExitReason)
	}
	// 2 reviewer + 1 coder rework + 0 jr (no simple blockers).
	if len(ag.Calls) != 3 {
		t.Errorf("agent calls=%d want 3 (2 reviewer + 1 senior rework)", len(ag.Calls))
	}
	// Locate the rework call.
	foundRework := false
	for _, c := range ag.Calls {
		if strings.HasPrefix(c.Label, "Coder (rework") {
			foundRework = true
		}
	}
	if !foundRework {
		t.Errorf("did not see senior coder rework call")
	}
	if len(gate.Calls) != 1 {
		t.Errorf("build gate called %d times, want 1", len(gate.Calls))
	}
}

// TestRunStage_SynthesizedAtMax — reviewer succeeds without producing a
// REVIEWER_REPORT.md across all cycles; the stage synthesizes the fallback
// on the last cycle and returns verdict=pass / synthesized_at_max.
func TestRunStage_SynthesizedAtMax(t *testing.T) {
	_, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	// Mid-cycle null-report returns rework; we need three of them. The first
	// two return rework -> rework cycle. Caller's runRework with empty report
	// (because runOneCycle returns cycleRework with nil report when file
	// doesn't exist) — we must make sure the test still sees the path.
	noReport := func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
		// Don't write a report; supervisor returns success.
		return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 3}, nil
	}
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			noReport, noReport, noReport,
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, nil)
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if res.ExitReason != "synthesized_at_max" {
		t.Errorf("exit_reason=%q want synthesized_at_max", res.ExitReason)
	}
	if !strings.Contains(res.Error, "synthesized_report=true") {
		t.Errorf("Error metadata missing synthesized_report=true:\n%s", res.Error)
	}
}

// TestRunStage_ReplanContinue — REPLAN_REQUIRED verdict + user chooses continue;
// verdict flipped to APPROVED_WITH_NOTES via finalizeApproved.
func TestRunStage_ReplanContinue(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, `## Verdict
REPLAN_REQUIRED

## Complex Blockers
- Task contradicts architecture

## Simple Blockers
- None
`)
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 6}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, &fakeReplan{Decision: replanContinue}, &fakeSpecialist{})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass", res.Verdict)
	}
	if !strings.Contains(res.Error, "verdict=APPROVED_WITH_NOTES") {
		t.Errorf("expected APPROVED_WITH_NOTES verdict in metadata, got:\n%s", res.Error)
	}
}

// TestRunStage_ReplanAbort — REPLAN_REQUIRED + user aborts; verdict=fail /
// replan_user_aborted.
func TestRunStage_ReplanAbort(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nREPLAN_REQUIRED\n\n## Complex Blockers\n- mis-scoped\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 4}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, &fakeReplan{Decision: replanUserAborted}, nil)
	defer restore()

	res, _ := RunStage(context.Background(), req)
	if res.Verdict != proto.VerdictFail {
		t.Errorf("verdict=%q want fail", res.Verdict)
	}
	if res.ExitReason != "replan_user_aborted" {
		t.Errorf("exit_reason=%q want replan_user_aborted", res.ExitReason)
	}
}

// TestRunStage_PreservesPassEnvelopeOnSpecialistReworkFailure asserts the
// m47 envelope-over-error rule end-to-end: when the reviewer agent emits an
// APPROVED verdict, the specialist runner returns blockers, AND the post-
// specialist build gate fails (forcing the escalation retry to fail too),
// the stage MUST still return a pass envelope — the build-gate failure
// records as Metadata["subprocess_warnings"] but does NOT override the
// originally-parsed verdict. Pre-m47 this combination returned verdict=fail
// (specialist_build_failure) which manifested as the m38.4 + m46 manifest
// false-failure (operator had to flip done manually).
//
// Per m47 Watch For "specialist_build_failure is still a hard fail" we
// instead drive a path where the post-specialist runOneCycle errors — this
// is the specialist.go:111 site the milestone classification table calls
// out as the converted-to-warning case. Use an empty fakeAgent Behaviors
// queue so the post-specialist reviewer pass returns the fake's default
// success result with no report file; the cycle's parse step then propagates
// the no-report path through synthesis (a non-error path) — so to exercise
// the converted error site we install a SpecialistRunner that fails after
// the first cycle has already produced an APPROVED report.
//
// Concrete failure mode: build-gate failure on the post-specialist-retry
// branch. The stage path that USED to override the verdict was the
// `runOneCycle` err return after the second build gate succeeded; we drive
// that by making the second build gate succeed but the post-specialist
// runOneCycle hit a render error.
func TestRunStage_PreservesPassEnvelopeOnSpecialistReworkFailure(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	// Reviewer cycle 1 → APPROVED. Senior coder rework → success. Post-
	// specialist reviewer cycle 2 → APPROVED again. The build gate flakes on
	// post-specialist-rework but recovers on retry — that's the path the
	// envelope-warning rule applies to (any failure in the rework branch
	// that does NOT terminate via the post-specialist-retry hard fail).
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			// reviewer cycle 1 — APPROVED
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED_WITH_NOTES\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 5}, nil
			},
			// senior coder rework (specialist branch)
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 12}, nil
			},
			// build_fix_minimal (escalation after first build gate fails)
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 4}, nil
			},
			// post-specialist reviewer pass — APPROVED again
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED_WITH_NOTES\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	// Build gate: first call fails (post-specialist-rework), second succeeds
	// (post-specialist-retry). The first failure used to be observable only
	// via log.Warn; after m47 it remains a non-fatal warning when the retry
	// recovers — the originally-parsed APPROVED verdict survives.
	gate := &fakeBuildGate{
		Behaviors: []error{errors.New("first build gate flake"), nil},
	}
	restore := installSeams(t, ag, gate, nil,
		&fakeSpecialist{Blockers: "- specialist flagged input handling\n"})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: err=%v (m47 requires nil)", err)
	}
	if res == nil {
		t.Fatal("RunStage: res=nil (m47 requires non-nil envelope)")
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass (originally-parsed APPROVED must survive)", res.Verdict)
	}
	if res.ExitReason != "approved" {
		t.Errorf("exit_reason=%q want approved", res.ExitReason)
	}
}

// TestRunStage_RecordsSubprocessWarningOnPostSpecialistCycleError exercises
// the exact specialist.go runOneCycle err-return site the m47 classification
// table flags as the converted-to-warning case. The original verdict was
// APPROVED. The specialist runner returns blockers, the build gate passes,
// and then the post-specialist reviewer cycle's runOneCycle fails (we drive
// this via a render-failure path by clearing the prompt template var). Under
// the m47 rule, the stage returns the originally-parsed APPROVED verdict
// with the post-cycle error recorded as a subprocess_warnings Metadata entry.
func TestRunStage_RecordsSubprocessWarningOnPostSpecialistCycleError(t *testing.T) {
	dir, req := setupProject(t)
	t.Setenv("MAX_REVIEW_CYCLES", "3")
	// Set the prompts dir to a nonexistent path AFTER cycle 1. We can't
	// flip it mid-run via env (loadConfig snapshots once), so use a custom
	// AgentRunner that errors on the post-specialist reviewer call — that
	// drives the same code path (runOneCycle returns err) without needing
	// a render failure.
	postSpecialistAgentErr := errors.New("post-specialist reviewer dispatch failed")
	cycleCalls := 0
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			// reviewer cycle 1 — APPROVED
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				cycleCalls++
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 4}, nil
			},
			// senior coder rework (specialist branch)
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 10}, nil
			},
			// post-specialist reviewer pass — errors out
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				return nil, postSpecialistAgentErr
			},
		},
	}
	gate := &fakeBuildGate{}
	restore := installSeams(t, ag, gate, nil,
		&fakeSpecialist{Blockers: "- spec found unsafe deserialization\n"})
	defer restore()

	res, err := RunStage(context.Background(), req)
	if err != nil {
		t.Fatalf("RunStage: err=%v (m47 requires nil)", err)
	}
	if res == nil {
		t.Fatal("RunStage: res=nil (m47 requires non-nil envelope)")
	}
	if res.Verdict != proto.VerdictPass {
		t.Errorf("verdict=%q want pass (originally-parsed APPROVED survives post-cycle error)", res.Verdict)
	}
	// The post-cycle failure must appear in subprocess_warnings — JSON list
	// per the m47 plural-key contract.
	raw := res.Metadata["subprocess_warnings"]
	if raw == "" {
		t.Fatalf("Metadata[\"subprocess_warnings\"] empty; expected JSON list with the post-cycle error")
	}
	var warnings []string
	if err := json.Unmarshal([]byte(raw), &warnings); err != nil {
		t.Fatalf("subprocess_warnings is not a JSON array: %v (raw=%q)", err, raw)
	}
	found := false
	for _, w := range warnings {
		if strings.Contains(w, "post_specialist_cycle") {
			found = true
		}
	}
	if !found {
		t.Errorf("subprocess_warnings missing post_specialist_cycle entry; got %v", warnings)
	}
}

// TestRunStage_DoesNotMutatePipelineState — RunStage MUST NOT write to
// PIPELINE_STATE.md directly. Verified by asserting the file does not exist
// after a complete run, regardless of which verdict path engaged.
func TestRunStage_DoesNotMutatePipelineState(t *testing.T) {
	dir, req := setupProject(t)
	ag := &fakeAgent{
		Behaviors: []func(*proto.AgentRequestV1) (*proto.AgentResultV1, error){
			func(_ *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
				writeReport(t, dir, "## Verdict\nAPPROVED\n\n## Complex Blockers\n- None\n\n## Simple Blockers\n- None\n")
				return &proto.AgentResultV1{Outcome: proto.OutcomeSuccess, TurnsUsed: 3}, nil
			},
		},
	}
	restore := installSeams(t, ag, &fakeBuildGate{}, nil, &fakeSpecialist{})
	defer restore()

	if _, err := RunStage(context.Background(), req); err != nil {
		t.Fatalf("RunStage: %v", err)
	}
	if fileExists(dir + "/.tekhton/PIPELINE_STATE.md") {
		t.Errorf("RunStage wrote PIPELINE_STATE.md — must not mutate state directly")
	}
}
