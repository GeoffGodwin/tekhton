package prerun

import (
	"context"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// recordingDeps is the shared test fake. Every dep that mutates state
// records its arguments so tests can assert call order and content.
// Lives in fakes_test.go so prerun_test.go stays focused on assertions.
type recordingDeps struct {
	// Injected behavior.
	dedupCanSkip   bool
	testCmdOutput  string
	testCmdExit    int
	testCmdErr     error
	agentErr       error
	captureErr     error
	deleteErr      error
	dedupRecordErr error
	renderErr      error

	// On the Nth RunTestCmd call AFTER the initial pre-coder check, return
	// verifyExits[N-1] / verifyOutputs[N-1] instead of (testCmdExit,
	// testCmdOutput). Lets the tests model "initial test fails, fix-agent
	// verify passes" without re-shaping the Deps. Calls before the first
	// agent invocation use testCmdExit/testCmdOutput.
	verifyExits     []int
	verifyOutputs   []string
	verifyExitIndex int
	initialTestRun  bool // true after the first RunTestCmd has returned

	// Recordings.
	agentCalls       int
	captureCalls     int
	captureMilestone string
	deleteCalls      int
	dedupRecord      int
	emitted          []string // "kind|scope|desc"
	logs             []string
	warns            []string
	successes        []string
	callOrder        []string // "delete" before "capture", etc.
	combined         []string // populated by parity_test wireCombinedStream
}

func (r *recordingDeps) toDeps() *Deps {
	return &Deps{
		RunAgent: func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
			r.agentCalls++
			if r.agentErr != nil {
				return nil, r.agentErr
			}
			return &proto.AgentResultV1{Proto: proto.AgentResultProtoV1, Outcome: proto.OutcomeSuccess}, nil
		},
		RenderPrompt: func(name string, vars map[string]string) (string, error) {
			if r.renderErr != nil {
				return "", r.renderErr
			}
			return "rendered:" + name, nil
		},
		RunTestCmd: func(ctx context.Context, cmd string) (string, int, error) {
			// First call (initial pre-coder check) returns testCmdExit/Output.
			// Subsequent calls (verify-after-attempt) peel from verifyExits
			// when programmed; otherwise fall through to the test-cmd defaults.
			if !r.initialTestRun {
				r.initialTestRun = true
				return r.testCmdOutput, r.testCmdExit, r.testCmdErr
			}
			if r.verifyExitIndex < len(r.verifyExits) {
				out := ""
				if r.verifyExitIndex < len(r.verifyOutputs) {
					out = r.verifyOutputs[r.verifyExitIndex]
				}
				exit := r.verifyExits[r.verifyExitIndex]
				r.verifyExitIndex++
				return out, exit, nil
			}
			return r.testCmdOutput, r.testCmdExit, r.testCmdErr
		},
		CaptureTestBaseline: func(milestone string) error {
			r.captureCalls++
			r.captureMilestone = milestone
			r.callOrder = append(r.callOrder, "capture")
			return r.captureErr
		},
		DeleteBaselineJSON: func() error {
			r.deleteCalls++
			r.callOrder = append(r.callOrder, "delete")
			return r.deleteErr
		},
		EmitEvent: func(kind, scope, desc string) {
			r.emitted = append(r.emitted, kind+"|"+scope+"|"+desc)
		},
		TestDedupCanSkip: func() bool { return r.dedupCanSkip },
		TestDedupRecordPass: func() error {
			r.dedupRecord++
			return r.dedupRecordErr
		},
		AppendVerifyOutput: func(path, content string) error { return nil },
		Log: func(format string, args ...any) {
			r.logs = append(r.logs, fmt.Sprintf(format, args...))
		},
		Warn: func(format string, args ...any) {
			r.warns = append(r.warns, fmt.Sprintf(format, args...))
		},
		Success: func(format string, args ...any) {
			r.successes = append(r.successes, fmt.Sprintf(format, args...))
		},
	}
}
