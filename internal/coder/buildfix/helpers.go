package buildfix

// ComputeBudget mirrors _compute_build_fix_budget. Returns 0 when the
// cumulative cap is exhausted (signal to halt the loop).
//
// Schedule (attempt-indexed):
//
//	1     → 1.0× base
//	2     → 1.5× base (integer arithmetic: base*3/2, NOT float math)
//	3+    → 2.0× base
//
// Clamps applied in order: floor 8, upper (EffectiveCoderMaxTurns *
// MaxTurnMultiplier / 100, floored at 8), cumulative remaining cap.
// Bash uses ${VAR:-DEFAULT} expansion for the three env knobs; the Go
// port mirrors that with explicit zero-defaults to 80 / 100 / 120.
func ComputeBudget(attempt, base, used int, cfg Config) int {
	maxTurns := cfg.EffectiveCoderMaxTurns
	if maxTurns <= 0 {
		maxTurns = 80
	}
	multiplier := cfg.MaxTurnMultiplier
	if multiplier <= 0 {
		multiplier = 100
	}
	totalCap := cfg.TotalTurnCap
	if totalCap <= 0 {
		totalCap = 120
	}

	var budget int
	switch attempt {
	case 1:
		budget = base
	case 2:
		budget = base * 3 / 2
	default:
		budget = base * 2
	}

	if budget < 8 {
		budget = 8
	}

	upper := maxTurns * multiplier / 100
	if upper < 8 {
		upper = 8
	}
	if budget > upper {
		budget = upper
	}

	remaining := totalCap - used
	if remaining <= 0 || remaining < 8 {
		return 0
	}
	if budget > remaining {
		budget = remaining
	}
	return budget
}

// ProgressSignal mirrors _build_fix_progress_signal. Pure function.
//   - SignalImproved   when newCount < prevCount
//   - SignalWorsened   when newCount > prevCount
//   - SignalUnchanged  when counts equal AND tails equal
//   - SignalImproved   when counts equal but tails differ (some signal moved)
func ProgressSignal(prevCount, newCount int, prevTail, newTail string) Signal {
	if newCount < prevCount {
		return SignalImproved
	}
	if newCount > prevCount {
		return SignalWorsened
	}
	if prevTail == newTail {
		return SignalUnchanged
	}
	return SignalImproved
}

// TerminalClass mirrors _build_fix_terminal_class. Maps run_agent's exit
// code + turn count to a coarse terminal class for the per-attempt
// report.
//
//	success   — exitCode == 0
//	max_turns — exitCode != 0 AND maxTurns > 0 AND turns >= maxTurns
//	error     — otherwise
func TerminalClass(exitCode, turns, maxTurns int) Class {
	if exitCode == 0 {
		return ClassSuccess
	}
	if maxTurns > 0 && turns >= maxTurns {
		return ClassMaxTurns
	}
	return ClassError
}

// ExtraContextFor mirrors _bf_extra_context_for_decision. Returns the
// route-specific extra-context block appended to the build_fix prompt.
// Empty for DecisionCodeDominant and DecisionNoncodeDominant (the latter
// never reaches this code path in the loop, but the empty-string return
// is defensive — a future refactor that re-routes noncode through the
// loop must not inject a stale mixed_uncertain context block).
func ExtraContextFor(d Decision, diagnosisPath string) string {
	switch d {
	case DecisionMixedUncertain:
		if diagnosisPath == "" {
			diagnosisPath = ".tekhton/BUILD_ROUTING_DIAGNOSIS.md"
		}
		return "## Routing Context (mixed_uncertain)\n" +
			"Both code and non-code error signals were detected in this run. See " +
			diagnosisPath +
			" for category counts and top diagnoses. Fix code errors first; if the build still fails, the remaining issues may be environmental and should be flagged for human action rather than retried."
	case DecisionUnknownOnly:
		return "## Routing Context (unknown_only)\n" +
			"No recognized error signatures matched the build output. This is the bounded fallback path: attempt one fix pass, then surface for human triage if it does not converge."
	default:
		return ""
	}
}

// ExportStats mirrors _export_build_fix_stats. Populates the Stats struct
// in place; sanitizes unrecognized Outcome tokens to OutcomeNotRun.
// Bash exports four env vars (BUILD_FIX_OUTCOME, BUILD_FIX_ATTEMPTS,
// BUILD_FIX_TURN_BUDGET_USED, BUILD_FIX_PROGRESS_GATE_FAILURES); the Go
// port writes to the typed struct and the m39.4 orchestrator wires the
// fields to env at process boundary.
//
// Attempts / TurnBudgetUsed / ProgressGateFailures are preserved verbatim
// — the m39.3 loop populates them before calling ExportStats so the
// "${VAR:-0}" defaulting in the bash version is a no-op here.
func ExportStats(out *Stats, outcome Outcome) {
	if out == nil {
		return
	}
	switch outcome {
	case OutcomePassed, OutcomeExhausted, OutcomeNoProgress, OutcomeNotRun:
		out.Outcome = outcome
	default:
		out.Outcome = OutcomeNotRun
	}
}

// SetSecondaryCause mirrors _build_fix_set_secondary_cause. Writes the
// four fixed values that signal "build-fix budget exhausted via
// AGENT_SCOPE/max_turns" to the typed SecondaryCause struct. The m39.4
// orchestrator wires the fields to the SECONDARY_ERROR_* env vars (or
// calls set_secondary_cause from lib/failure_context.sh) at process
// boundary.
func SetSecondaryCause(out *SecondaryCause) {
	if out == nil {
		return
	}
	out.Category = "AGENT_SCOPE"
	out.Subcategory = "max_turns"
	out.Signal = "build_fix_budget_exhausted"
	out.Source = "coder_build_fix"
}
