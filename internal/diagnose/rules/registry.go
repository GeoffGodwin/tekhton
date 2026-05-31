// Package rules — m32.2 Go-native rule registry for the diagnose engine.
//
// Replaces the m32.1 BashRuleAdapter. The priority order in `registry` MUST
// mirror lib/diagnose_rules_registry.sh:DIAGNOSE_RULES byte-for-byte; the
// order-mismatch test in registry_test.go fails red on drift.
//
// Each rule lives in a sibling file (core.go, extra.go, migration.go,
// resilience.go, resilience_preflight.go) chosen by the bash source file
// the rule was ported from. Every rule is a zero-value struct implementing
// diagnose.Rule — Name() returns the bash function name (e.g.
// "_rule_max_turns") so the engine's `[diag] rule=...` emit line stays
// byte-identical to v4.31.x.
//
// Adding a new rule is a one-file change: drop a struct in the appropriate
// sibling file, register it in `registry` below, write the per-rule
// match/no-match table test, and update the want slice in
// TestRuleOrder_MatchesBashRegistry. No engine modification required.
package rules

import "github.com/geoffgodwin/tekhton/internal/diagnose"

// registry is the priority-ordered rule list. classify_failure_diag in bash
// walks this top-down and stops at the first match — the Go engine does the
// same via diagnose.Engine.Run. Resilience-arc primary rules MUST stay at
// the top so they beat the generic build_failure / max_turns rules; the
// always-true _rule_unknown fallback MUST stay last.
//
//nolint:gochecknoglobals // registry is data, not configuration.
var registry = []diagnose.Rule{
	// Resilience-arc primary rules (m133) — beat generic build_failure / max_turns.
	UIGateInteractiveReporter{},
	PreflightInteractiveConfig{},

	// Build / max-turns / review-loop core.
	BuildFixExhausted{},
	BuildFailure{},
	MaxTurns{},
	ReviewLoop{},
	SecurityHalt{},
	IntakeClarity{},
	QuotaExhausted{},
	StuckLoop{},

	// Lower-confidence / secondary rules.
	MixedClassification{},
	TurnExhaustion{},
	SplitDepth{},
	TransientError{},
	TestAuditFailure{},

	// Migration / version-mismatch.
	MigrationCrash{},
	VersionMismatch{},

	// Always-last fallback.
	Unknown{},
}

// Registry is the m32.2 production diagnose.RuleProvider. Constructed via
// New(); the zero-value receiver intentionally has no fields so the wired
// rules stay deterministic.
type Registry struct{}

// New returns the Registry value the CLI wires into diagnose.NewEngine.
func New() *Registry { return &Registry{} }

// Rules implements diagnose.RuleProvider by returning the package-level
// `registry` slice. Callers must NOT mutate the returned slice — it is the
// canonical priority order.
func (*Registry) Rules() []diagnose.Rule {
	out := make([]diagnose.Rule, len(registry))
	copy(out, registry)
	return out
}
