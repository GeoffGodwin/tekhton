package buildfix

import (
	"context"
	"sync/atomic"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// loopFake records call counts and lets tests drive the seam functions.
// Designed to expose every observable used by the milestone acceptance
// criteria: invocation count, label / classification passed to RunAgent,
// per-attempt arguments threaded into AppendReport.
type loopFake struct {
	rawErrorsByCall      []string // pops from index 0; last value sticks
	classifyReturn       Decision
	classifyCalls        int32
	classifyWithStatsCnt int32
	emitDiagCalls        int32
	driftAppends         []string
	runAgentLabels       []string
	runAgentExitCodes    []int
	runAgentTurns        []int
	gateReturns          []bool // pops from index 0; last value sticks
	appendReports        []AttemptReport
	countErrors          []int // pops from index 0; last value sticks
	errorTails           []string
}

func (f *loopFake) deps() *Deps {
	return &Deps{
		ReadRawErrors:          f.readRawErrors,
		Classify:               f.classify,
		FilterCodeErrors:       func(raw string) string { return raw },
		ClassifyWithStats:      f.classifyWithStats,
		EmitRoutingDiagnosis:   f.emitRoutingDiagnosis,
		DriftHumanActionAppend: f.driftHumanActionAppend,
		RenderPrompt:           func(_ string, _ map[string]string) (string, error) { return "PROMPT", nil },
		RunAgent:               f.runAgent,
		RunBuildGate:           f.runBuildGate,
		CountErrors:            f.countErr,
		ErrorTail:              f.errTail,
		AppendReport:           f.appendReport,
	}
}

func (f *loopFake) readRawErrors() (string, error) {
	if len(f.rawErrorsByCall) == 0 {
		return "", nil
	}
	out := f.rawErrorsByCall[0]
	if len(f.rawErrorsByCall) > 1 {
		f.rawErrorsByCall = f.rawErrorsByCall[1:]
	}
	return out, nil
}

func (f *loopFake) classify(_ string) Decision {
	atomic.AddInt32(&f.classifyCalls, 1)
	return f.classifyReturn
}

func (f *loopFake) classifyWithStats(_ string) string {
	atomic.AddInt32(&f.classifyWithStatsCnt, 1)
	return ""
}

func (f *loopFake) emitRoutingDiagnosis(_ string, _ string) error {
	atomic.AddInt32(&f.emitDiagCalls, 1)
	return nil
}

func (f *loopFake) driftHumanActionAppend(_ context.Context, source, desc string) error {
	f.driftAppends = append(f.driftAppends, source+"|"+desc)
	return nil
}

func (f *loopFake) runAgent(_ context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	f.runAgentLabels = append(f.runAgentLabels, req.Label)
	idx := len(f.runAgentLabels) - 1
	exit := 0
	if idx < len(f.runAgentExitCodes) {
		exit = f.runAgentExitCodes[idx]
	}
	turns := 0
	if idx < len(f.runAgentTurns) {
		turns = f.runAgentTurns[idx]
	}
	return &proto.AgentResultV1{ExitCode: exit, TurnsUsed: turns}, nil
}

func (f *loopFake) runBuildGate(_ context.Context, _ string) (bool, error) {
	if len(f.gateReturns) == 0 {
		return false, nil
	}
	out := f.gateReturns[0]
	if len(f.gateReturns) > 1 {
		f.gateReturns = f.gateReturns[1:]
	}
	return out, nil
}

func (f *loopFake) countErr(_ string) (int, error) {
	if len(f.countErrors) == 0 {
		return 0, nil
	}
	out := f.countErrors[0]
	if len(f.countErrors) > 1 {
		f.countErrors = f.countErrors[1:]
	}
	return out, nil
}

func (f *loopFake) errTail(_ string) (string, error) {
	if len(f.errorTails) == 0 {
		return "", nil
	}
	out := f.errorTails[0]
	if len(f.errorTails) > 1 {
		f.errorTails = f.errorTails[1:]
	}
	return out, nil
}

func (f *loopFake) appendReport(_ string, r AttemptReport) error {
	f.appendReports = append(f.appendReports, r)
	return nil
}
