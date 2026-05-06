package supervisor

import (
	"errors"
	"fmt"

	"github.com/geoffgodwin/tekhton/internal/proto"
)

// AgentError is the typed error V3's bash supervisor encoded as a pipe-delimited
// string ("CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE", produced by lib/errors.sh
// classify_error). m07 lifts that vocabulary into Go so callers can route on
// errors.Is / errors.As instead of cutting fields out of strings.
//
// Identity rule: errors.Is matches on Category+Subcategory ONLY. Transient
// and Wrapped are payload, not identity. Sentinel exemplars (ErrUpstreamRateLimit
// etc.) carry zero Wrapped err and still match a live error that wraps a real
// underlying cause.
type AgentError struct {
	Category    string
	Subcategory string
	Transient   bool
	Wrapped     error
}

// Error renders the V3 wire format CATEGORY|SUBCATEGORY|TRANSIENT|MESSAGE so
// any bash consumer logging or parsing a Go-side string still sees the same
// fields. The MESSAGE half is the Wrapped error's text, or empty if absent.
func (e *AgentError) Error() string {
	msg := ""
	if e.Wrapped != nil {
		msg = e.Wrapped.Error()
	}
	transient := "false"
	if e.Transient {
		transient = "true"
	}
	return fmt.Sprintf("%s|%s|%s|%s", e.Category, e.Subcategory, transient, msg)
}

// Is reports whether target is the same (Category, Subcategory) class as e.
// The Transient flag and Wrapped cause deliberately do not participate.
func (e *AgentError) Is(target error) bool {
	var ae *AgentError
	if !errors.As(target, &ae) {
		return false
	}
	return e.Category == ae.Category && e.Subcategory == ae.Subcategory
}

// Unwrap returns the underlying cause for standard errors.Unwrap chain support.
func (e *AgentError) Unwrap() error { return e.Wrapped }

// Sentinel exemplars — the V3 error vocabulary projected into Go. Compare with
// errors.Is. Source of truth: lib/errors.sh classify_error(). m10 deletes the
// bash side; until then any change here must be mirrored there (the m07
// taxonomy-diff script enforces shape parity).
//
//nolint:gochecknoglobals // sentinels by design — package-level value identity is the API.
var (
	// UPSTREAM — API provider failures. Transient except api_auth and quota_exhausted.
	ErrUpstreamRateLimit  = &AgentError{Category: "UPSTREAM", Subcategory: "api_rate_limit", Transient: true}
	ErrUpstreamOverloaded = &AgentError{Category: "UPSTREAM", Subcategory: "api_overloaded", Transient: true}
	ErrUpstream500        = &AgentError{Category: "UPSTREAM", Subcategory: "api_500", Transient: true}
	ErrUpstreamAuth       = &AgentError{Category: "UPSTREAM", Subcategory: "api_auth", Transient: false}
	ErrUpstreamTimeout    = &AgentError{Category: "UPSTREAM", Subcategory: "api_timeout", Transient: true}
	ErrUpstreamUnknown    = &AgentError{Category: "UPSTREAM", Subcategory: "api_unknown", Transient: true}
	ErrQuotaExhausted     = &AgentError{Category: "UPSTREAM", Subcategory: "quota_exhausted", Transient: false}

	// ENVIRONMENT — local system. OOM and network are transient; others permanent.
	ErrEnvOOM         = &AgentError{Category: "ENVIRONMENT", Subcategory: "oom", Transient: true}
	ErrEnvNetwork     = &AgentError{Category: "ENVIRONMENT", Subcategory: "network", Transient: true}
	ErrEnvDiskFull    = &AgentError{Category: "ENVIRONMENT", Subcategory: "disk_full", Transient: false}
	ErrEnvMissingDep  = &AgentError{Category: "ENVIRONMENT", Subcategory: "missing_dep", Transient: false}
	ErrEnvPermissions = &AgentError{Category: "ENVIRONMENT", Subcategory: "permissions", Transient: false}
	ErrEnvUnknown     = &AgentError{Category: "ENVIRONMENT", Subcategory: "env_unknown", Transient: false}

	// AGENT_SCOPE — agent-level failures. All permanent.
	ErrAgentNullRun             = &AgentError{Category: "AGENT_SCOPE", Subcategory: "null_run", Transient: false}
	ErrAgentMaxTurns            = &AgentError{Category: "AGENT_SCOPE", Subcategory: "max_turns", Transient: false}
	ErrAgentActivityTimeout     = &AgentError{Category: "AGENT_SCOPE", Subcategory: "activity_timeout", Transient: false}
	ErrAgentNullActivityTimeout = &AgentError{Category: "AGENT_SCOPE", Subcategory: "null_activity_timeout", Transient: false}
	ErrAgentNoSummary           = &AgentError{Category: "AGENT_SCOPE", Subcategory: "no_summary", Transient: false}
	ErrAgentScopeUnknown        = &AgentError{Category: "AGENT_SCOPE", Subcategory: "scope_unknown", Transient: false}

	// PIPELINE — Tekhton internal. All permanent.
	ErrPipelineStateCorrupt  = &AgentError{Category: "PIPELINE", Subcategory: "state_corrupt", Transient: false}
	ErrPipelineConfigError   = &AgentError{Category: "PIPELINE", Subcategory: "config_error", Transient: false}
	ErrPipelineMissingFile   = &AgentError{Category: "PIPELINE", Subcategory: "missing_file", Transient: false}
	ErrPipelineTemplateError = &AgentError{Category: "PIPELINE", Subcategory: "template_error", Transient: false}
	ErrPipelineInternal      = &AgentError{Category: "PIPELINE", Subcategory: "internal", Transient: false}

	// ErrFatalAgent is the catch-all "stop retrying" sentinel callers compare
	// against when only the transient/fatal axis matters. Aliases scope_unknown.
	ErrFatalAgent = ErrAgentScopeUnknown
)

// classifyResult maps an AgentResultV1 into a typed error. Returns nil for
// terminal-success outcomes (success, turn_exhausted) — the retry envelope's
// "no error" signal. For any failure outcome it builds an AgentError from the
// result's ErrorCategory/ErrorSubcategory if populated, otherwise infers from
// the coarser Outcome string (m06 results that haven't been classified yet).
func classifyResult(r *proto.AgentResultV1) error {
	if r == nil {
		return nil
	}
	switch r.Outcome {
	case proto.OutcomeSuccess, proto.OutcomeTurnExhausted:
		return nil
	}

	if r.ErrorCategory != "" || r.ErrorSubcategory != "" {
		return &AgentError{
			Category:    r.ErrorCategory,
			Subcategory: r.ErrorSubcategory,
			Transient:   r.ErrorTransient,
			Wrapped:     errFromResultMessage(r),
		}
	}

	switch r.Outcome {
	case proto.OutcomeActivityTimeout:
		ae := *ErrAgentActivityTimeout
		ae.Wrapped = errFromResultMessage(r)
		return &ae
	case proto.OutcomeTransientError:
		ae := *ErrUpstreamUnknown
		ae.Wrapped = errFromResultMessage(r)
		return &ae
	}

	ae := *ErrFatalAgent
	ae.Wrapped = errFromResultMessage(r)
	return &ae
}

func errFromResultMessage(r *proto.AgentResultV1) error {
	if r == nil || r.ErrorMessage == "" {
		return nil
	}
	return errors.New(r.ErrorMessage)
}
