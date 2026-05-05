// Package supervisor is the Go-side process supervisor that replaces
// lib/agent_monitor.sh + lib/agent_retry.sh + lib/agent.sh in V4 Phase 2.
//
// Status (m05): scaffold only. Run() returns a stub success response without
// launching any subprocess. m06 lands exec.CommandContext + the activity
// monitor; m07 wraps Run with the retry envelope; m08 layers quota pause; m09
// ports the spinner; m10 publishes the parity test suite that gates the bash
// shim flip. Until m10 ships, lib/agent.sh stays on the bash supervisor and
// no production code path reaches this package.
//
// The boundary between this package and its callers is the proto envelope
// (internal/proto/agent_v1.go). Validation happens here once at Run() entry
// so the CLI layer (cmd/tekhton/supervise.go) and any future in-process
// caller see identical contract enforcement.
package supervisor

import (
	"context"
	"errors"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// Supervisor owns the seams onto the rest of the V4 runtime: the causal log
// (so agent lifecycle events can be emitted) and the state store (so
// resume-relevant state can be updated mid-run). Both are nil-safe in the
// m05 stub — Run() does not touch them yet.
type Supervisor struct {
	causal *causal.Log
	state  *state.Store
	// m06+: subprocess fields (cmd, stdin/stdout pipes), activity timer,
	// signal handlers, ring buffer. None of those exist yet.
}

// New constructs a Supervisor. Both arguments may be nil for the m05 stub
// path — they become required once Run() actually executes a subprocess.
func New(c *causal.Log, s *state.Store) *Supervisor {
	return &Supervisor{causal: c, state: s}
}

// ErrNotImplemented is returned by Run when a code path that m05 has stubbed
// is exercised in a way the stub cannot satisfy. m06 replaces every site
// that returns this with the real implementation.
var ErrNotImplemented = errors.New("supervisor: not implemented in m05 stub")

// Run is the central entry point: validate the request, dispatch to the
// (eventual) subprocess path, and shape an AgentResultV1 to return. In the
// m05 stub, validation is real but the subprocess is not — Run returns a
// success result immediately so the CLI surface and the proto round-trip
// can be exercised end-to-end without launching `claude`.
//
// Callers MUST treat ctx cancellation as authoritative even though the stub
// ignores it; m06 wires ctx into exec.CommandContext and any consumer that
// passes a deadline expects it to be honored.
func (s *Supervisor) Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	if req == nil {
		return nil, fmt.Errorf("supervisor: nil request")
	}
	// Defensive: any in-process caller that bypasses cmd/tekhton/supervise.go
	// must still get contract enforcement. The CLI layer also validates;
	// the duplication is intentional. m06 will grow more validation here.
	if err := req.Validate(); err != nil {
		return nil, err
	}

	// Stub path: pretend the agent ran successfully with zero turns and zero
	// duration. The fields populated here are the minimum the proto requires
	// (Proto, Outcome, ExitCode); m06 fills in TurnsUsed, DurationMs, and the
	// stdout tail from the real subprocess.
	res := &proto.AgentResultV1{
		Proto:    proto.AgentResultProtoV1,
		RunID:    req.RunID,
		Label:    req.Label,
		ExitCode: 0,
		Outcome:  proto.OutcomeSuccess,
	}
	res.TrimStdoutTail()
	return res, nil
}
