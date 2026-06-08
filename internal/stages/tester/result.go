package tester

import (
	"time"

	"github.com/geoffgodwin/tekhton/internal/proto"
	innertester "github.com/geoffgodwin/tekhton/internal/tester"
)

// Result envelope metadata keys. Stored in StageResultV1.Metadata for
// the legacy bash orchestrator to consume — m38.6 does not yet rewire
// every metadata consumer, but the keys are stable for the eventual
// follow-up arc.
const (
	metaSkipFinalChecks  = "skip_final_checks"
	metaResolvedFailures = "resolved_failures"
	metaContinuationOK   = "continuation_ok"
	metaAuditRan         = "audit_ran"
	metaRouting          = "routing"
)

// finalizeResult builds the per-routing StageResultV1. The verdict is
// `pass` for every routing branch except RoutingNoReportNoTests (block —
// no way to proceed without operator intervention).
func finalizeResult(
	req *proto.StageRequestV1,
	decision innertester.ValidationDecision,
	meta routingMetadata,
	agentCalls int,
	stageStart time.Time,
) *proto.StageResultV1 {
	verdict := proto.VerdictPass
	exitReason := decision.Routing.String()
	nextAction := ""

	switch decision.Routing {
	case innertester.RoutingClean:
		nextAction = "pass"
	case innertester.RoutingCompilationErrors:
		verdict = proto.VerdictRework
		nextAction = "fix-compilation"
	case innertester.RoutingTestFailures:
		if meta.ResolvedFailures {
			nextAction = "pass"
		} else {
			verdict = proto.VerdictFail
			nextAction = "fix"
		}
	case innertester.RoutingPartialRun:
		if meta.ContinuationOK {
			nextAction = "pass"
		} else {
			verdict = proto.VerdictRework
			nextAction = "resume"
		}
	case innertester.RoutingNoReportButTestsCreated:
		nextAction = "synthesized"
	case innertester.RoutingNoReportNoTests:
		verdict = proto.VerdictBlock
		nextAction = "missing-report"
	}

	res := &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     verdict,
		ExitReason:  exitReason,
		AgentCalls:  agentCalls,
		NextAction:  nextAction,
		DurationSec: int(time.Since(stageStart).Seconds()),
		HumanAction: meta.HumanAction,
		Metadata:    map[string]string{metaRouting: decision.Routing.String()},
	}
	if meta.SkipFinalChecks {
		res.Metadata[metaSkipFinalChecks] = "true"
	}
	if meta.ResolvedFailures {
		res.Metadata[metaResolvedFailures] = "true"
	}
	if meta.ContinuationOK {
		res.Metadata[metaContinuationOK] = "true"
	}
	if meta.AuditRan {
		res.Metadata[metaAuditRan] = "true"
	}
	return res
}

// upstreamResult is the MAIN tester UPSTREAM disposition: verdict=pass
// because the operator just re-runs (the work continues from this
// stage), agent_calls is the count consumed before the error, and
// SkipFinalChecks=true so downstream cleanup/test re-execution is
// skipped. Distinct from the TDD UPSTREAM result (verdict=fail with a
// non-nil error returned to the runner).
func upstreamResult(req *proto.StageRequestV1, agentCalls int, stageStart time.Time) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictPass,
		ExitReason:  "upstream_error",
		AgentCalls:  agentCalls,
		NextAction:  "resume",
		DurationSec: int(time.Since(stageStart).Seconds()),
		Metadata: map[string]string{
			metaSkipFinalChecks: "true",
			metaRouting:         "upstream",
		},
	}
}

// nullRunResult is the null-run disposition: same shape as UPSTREAM
// because the operator response is identical (re-run).
func nullRunResult(req *proto.StageRequestV1, agentCalls int, stageStart time.Time) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictPass,
		ExitReason:  "null_run",
		AgentCalls:  agentCalls,
		NextAction:  "resume",
		DurationSec: int(time.Since(stageStart).Seconds()),
		Metadata: map[string]string{
			metaSkipFinalChecks: "true",
			metaRouting:         "null_run",
		},
	}
}

// failResult builds a verdict=fail StageResultV1 for the error paths
// (agent invocation failure, routing dispatch error).
func failResult(req *proto.StageRequestV1, reason string, agentCalls int, stageStart time.Time) *proto.StageResultV1 {
	return &proto.StageResultV1{
		Proto:       proto.StageResultProtoV1,
		Stage:       req.Stage,
		Verdict:     proto.VerdictFail,
		ExitReason:  reason,
		AgentCalls:  agentCalls,
		DurationSec: int(time.Since(stageStart).Seconds()),
	}
}
