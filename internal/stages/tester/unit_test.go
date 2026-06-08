package tester

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
)

func TestSetStateHaltWriter_RoundTrip(t *testing.T) {
	prev := SetStateHaltWriter(&fakeStateHaltWriter{})
	SetStateHaltWriter(prev) // restore
}

func TestSetters_ReturnPrevious(t *testing.T) {
	t.Helper()
	mainPrev := SetMainAgentRunner(&fakeMainAgent{})
	if mainPrev == nil {
		t.Fatalf("expected non-nil previous main runner")
	}
	SetMainAgentRunner(mainPrev)

	tddPrev := SetTDDRunner(&fakeTDD{})
	SetTDDRunner(tddPrev)

	fixPrev := SetFixRunner(&fakeFix{})
	SetFixRunner(fixPrev)

	contPrev := SetContinuationRunner(&fakeContinuation{})
	SetContinuationRunner(contPrev)

	auditPrev := SetAuditRunner(&fakeAudit{})
	SetAuditRunner(auditPrev)
}

func TestSetters_NilValueDoesNotOverwrite(t *testing.T) {
	// Setters are documented to ignore nil — verify the previous value
	// is returned even when nothing changes.
	prev := SetMainAgentRunner(nil)
	if prev == nil {
		t.Fatalf("expected non-nil previous main runner from nil-set")
	}
}

func TestFailResult_Shape(t *testing.T) {
	req := &proto.StageRequestV1{Proto: proto.StageRequestProtoV1, Stage: proto.StageTester}
	res := failResult(req, "agent_invocation_failed", 0, time.Now())
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("want fail, got %q", res.Verdict)
	}
	if res.ExitReason != "agent_invocation_failed" {
		t.Fatalf("want agent_invocation_failed, got %q", res.ExitReason)
	}
}

func TestTDDFailResult_Shape(t *testing.T) {
	req := &proto.StageRequestV1{Proto: proto.StageRequestProtoV1, Stage: proto.StageTester}
	res := tddFailResult(req, "tdd_upstream", time.Now())
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("want fail, got %q", res.Verdict)
	}
	if res.Error == "" {
		t.Fatalf("want non-empty Error field")
	}
}

func TestFinalizeResult_BlocksOnNoReportNoTests(t *testing.T) {
	req := &proto.StageRequestV1{Proto: proto.StageRequestProtoV1, Stage: proto.StageTester}
	decision := innertester.ValidationDecision{Routing: innertester.RoutingNoReportNoTests}
	res := finalizeResult(req, decision, routingMetadata{}, 0, time.Now())
	if res.Verdict != proto.VerdictBlock {
		t.Fatalf("want block, got %q", res.Verdict)
	}
}

func TestFinalizeResult_TestFailuresUnresolved_IsFail(t *testing.T) {
	req := &proto.StageRequestV1{Proto: proto.StageRequestProtoV1, Stage: proto.StageTester}
	decision := innertester.ValidationDecision{Routing: innertester.RoutingTestFailures}
	res := finalizeResult(req, decision, routingMetadata{ResolvedFailures: false}, 1, time.Now())
	if res.Verdict != proto.VerdictFail {
		t.Fatalf("want fail when failures unresolved, got %q", res.Verdict)
	}
}

func TestEnvBool_DefaultAndOverride(t *testing.T) {
	if envBool("ABSENT_TEST_KEY_38_6", true) != true {
		t.Fatalf("expected default true")
	}
	t.Setenv("PRESENT_TEST_KEY_38_6", "yes")
	if envBool("PRESENT_TEST_KEY_38_6", false) != true {
		t.Fatalf("expected yes → true")
	}
	t.Setenv("PRESENT_TEST_KEY_38_6", "no")
	if envBool("PRESENT_TEST_KEY_38_6", true) != false {
		t.Fatalf("expected no → false")
	}
}

func TestEnvInt_RejectsNonDigit(t *testing.T) {
	t.Setenv("BAD_INT_38_6", "abc")
	if envInt("BAD_INT_38_6", 7) != 7 {
		t.Fatalf("expected fallback on non-digit input")
	}
}

func TestEnvIntAllowZero_AcceptsZero(t *testing.T) {
	t.Setenv("ZERO_INT_38_6", "0")
	if envIntAllowZero("ZERO_INT_38_6", 9) != 0 {
		t.Fatalf("expected 0 to be accepted")
	}
}

func TestBuildResumeFlag_HumanMode(t *testing.T) {
	cfg := config{HumanMode: true, HumanNotesTag: "BUG"}
	if got := buildResumeFlag("test", cfg); got != "--human BUG --start-at test" {
		t.Fatalf("unexpected resume flag: %q", got)
	}
}

func TestBuildResumeFlag_MilestoneMode(t *testing.T) {
	cfg := config{MilestoneMode: true}
	if got := buildResumeFlag("test", cfg); got != "--milestone --start-at test" {
		t.Fatalf("unexpected resume flag: %q", got)
	}
}

func TestItoaSentinel(t *testing.T) {
	if itoaSentinel(-1) != "-1" {
		t.Fatalf("expected -1 sentinel")
	}
	if itoaSentinel(0) != "0" {
		t.Fatalf("expected 0")
	}
	if itoaSentinel(42) != "42" {
		t.Fatalf("expected 42, got %q", itoaSentinel(42))
	}
}

func TestRouteDecision_PartialRunContinuationSkipsFinalChecks(t *testing.T) {
	cfg := &config{ContinuationEnabled: true}
	cont := &fakeContinuation{
		Result: &innertester.ContinuationResult{
			Continued: false, AttemptsUsed: 1, SkipFinalChecks: true, UpstreamErrored: true,
		},
	}
	prev := SetContinuationRunner(cont)
	defer SetContinuationRunner(prev)

	meta, _, err := routeDecision(context.Background(), cfg,
		innertester.ValidationDecision{Routing: innertester.RoutingPartialRun, Remaining: 2}, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !meta.SkipFinalChecks {
		t.Fatalf("expected SkipFinalChecks=true from continuation UPSTREAM")
	}
}

func TestRouteDecision_AuditCallFailureSurfaces(t *testing.T) {
	cfg := &config{}
	a := &fakeAudit{Err: errors.New("audit failed")}
	prev := SetAuditRunner(a)
	defer SetAuditRunner(prev)

	meta, _, err := routeDecision(context.Background(), cfg,
		innertester.ValidationDecision{Routing: innertester.RoutingClean}, nil)
	if err != nil {
		t.Fatalf("audit error must not propagate: %v", err)
	}
	if meta.AuditRan {
		t.Fatalf("AuditRan must be false on audit error")
	}
}
