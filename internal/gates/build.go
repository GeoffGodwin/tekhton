// Package gates owns the build gate and completion gate that run inside the
// coder stage subprocess. m31.1 ports lib/gates.sh, lib/gates_phases.sh, and
// lib/gates_completion.sh; m31.2 will replace the bash UI-phase shim with a
// native implementation.
//
// Two top-level types drive everything:
//
//   - BuildGate runs the five-phase build pipeline (analyze, compile,
//     constraints, ui_test, ui_validation) under an omnibus timeout budget.
//   - CompletionGate runs after the coder stage to verify the coder
//     self-reported COMPLETE and that TEST_CMD still passes.
//
// The package is process-boundary safe: every command exec passes through
// CommandRunner so tests substitute deterministic fakes, and every file
// write goes through ErrorsWriter so tests can assert on captured bytes
// without touching the filesystem.
package gates

import (
	"context"
	"errors"
	"fmt"
	"time"
)

// Sentinel errors that callers match with errors.Is. Phase-specific failures
// wrap PhaseError so the call site can pull the phase name out via errors.As.
var (
	// ErrGateTimeout is returned when the omnibus build gate exceeds
	// BUILD_GATE_TIMEOUT before all phases complete. Mirrors the bash
	// _gate_check_timeout synthetic ## Gate Timeout report.
	ErrGateTimeout = errors.New("gates: build gate timeout exceeded")

	// ErrPhaseFailed is returned when a phase reports verdict Fail. Wrap
	// with PhaseError so the failing phase name survives the errors.Is/As
	// chain at the CLI seam.
	ErrPhaseFailed = errors.New("gates: phase failed")
)

// PhaseStatus is the verdict a Phase returns. Fail short-circuits the gate;
// Pass and Skip both continue to the next phase.
type PhaseStatus int

const (
	// StatusPass means the phase ran and reported no errors.
	StatusPass PhaseStatus = iota
	// StatusFail means the phase ran, found errors, and did not recover.
	StatusFail
	// StatusSkip means the phase short-circuited (e.g. BUILD_CHECK_CMD is
	// empty, DEPENDENCY_CONSTRAINTS_FILE not configured, UI_TEST_CMD unset).
	// Skip is the unconfigured-phase outcome — not a recoverable failure.
	StatusSkip
)

// PhaseInput carries the per-invocation context every Phase receives.
type PhaseInput struct {
	// StageLabel is the human-readable identifier for the caller stage
	// ("post-coder" / "post-jr-coder") that gets written into BUILD_ERRORS.md.
	StageLabel string

	// Remaining is the time budget left for this phase, computed as
	// min(phase_timeout, gate_timeout - elapsed). Phases that finish under
	// budget return early; phases that timeout treat exit code 124 as Pass
	// (parity with bash `timeout 124`).
	Remaining time.Duration

	// Now is the clock the phase should query for ## Build Errors timestamps.
	// Defaults to time.Now when nil so phase tests can pin a fixed instant.
	Now func() time.Time
}

// PhaseResult is what a Phase returns from Run.
type PhaseResult struct {
	Status PhaseStatus
	// Err is set when Status == StatusFail. The build gate wraps this in
	// PhaseError so callers can pull both the phase name and the underlying
	// failure cause.
	Err error
}

// Phase is the per-step contract inside BuildGate. Phase implementations
// live in phases.go; the build gate registers them in a fixed order.
type Phase interface {
	// Name returns the canonical phase identifier ("analyze", "compile",
	// "constraints", "ui_test", "ui_validation"). The order-mismatch test
	// in build_test.go asserts that the registered Phase names equal this
	// exact slice in order.
	Name() string
	Run(ctx context.Context, in *PhaseInput) PhaseResult
}

// PhaseError lets callers recover both the failing phase name and the
// underlying cause via errors.As / errors.Is.
type PhaseError struct {
	Phase string
	Err   error
}

// Error implements the error interface.
func (e *PhaseError) Error() string {
	return fmt.Sprintf("phase %s: %v", e.Phase, e.Err)
}

// Unwrap lets errors.Is(err, ErrPhaseFailed) succeed.
func (e *PhaseError) Unwrap() error { return e.Err }

// Is satisfies errors.Is for ErrPhaseFailed and any wrapped sentinel.
func (e *PhaseError) Is(target error) bool {
	if target == ErrPhaseFailed {
		return true
	}
	return errors.Is(e.Err, target)
}

