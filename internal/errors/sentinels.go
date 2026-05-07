// Package errors holds the cross-cutting error vocabulary shared across
// Tekhton's Go subsystems and the `tekhton diagnose classify` build-error
// pattern classifier ported from lib/error_patterns_classify.sh.
//
// Subsystem-specific errors stay where they live (supervisor.AgentError,
// state.ErrCorrupt, dag.ValidationError, config.ErrValidation) but wrap one
// of the common sentinels declared here so a single errors.Is(err, X) call
// works across subsystems without each caller importing every error package.
//
// Identity rule: the sentinels are simple errors.New values. Wrap with %w
// (or via a custom Is method on a struct error) to make a subsystem error
// match. Do not promote new common sentinels lightly — five is plenty;
// finer-grained dimensions stay subsystem-local (m17 Watch For).
package errors

import "errors"

// Common error sentinels. Match with errors.Is.
var (
	// ErrTransient marks an error that may resolve by itself on retry.
	// Supervisor's AgentError.Is matches when Transient: true.
	ErrTransient = errors.New("tekhton: transient error")

	// ErrFatal marks an error that will not resolve on retry. State
	// corruption, legacy format, and most pipeline errors wrap this.
	ErrFatal = errors.New("tekhton: fatal error")

	// ErrUserActionRequired marks an error whose resolution requires a
	// human (auth lockout, missing dependency, manifest cycle, etc.).
	// Recovery dispatch routes these to HUMAN_ACTION_REQUIRED.md.
	ErrUserActionRequired = errors.New("tekhton: user action required")

	// ErrConfigInvalid marks a configuration that violates a structural
	// invariant. dag.ValidationError and config.ErrValidation wrap this.
	ErrConfigInvalid = errors.New("tekhton: config invalid")

	// ErrUpstreamLimit marks a rate-limit / quota exhaustion class from
	// the upstream API. Distinct from ErrTransient because the wait time
	// is typically much longer (minutes, not seconds).
	ErrUpstreamLimit = errors.New("tekhton: upstream rate limit")
)
