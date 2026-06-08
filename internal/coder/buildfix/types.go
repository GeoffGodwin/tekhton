// Package buildfix implements the M128 build-fix continuation-loop helpers
// (m39.2 port).
//
// stages/coder_buildfix_helpers.sh hosts the pure-logic and IO-bounded
// helpers consumed by stages/coder_buildfix.sh. m39.2 ports the helpers
// while leaving both bash files on disk; the loop body lands in m39.3 and
// the bash files delete together in m39.4. Every function below is either
// pure (returns the same output for the same input) or IO-bounded by a
// single explicit path argument — no env reads, no pipeline-state
// touching.
//
// The token vocabularies (Decision, Signal, Outcome, Class) are frozen by
// M127/M128/M129 contracts; m39.3 + M132's _collect_build_fix_stats_json
// pattern-match on the exact strings, so any drift must be a separate
// milestone.
package buildfix

// Decision is the M127 routing decision token. Frozen vocabulary —
// internal/errors/classify.go is the canonical producer; the helpers below
// consume it as opaque enum.
type Decision string

const (
	DecisionCodeDominant    Decision = "code_dominant"
	DecisionNoncodeDominant Decision = "noncode_dominant"
	DecisionMixedUncertain  Decision = "mixed_uncertain"
	DecisionUnknownOnly     Decision = "unknown_only"
)

// Signal is the M128 progress-signal token. Frozen vocabulary —
// _build_fix_progress_signal in the bash file emits these exact strings.
type Signal string

const (
	SignalImproved  Signal = "improved"
	SignalUnchanged Signal = "unchanged"
	SignalWorsened  Signal = "worsened"
)

// Outcome is the loop-result token consumed by M132's
// _collect_build_fix_stats_json. Frozen vocabulary; ExportStats sanitizes
// unknown values to OutcomeNotRun.
type Outcome string

const (
	OutcomePassed     Outcome = "passed"
	OutcomeExhausted  Outcome = "exhausted"
	OutcomeNoProgress Outcome = "no_progress"
	OutcomeNotRun     Outcome = "not_run"
)

// Class is the terminal-class token written into the per-attempt report.
// Mirrors the taxonomy in lib/agent.sh / internal/errors.
type Class string

const (
	ClassSuccess  Class = "success"
	ClassMaxTurns Class = "max_turns"
	ClassError    Class = "error"
)

// Stats is the Goal-7 stats envelope. ExportStats populates it; the m39.3
// loop holds one and forwards it to the m39.4 orchestrator, which wires it
// to the M132 BUILD_FIX_* env vars at process boundary.
type Stats struct {
	Outcome              Outcome
	Attempts             int
	TurnBudgetUsed       int
	ProgressGateFailures int
}

// AttemptReport is one row of the per-attempt history written to
// BUILD_FIX_REPORT.md. AppendReport renders one section per call; the
// schema is operator-visible and consumed by downstream parsers (notes
// pipeline, watchtower) via simple grep/sed.
type AttemptReport struct {
	Attempt         int
	Budget          int
	TerminalClass   Class
	GateResult      string // "pass" | "fail"
	ProgressSignal  Signal
	ErrorCountDelta string // "prev→new"
	Classification  Decision
}

// Config holds the resolved knobs for a single Run() invocation (m39.3).
// m39.2 introduces it here so the helpers and the loop share the same
// shape; the m39.4 orchestrator resolves env → Config once at coder-stage
// entry and threads it through every helper that needs it.
type Config struct {
	// Enabled mirrors BUILD_FIX_ENABLED. Default true.
	Enabled bool

	// MaxAttempts mirrors BUILD_FIX_MAX_ATTEMPTS. Default 3. Set to 1 to
	// restore pre-M128 single-attempt behavior.
	MaxAttempts int

	// BaseTurnDivisor mirrors BUILD_FIX_BASE_TURN_DIVISOR. Default 3.
	// Base turn budget = EFFECTIVE_CODER_MAX_TURNS / BaseTurnDivisor,
	// floored at 8. Resolved upstream (in the m39.3 loop); helpers
	// consume the base directly.
	BaseTurnDivisor int

	// MaxTurnMultiplier mirrors BUILD_FIX_MAX_TURN_MULTIPLIER. Default
	// 100 (= 1.0×). Upper-bound clamp = EffectiveCoderMaxTurns *
	// MaxTurnMultiplier / 100. ComputeBudget defaults 0 → 100 to match
	// bash's ${VAR:-100} expansion.
	MaxTurnMultiplier int

	// RequireProgress mirrors BUILD_FIX_REQUIRE_PROGRESS. Default true.
	// When true, the m39.3 loop halts on attempt N≥2 if ProgressSignal
	// is unchanged or worsened.
	RequireProgress bool

	// TotalTurnCap mirrors BUILD_FIX_TOTAL_TURN_CAP. Default 120 (= 1.5×
	// the default CODER_MAX_TURNS=80). Cumulative turn budget across all
	// attempts; below the 8-turn floor the loop exits. Operators tuning
	// this should understand the 1.5× headroom — projects with large
	// test suites may want to bump to 200+.
	TotalTurnCap int

	// ClassificationRequired mirrors BUILD_FIX_CLASSIFICATION_REQUIRED
	// (M130 amendment C). Default false. When true, mixed-uncertain
	// classifications retry once then save_exit instead of always
	// retrying.
	ClassificationRequired bool

	// EffectiveCoderMaxTurns mirrors EFFECTIVE_CODER_MAX_TURNS (falling
	// back to CODER_MAX_TURNS). Default 80. ComputeBudget defaults
	// non-positive values to 80 to match bash's
	// ${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}} expansion.
	EffectiveCoderMaxTurns int
}

// DefaultConfig returns the bash-default values byte-identically. Tests
// assert struct equality against this — any drift fails red.
func DefaultConfig() Config {
	return Config{
		Enabled:                true,
		MaxAttempts:            3,
		BaseTurnDivisor:        3,
		MaxTurnMultiplier:      100,
		RequireProgress:        true,
		TotalTurnCap:           120,
		ClassificationRequired: false,
		EffectiveCoderMaxTurns: 80,
	}
}

// SecondaryCause is the typed M129 forward-integration sink. The bash
// helper exports SECONDARY_ERROR_* env vars directly; the Go port writes
// to this struct and the orchestrator wires the fields to the env vars at
// process boundary (or to set_secondary_cause when the M129 helper is
// available). Decouples the helpers package from environment side
// effects.
type SecondaryCause struct {
	Category    string
	Subcategory string
	Signal      string
	Source      string
}