// BuildGate orchestrates the five build phases under a single omnibus
// timeout budget. Construct via NewBuildGate (which registers the canonical
// phase order) and drive with Run.
type BuildGate struct {
	// Phases is the registered phase order. NewBuildGate populates this with
	// the canonical [analyze, compile, constraints, ui_test, ui_validation]
	// list. Direct construction is allowed for tests that need a different
	// phase set (e.g. order-shuffle tests).
	Phases []Phase

	// Timeout caps the omnibus gate run. Zero means use BUILD_GATE_TIMEOUT
	// (defaulted by the env contract to 600s).
	Timeout time.Duration

	// Errors owns the BUILD_ERRORS.md + BUILD_RAW_ERRORS.txt write surface.
	// nil falls back to a NoopErrorsWriter so direct-construction tests
	// don't need to wire it.
	Errors ErrorsWriter

	// Now overrides the wall-clock for tests. Defaults to time.Now.
	Now func() time.Time
}

// canonicalPhaseOrder is the registered phase order. The order-mismatch
// guard in build_test.go::TestBuildGate_PhaseOrder fails red if the slice
// drifts. Changing this also requires updating lib/gates.sh's mirror in
// any retained legacy compatibility shim AND the parity-test assertions.
var canonicalPhaseOrder = []string{
	"analyze",
	"compile",
	"constraints",
	"ui_test",
	"ui_validation",
}

// PhaseOrder returns the canonical phase registration order. Exported so
// the order-mismatch test and external parity tooling can compare against
// it without reaching into private state.
func PhaseOrder() []string {
	out := make([]string, len(canonicalPhaseOrder))
	copy(out, canonicalPhaseOrder)
	return out
}

// NewBuildGate constructs a BuildGate with the canonical phase order using
// the supplied factory map. Phases not present in the factory map are
// skipped (this is how m31.1 ships without a UI_TEST_CMD configured —
// UIPhase's factory returns a Skip stub).
//
// The factory pattern lets m31.2 swap the bash-shim UIPhase for a native
// implementation by changing one map entry, without touching the canonical
// ordering anywhere.
func NewBuildGate(factories map[string]func() Phase, opts BuildGateOptions) *BuildGate {
	g := &BuildGate{
		Timeout: opts.Timeout,
		Errors:  opts.Errors,
		Now:     opts.Now,
	}
	if g.Errors == nil {
		g.Errors = NoopErrorsWriter{}
	}
	if g.Now == nil {
		g.Now = time.Now
	}
	for _, name := range canonicalPhaseOrder {
		ctor, ok := factories[name]
		if !ok {
			continue
		}
		p := ctor()
		if p == nil {
			continue
		}
		g.Phases = append(g.Phases, p)
	}
	return g
}

// BuildGateOptions carries the construction-time knobs for NewBuildGate.
type BuildGateOptions struct {
	Timeout time.Duration
	Errors  ErrorsWriter
	Now     func() time.Time
}

// Run executes every registered phase in order under the omnibus timeout.
// Returns nil on pass (every phase returned Pass or Skip), ErrGateTimeout
// if the budget runs out before the next phase starts, or a PhaseError
// wrapping ErrPhaseFailed if a phase returns Fail.
//
// On timeout, the synthetic ## Gate Timeout BUILD_ERRORS.md is written via
// the configured ErrorsWriter so the downstream classifier (internal/errors)
// can route the failure.
//
// On phase failure, the failing phase already wrote its own BUILD_ERRORS.md
// section via ErrorsWriter (parity with the bash _gate_write_*_errors
// callers); Run does not double-write.
func (g *BuildGate) Run(ctx context.Context, stageLabel string) error {
	if g == nil {
		return nil
	}
	timeout := g.Timeout
	if timeout <= 0 {
		timeout = 600 * time.Second
	}
	now := g.Now
	if now == nil {
		now = time.Now
	}

	// Reset stale artifacts. Mirrors the rm -f at the top of run_build_gate.
	g.Errors.Reset()

	deadline := now().Add(timeout)
	for _, p := range g.Phases {
		if err := ctx.Err(); err != nil {
			return err
		}
		nowT := now()
		if !nowT.Before(deadline) {
			g.Errors.WriteTimeout(stageLabel, timeout, nowT)
			return fmt.Errorf("%w (after %s)", ErrGateTimeout, timeout)
		}
		in := &PhaseInput{
			StageLabel: stageLabel,
			Remaining:  deadline.Sub(nowT),
			Now:        now,
		}
		result := p.Run(ctx, in)
		if result.Status == StatusFail {
			return &PhaseError{Phase: p.Name(), Err: result.Err}
		}
		// Pass and Skip both fall through.
	}

	// All phases passed — clear any prior BUILD_ERRORS.md so the next gate
	// invocation sees a clean slate. Mirrors the rm at the tail of the
	// bash run_build_gate.
	g.Errors.ClearOnPass()
	return nil
}
