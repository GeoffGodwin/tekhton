package buildfix

import (
	"context"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// Deps is the dependency-injection seam for Run. Every field is
// best-effort (nil-safe via the helper wrappers) so callers can
// construct a minimal Deps for tests and only wire the fields the
// exercised path needs.
//
// The m39.4 orchestrator constructs a populated Deps once per coder
// stage entry; tests substitute recording fakes per scenario.
type Deps struct {
	// ReadRawErrors reads BUILD_RAW_ERRORS_FILE (preferred) or
	// BUILD_ERRORS_FILE. The m39.4 orchestrator wires both paths; tests
	// substitute a stub that returns canned content.
	ReadRawErrors func() (string, error)

	// Classify wraps the M127 routing classifier. Default: package-level
	// Classify. Tests override to force specific decisions without
	// constructing matching fixtures.
	Classify func(raw string) Decision

	// FilterCodeErrors strips noncode summaries from raw errors before
	// the build_fix prompt body is rendered. Production wires
	// internal/errors.FilterCodeErrors; tests pass an identity function.
	FilterCodeErrors func(raw string) string

	// RenderPrompt renders the "build_fix" template. Production wiring
	// resolves through internal/prompt; tests substitute a recording stub.
	RenderPrompt func(name string, vars map[string]string) (string, error)

	// RunAgent dispatches the bounded build-fix agent. Production wires
	// the in-process supervisor.
	RunAgent func(ctx context.Context, req *proto.AgentRequestV1) (*proto.AgentResultV1, error)

	// RunBuildGate invokes the build gate post-attempt. Returns
	// (true, nil) when the gate passes.
	RunBuildGate func(ctx context.Context, label string) (bool, error)

	// CountErrors / ErrorTail are file-bounded helpers. Tests override
	// to drive synthetic error streams; production wires the package
	// helpers from io.go.
	CountErrors func(path string) (int, error)
	ErrorTail   func(path string) (string, error)

	// EmitRoutingDiagnosis writes BUILD_ROUTING_DIAGNOSIS.md when the
	// routing decision is mixed_uncertain. Production wires the
	// package helper from io.go.
	EmitRoutingDiagnosis func(path string, statsText string) error

	// AppendReport appends one section to BUILD_FIX_REPORT.md per
	// attempt. Production wires the package helper from io.go.
	AppendReport func(path string, r AttemptReport) error

	// ClassifyWithStats produces the pipe-delimited stats stream
	// EmitRoutingDiagnosis consumes. Production wires
	// internal/errors.ClassifyWithStats with .FormatStatsLegacy() per
	// record.
	ClassifyWithStats func(raw string) string

	// DriftHumanActionAppend records an entry under "build_gate" in
	// HUMAN_ACTION_REQUIRED.md. Production wires the drift CLI shim;
	// nil-safe.
	DriftHumanActionAppend func(ctx context.Context, source, desc string) error

	// Log / Warn / Error surface progress to the operator. nil values
	// degrade to no-ops.
	Log   func(format string, args ...any)
	Warn  func(format string, args ...any)
	Error func(format string, args ...any)
}
