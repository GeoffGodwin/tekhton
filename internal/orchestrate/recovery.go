package orchestrate

import "github.com/geoffgodwin/tekhton/internal/proto"

// Classify is the Go port of `_classify_failure` in
// lib/orchestrate_classify.sh:121. It maps a stage outcome + persistent
// retry guards to a recovery action string that callers act on.
//
// The decision tree mirrors the bash version exactly so the parity tests at
// scripts/orchestrate-parity-check.sh assert byte-for-byte equivalence:
//
//	UPSTREAM errors                        → save_exit
//	AGENT_SCOPE/max_turns + env primary    → retry_ui_gate_env (M130 amend B)
//	AGENT_SCOPE/max_turns                  → split
//	AGENT_SCOPE/null_run                   → split
//	AGENT_SCOPE/null_activity_timeout      → save_exit
//	AGENT_SCOPE/activity_timeout           → save_exit
//	ENVIRONMENT/test_infra (no error_cat)  → retry_ui_gate_env (M130 amend A)
//	ENVIRONMENT errors                     → save_exit
//	PIPELINE errors                        → save_exit
//	CHANGES_REQUIRED / review_cycle_max    → bump_review
//	REPLAN_REQUIRED                        → save_exit
//	build errors + classification routing  → retry_coder_build | save_exit
//	unclassified                           → save_exit
//
// The function is pure — guards are read from the Loop receiver but not
// mutated here. Mutation happens in markGuard at the dispatch site so the
// classifier can stay easily unit-testable.
func (l *Loop) Classify(o StageOutcome, cfg Config) string {
	cat := o.ErrorCategory
	sub := o.ErrorSubcategory

	// Sustained UPSTREAM after retry envelope already exhausted.
	if cat == "UPSTREAM" {
		return proto.RecoverySaveExit
	}

	// M130 Amendment B: max_turns with env/test_infra primary cause is a
	// symptom — re-run the gate with hardened env (M126) instead of split.
	if cat == "AGENT_SCOPE" && sub == "max_turns" &&
		o.PrimaryCat == "ENVIRONMENT" && o.PrimarySub == "test_infra" &&
		!l.envGateRetried && cfg.UIGateEnvRetryEnabled {
		return proto.RecoveryRetryUIGateEnv
	}

	if cat == "AGENT_SCOPE" && sub == "max_turns" {
		return proto.RecoverySplit
	}

	if cat == "AGENT_SCOPE" && sub == "null_run" {
		return proto.RecoverySplit
	}

	if cat == "AGENT_SCOPE" && sub == "null_activity_timeout" {
		return proto.RecoverySaveExit
	}

	if cat == "AGENT_SCOPE" && sub == "activity_timeout" {
		return proto.RecoverySaveExit
	}

	// M130 Amendment A: env/test_infra primary cause is recoverable by
	// re-running with the deterministic gate profile (M126).
	if o.PrimaryCat == "ENVIRONMENT" && o.PrimarySub == "test_infra" &&
		!l.envGateRetried && cfg.UIGateEnvRetryEnabled {
		return proto.RecoveryRetryUIGateEnv
	}

	if cat == "ENVIRONMENT" {
		return proto.RecoverySaveExit
	}

	if cat == "PIPELINE" {
		return proto.RecoverySaveExit
	}

	// No agent-error classification — check VERDICT for review cycle exhaustion.
	switch o.Verdict {
	case "CHANGES_REQUIRED", "review_cycle_max":
		return proto.RecoveryBumpReview
	case "REPLAN_REQUIRED":
		return proto.RecoverySaveExit
	}

	// M130 Amendment C: build-gate routing is gated by the M127 confidence
	// classification token. The kill-switch BuildFixClassificationRequired=false
	// reverts to pre-M130 behavior (always retry on non-empty BUILD_ERRORS_FILE).
	if o.BuildErrorsPresent {
		if !cfg.BuildFixClassificationRequired {
			return proto.RecoveryRetryCoderBuild
		}
		switch o.BuildClassification {
		case "code_dominant", "unknown_only", "":
			return proto.RecoveryRetryCoderBuild
		case "mixed_uncertain":
			if !l.mixedBuildRetried {
				return proto.RecoveryRetryCoderBuild
			}
			return proto.RecoverySaveExit
		case "noncode_dominant":
			return proto.RecoverySaveExit
		}
	}

	// Unclassified — never retry unknown errors.
	return proto.RecoverySaveExit
}
