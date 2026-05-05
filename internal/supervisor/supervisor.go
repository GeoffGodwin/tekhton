// Package supervisor is the Go-side process supervisor that replaces
// lib/agent_monitor.sh + lib/agent_retry.sh + lib/agent.sh in V4 Phase 2.
//
// Status (m06): real subprocess path. Run launches the agent binary under
// exec.CommandContext, scans stdout for streaming JSON events, tees stderr
// to the causal log, and bounds idle time with an activity timer. m07 will
// wrap Run with a retry envelope; m08 layers the quota pause; m09 ports
// the spinner + Windows process-tree reaping; m10 publishes the parity test
// suite that gates the bash shim flip. Until m10 ships, lib/agent.sh stays
// on the bash supervisor and no production code path reaches this package.
//
// The boundary between this package and its callers is the proto envelope
// (internal/proto/agent_v1.go). Validation happens at Run() entry so the
// CLI layer (cmd/tekhton/supervise.go) and any future in-process caller
// see identical contract enforcement.
package supervisor

import (
	"context"
	"os"

	"github.com/geoffgodwin/tekhton/internal/causal"
	"github.com/geoffgodwin/tekhton/internal/proto"
	"github.com/geoffgodwin/tekhton/internal/state"
)

// AgentBinaryEnv lets tests and unusual deployments override the default
// "claude" binary the supervisor launches. Honored by New() at construction
// time so a single setenv configures both in-process and CLI callers.
const AgentBinaryEnv = "TEKHTON_AGENT_BINARY"

// defaultBinary is the production agent CLI. Resolved at New() time, not at
// Run() time, so a long-running supervisor doesn't start picking up env
// changes mid-flight.
const defaultBinary = "claude"

// Supervisor owns the seams onto the rest of the V4 runtime: the causal log
// (so agent lifecycle events can be emitted) and the state store (so
// resume-relevant state can be updated mid-run). Both are nil-safe — Run
// degrades gracefully when callers haven't wired them.
type Supervisor struct {
	causal *causal.Log
	state  *state.Store
	binary string
}

// New constructs a Supervisor. Both seam arguments may be nil; the binary
// resolves to $TEKHTON_AGENT_BINARY when set, falling back to "claude".
// Tests use the env var to point Run at testdata/fake_agent.sh.
func New(c *causal.Log, s *state.Store) *Supervisor {
	bin := os.Getenv(AgentBinaryEnv)
	if bin == "" {
		bin = defaultBinary
	}
	return &Supervisor{causal: c, state: s, binary: bin}
}

// SetBinary overrides the agent CLI path. Mostly for tests that need to
// point the supervisor at a fixture script without touching process env.
// Production callers should prefer the env-var path so the binary is
// configured once at process start.
func (s *Supervisor) SetBinary(path string) { s.binary = path }

// Run is the central entry point: validate the request, dispatch to the
// subprocess path in run.go, and shape an AgentResultV1 to return.
//
// Callers MUST treat ctx cancellation as authoritative — Run wires it into
// exec.CommandContext, so any consumer that passes a deadline gets the
// expected SIGTERM → SIGKILL escalation when the deadline fires.
func (s *Supervisor) Run(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error) {
	return s.run(ctx, req)
}
