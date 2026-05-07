package errors_test

import (
	stderrs "errors"
	"fmt"
	"testing"

	"github.com/geoffgodwin/tekhton/internal/config"
	"github.com/geoffgodwin/tekhton/internal/dag"
	terr "github.com/geoffgodwin/tekhton/internal/errors"
	"github.com/geoffgodwin/tekhton/internal/state"
	"github.com/geoffgodwin/tekhton/internal/supervisor"
)

// Verifies the m17 cross-subsystem matching contract: a single errors.Is call
// against a common sentinel must work for every wrapping subsystem.

func TestStateErrors_MatchErrFatal(t *testing.T) {
	t.Parallel()
	if !stderrs.Is(state.ErrCorrupt, terr.ErrFatal) {
		t.Errorf("state.ErrCorrupt must match terr.ErrFatal")
	}
	if !stderrs.Is(state.ErrLegacyFormat, terr.ErrFatal) {
		t.Errorf("state.ErrLegacyFormat must match terr.ErrFatal")
	}
	if stderrs.Is(state.ErrNotFound, terr.ErrFatal) {
		t.Errorf("state.ErrNotFound must NOT match terr.ErrFatal (file-missing is recoverable)")
	}
	// fmt-wrapped variant still matches
	wrapped := fmt.Errorf("read: %w", state.ErrCorrupt)
	if !stderrs.Is(wrapped, terr.ErrFatal) {
		t.Errorf("wrapped state.ErrCorrupt must still match terr.ErrFatal")
	}
	if !stderrs.Is(wrapped, state.ErrCorrupt) {
		t.Errorf("wrapped state.ErrCorrupt must still match state.ErrCorrupt")
	}
}

func TestSupervisorErrors_MatchTransientAxis(t *testing.T) {
	t.Parallel()
	transient := supervisor.ErrUpstreamRateLimit
	if !stderrs.Is(transient, terr.ErrTransient) {
		t.Errorf("transient supervisor sentinel must match terr.ErrTransient")
	}
	if stderrs.Is(transient, terr.ErrFatal) {
		t.Errorf("transient sentinel must NOT match terr.ErrFatal")
	}

	fatal := supervisor.ErrUpstreamAuth
	if stderrs.Is(fatal, terr.ErrTransient) {
		t.Errorf("fatal supervisor sentinel must NOT match terr.ErrTransient")
	}
	if !stderrs.Is(fatal, terr.ErrFatal) {
		t.Errorf("fatal supervisor sentinel must match terr.ErrFatal")
	}
}

func TestDagErrors_MatchErrConfigInvalid(t *testing.T) {
	t.Parallel()
	ve := &dag.ValidationError{
		ID: "m99", Kind: "cycle", Msg: "ERROR: m99 → m99",
		Wrapped: dag.ErrCycle,
	}
	if !stderrs.Is(ve, terr.ErrConfigInvalid) {
		t.Errorf("dag.ValidationError must match terr.ErrConfigInvalid")
	}
	// Legacy (per-kind) matching must still work.
	if !stderrs.Is(ve, dag.ErrCycle) {
		t.Errorf("dag.ValidationError must still match dag.ErrCycle via Unwrap")
	}
	if stderrs.Is(ve, dag.ErrMissingDep) {
		t.Errorf("dag.ValidationError(cycle) must NOT match dag.ErrMissingDep")
	}
}

func TestConfigErrors_MatchErrConfigInvalid(t *testing.T) {
	t.Parallel()
	if !stderrs.Is(config.ErrValidation, terr.ErrConfigInvalid) {
		t.Errorf("config.ErrValidation must match terr.ErrConfigInvalid")
	}
	wrapped := fmt.Errorf("strict-mode failed: %w", config.ErrValidation)
	if !stderrs.Is(wrapped, terr.ErrConfigInvalid) {
		t.Errorf("wrapped config.ErrValidation must still match terr.ErrConfigInvalid")
	}
}

func TestSupervisorErrors_PreserveSiblingMatch(t *testing.T) {
	t.Parallel()
	// m07 contract: errors.Is between sibling AgentErrors still uses
	// (Category, Subcategory) identity, not the transient axis.
	a := supervisor.ErrUpstreamRateLimit
	b := supervisor.ErrUpstreamOverloaded
	if stderrs.Is(a, b) {
		t.Errorf("rate_limit must not match overloaded")
	}
	if !stderrs.Is(a, supervisor.ErrUpstreamRateLimit) {
		t.Errorf("self-match broken")
	}
}
