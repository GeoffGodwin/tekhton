#!/usr/bin/env bash
# =============================================================================
# diagnose_rules_registry.sh — Priority-ordered DIAGNOSE_RULES registry
#
# Sourced by lib/diagnose_rules.sh — do not run directly.
#
# Extracted from diagnose_rules.sh to keep the parent module under the 300-line
# ceiling and to decouple the registry from the rule function bodies, mirroring
# the precedent set by pipeline_order_policy.sh.
# =============================================================================

# Priority-ordered array. classify_failure_diag() applies rules top-down,
# stops at the first match. The three resilience-arc primary rules must beat
# generic build failure and max_turns; mixed_classification remains a
# low-confidence secondary rule; _rule_unknown remains last.

# shellcheck disable=SC2034  # Used by lib/diagnose.sh
DIAGNOSE_RULES=(
    "_rule_ui_gate_interactive_reporter"
    "_rule_preflight_interactive_config"
    "_rule_build_fix_exhausted"
    "_rule_build_failure"
    "_rule_max_turns"
    "_rule_review_loop"
    "_rule_security_halt"
    "_rule_intake_clarity"
    "_rule_quota_exhausted"
    "_rule_stuck_loop"
    "_rule_mixed_classification"
    "_rule_turn_exhaustion"
    "_rule_split_depth"
    "_rule_transient_error"
    "_rule_test_audit_failure"
    "_rule_migration_crash"
    "_rule_version_mismatch"
    "_rule_unknown"
)
