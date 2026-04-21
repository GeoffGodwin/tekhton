#!/usr/bin/env bash
# =============================================================================
# test_pipeline_order_m110.sh — Unit tests for M110 additions to
# lib/pipeline_order.sh: get_stage_metrics_key, get_stage_policy, and
# get_run_stage_plan.
#
# Tests:
#  1. get_stage_metrics_key — all alias pairs from §6 normalize correctly
#  2. get_stage_metrics_key — idempotent on canonical keys
#  3. get_stage_metrics_key — passthrough for unregistered stages
#  4. get_stage_policy — all stages in §2 table return correct record shape
#  5. get_stage_policy — unknown stage falls back to op record
#  6. get_stage_policy — accepts internal names via metrics-key routing
#  7. get_run_stage_plan — bare task (all defaults)
#  8. get_run_stage_plan — SKIP_SECURITY=true
#  9. get_run_stage_plan — DOCS_AGENT_ENABLED=true
# 10. get_run_stage_plan — PREFLIGHT_ENABLED=false (milestone-style mode)
# 11. get_run_stage_plan — INTAKE_AGENT_ENABLED=false
# 12. get_run_stage_plan — FORCE_AUDIT=true (architect promoted)
# 13. get_run_stage_plan — drift observation count above threshold
# 14. get_run_stage_plan — runs-since-audit at threshold
# 15. get_run_stage_plan — SECURITY_AGENT_ENABLED=false
# 16. get_run_stage_plan — PIPELINE_ORDER=test_first
# 17. get_run_stage_plan — start-at review (plan unchanged; full list returned)
# 18. get_run_stage_plan — fix-drift mode (FORCE_AUDIT via env) + SKIP_SECURITY
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/pipeline_order.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

_reset_env() {
    unset PIPELINE_ORDER PREFLIGHT_ENABLED INTAKE_AGENT_ENABLED FORCE_AUDIT
    unset DRIFT_OBSERVATION_COUNT DRIFT_OBSERVATION_THRESHOLD
    unset DRIFT_RUNS_SINCE_AUDIT DRIFT_RUNS_SINCE_AUDIT_THRESHOLD
    unset SKIP_SECURITY SECURITY_AGENT_ENABLED SKIP_DOCS DOCS_AGENT_ENABLED
}

_reset_env

# =============================================================================
# Phase 1: get_stage_metrics_key — alias normalisation
# =============================================================================

echo "=== Phase 1: get_stage_metrics_key aliases ==="

# reviewer → review
assert_eq "1.1 reviewer → review" \
    "review" "$(get_stage_metrics_key reviewer)"

# test_verify → tester
assert_eq "1.2 test_verify → tester" \
    "tester" "$(get_stage_metrics_key test_verify)"

# test → tester
assert_eq "1.3 test → tester" \
    "tester" "$(get_stage_metrics_key test)"

# test_write → tester-write
assert_eq "1.4 test_write → tester-write" \
    "tester-write" "$(get_stage_metrics_key test_write)"

# tester_write → tester-write
assert_eq "1.5 tester_write → tester-write" \
    "tester-write" "$(get_stage_metrics_key tester_write)"

# jr_coder → rework
assert_eq "1.6 jr_coder → rework" \
    "rework" "$(get_stage_metrics_key jr_coder)"

# jr-coder → rework
assert_eq "1.7 jr-coder → rework" \
    "rework" "$(get_stage_metrics_key jr-coder)"

# wrap_up → wrap-up
assert_eq "1.8 wrap_up → wrap-up" \
    "wrap-up" "$(get_stage_metrics_key wrap_up)"

# =============================================================================
# Phase 2: get_stage_metrics_key — idempotent on canonical keys
# =============================================================================

echo "=== Phase 2: get_stage_metrics_key idempotent ==="

assert_eq "2.1 review idempotent" \
    "review" "$(get_stage_metrics_key review)"

assert_eq "2.2 tester idempotent" \
    "tester" "$(get_stage_metrics_key tester)"

assert_eq "2.3 tester-write idempotent" \
    "tester-write" "$(get_stage_metrics_key tester-write)"

assert_eq "2.4 rework idempotent" \
    "rework" "$(get_stage_metrics_key rework)"

assert_eq "2.5 wrap-up idempotent" \
    "wrap-up" "$(get_stage_metrics_key wrap-up)"

assert_eq "2.6 coder idempotent (passthrough)" \
    "coder" "$(get_stage_metrics_key coder)"

assert_eq "2.7 security idempotent (passthrough)" \
    "security" "$(get_stage_metrics_key security)"

# =============================================================================
# Phase 3: get_stage_metrics_key — passthrough for unregistered stages
# =============================================================================

echo "=== Phase 3: get_stage_metrics_key passthrough ==="

# Unregistered name goes through get_stage_display_label fallback (underscore → hyphen)
assert_eq "3.1 unregistered underscore → hyphen" \
    "some-new-stage" "$(get_stage_metrics_key some_new_stage)"

assert_eq "3.2 unregistered no-underscore → unchanged" \
    "intake" "$(get_stage_metrics_key intake)"

# =============================================================================
# Phase 4: get_stage_policy — all §2 table entries
# =============================================================================

echo "=== Phase 4: get_stage_policy §2 table entries ==="

# Pre-stages
assert_eq "4.01 preflight → pre record" \
    "pre|yes|yes|yes|-" "$(get_stage_policy preflight)"

assert_eq "4.02 intake → pre record" \
    "pre|yes|yes|yes|-" "$(get_stage_policy intake)"

assert_eq "4.03 architect → conditional pill" \
    "pre|conditional|yes|yes|-" "$(get_stage_policy architect)"

# Sub-stages
assert_eq "4.04 architect-remediation → sub with parent=architect" \
    "sub|no|yes|yes|architect" "$(get_stage_policy architect-remediation)"

assert_eq "4.05 scout → sub with parent=coder" \
    "sub|no|yes|yes|coder" "$(get_stage_policy scout)"

# Pipeline stages
assert_eq "4.06 coder → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy coder)"

assert_eq "4.07 security → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy security)"

assert_eq "4.08 review → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy review)"

assert_eq "4.09 docs → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy docs)"

assert_eq "4.10 tester → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy tester)"

assert_eq "4.11 tester-write → pipeline record" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy tester-write)"

# Sub-stage rework
assert_eq "4.12 rework → sub with parent=review" \
    "sub|no|yes|yes|review" "$(get_stage_policy rework)"

# Post-stage
assert_eq "4.13 wrap-up → post record" \
    "post|yes|yes|yes|-" "$(get_stage_policy wrap-up)"

# =============================================================================
# Phase 5: get_stage_policy — unknown stage falls back to op record
# =============================================================================

echo "=== Phase 5: get_stage_policy unknown → op fallback ==="

assert_eq "5.1 completely unknown → op|no|no|yes|-" \
    "op|no|no|yes|-" "$(get_stage_policy totally_unknown_stage)"

assert_eq "5.2 empty string → op fallback" \
    "op|no|no|yes|-" "$(get_stage_policy "")"

# =============================================================================
# Phase 6: get_stage_policy — accepts internal names via metrics-key routing
# =============================================================================

echo "=== Phase 6: get_stage_policy accepts internal names ==="

# reviewer → resolved to review → pipeline record
assert_eq "6.1 reviewer → pipeline record (via metrics key)" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy reviewer)"

# test_verify → tester → pipeline record
assert_eq "6.2 test_verify → pipeline record (via metrics key)" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy test_verify)"

# test_write → tester-write → pipeline record
assert_eq "6.3 test_write → pipeline record (via metrics key)" \
    "pipeline|yes|yes|yes|-" "$(get_stage_policy test_write)"

# jr_coder → rework → sub record
assert_eq "6.4 jr_coder → rework sub record (via metrics key)" \
    "sub|no|yes|yes|review" "$(get_stage_policy jr_coder)"

# wrap_up → wrap-up → post record
assert_eq "6.5 wrap_up → post record (via metrics key)" \
    "post|yes|yes|yes|-" "$(get_stage_policy wrap_up)"

# =============================================================================
# Phase 7: get_run_stage_plan — bare task (all defaults)
# =============================================================================

echo "=== Phase 7: get_run_stage_plan bare task ==="

_reset_env
PIPELINE_ORDER="standard"
assert_eq "7.1 bare task: preflight intake coder security review tester wrap-up" \
    "preflight intake coder security review tester wrap-up" \
    "$(get_run_stage_plan)"

# =============================================================================
# Phase 8: get_run_stage_plan — SKIP_SECURITY=true
# =============================================================================

echo "=== Phase 8: get_run_stage_plan SKIP_SECURITY=true ==="

_reset_env
PIPELINE_ORDER="standard"
SKIP_SECURITY="true"
assert_eq "8.1 SKIP_SECURITY: security omitted" \
    "preflight intake coder review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 9: get_run_stage_plan — DOCS_AGENT_ENABLED=true
# =============================================================================

echo "=== Phase 9: get_run_stage_plan DOCS_AGENT_ENABLED=true ==="

_reset_env
PIPELINE_ORDER="standard"
DOCS_AGENT_ENABLED="true"
assert_eq "9.1 DOCS_AGENT_ENABLED: docs between coder and security" \
    "preflight intake coder docs security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 10: get_run_stage_plan — PREFLIGHT_ENABLED=false
# =============================================================================

echo "=== Phase 10: get_run_stage_plan PREFLIGHT_ENABLED=false ==="

_reset_env
PIPELINE_ORDER="standard"
PREFLIGHT_ENABLED="false"
assert_eq "10.1 PREFLIGHT_ENABLED=false: no preflight stage" \
    "intake coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 11: get_run_stage_plan — INTAKE_AGENT_ENABLED=false
# =============================================================================

echo "=== Phase 11: get_run_stage_plan INTAKE_AGENT_ENABLED=false ==="

_reset_env
PIPELINE_ORDER="standard"
INTAKE_AGENT_ENABLED="false"
assert_eq "11.1 INTAKE_AGENT_ENABLED=false: no intake stage" \
    "preflight coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 12: get_run_stage_plan — FORCE_AUDIT=true (architect promoted)
# =============================================================================

echo "=== Phase 12: get_run_stage_plan FORCE_AUDIT=true ==="

_reset_env
PIPELINE_ORDER="standard"
FORCE_AUDIT="true"
assert_eq "12.1 FORCE_AUDIT: architect in plan after intake" \
    "preflight intake architect coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 13: get_run_stage_plan — drift observations above threshold
# =============================================================================

echo "=== Phase 13: get_run_stage_plan drift count above threshold ==="

_reset_env
PIPELINE_ORDER="standard"
DRIFT_OBSERVATION_COUNT="10"
DRIFT_OBSERVATION_THRESHOLD="8"
assert_eq "13.1 drift count >= threshold: architect promoted" \
    "preflight intake architect coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# Count at threshold (equal, so >=)
_reset_env
PIPELINE_ORDER="standard"
DRIFT_OBSERVATION_COUNT="8"
DRIFT_OBSERVATION_THRESHOLD="8"
assert_eq "13.2 drift count == threshold: architect promoted" \
    "preflight intake architect coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# Count below threshold
_reset_env
PIPELINE_ORDER="standard"
DRIFT_OBSERVATION_COUNT="7"
DRIFT_OBSERVATION_THRESHOLD="8"
assert_eq "13.3 drift count < threshold: architect NOT promoted" \
    "preflight intake coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 14: get_run_stage_plan — runs-since-audit at threshold
# =============================================================================

echo "=== Phase 14: get_run_stage_plan runs-since-audit threshold ==="

_reset_env
PIPELINE_ORDER="standard"
DRIFT_RUNS_SINCE_AUDIT="5"
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD="5"
assert_eq "14.1 runs_since >= threshold: architect promoted" \
    "preflight intake architect coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

_reset_env
PIPELINE_ORDER="standard"
DRIFT_RUNS_SINCE_AUDIT="4"
DRIFT_RUNS_SINCE_AUDIT_THRESHOLD="5"
assert_eq "14.2 runs_since < threshold: architect NOT promoted" \
    "preflight intake coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 15: get_run_stage_plan — SECURITY_AGENT_ENABLED=false
# =============================================================================

echo "=== Phase 15: get_run_stage_plan SECURITY_AGENT_ENABLED=false ==="

_reset_env
PIPELINE_ORDER="standard"
SECURITY_AGENT_ENABLED="false"
assert_eq "15.1 SECURITY_AGENT_ENABLED=false: security omitted" \
    "preflight intake coder review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 16: get_run_stage_plan — PIPELINE_ORDER=test_first
# =============================================================================

echo "=== Phase 16: get_run_stage_plan test_first order ==="

_reset_env
PIPELINE_ORDER="test_first"
assert_eq "16.1 test_first: tester-write before coder" \
    "preflight intake tester-write coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 17: get_run_stage_plan — --start-at review (plan unchanged)
# =============================================================================

echo "=== Phase 17: get_run_stage_plan start-at has no effect on the plan ==="

# start-at is handled by should_run_stage(), not get_run_stage_plan().
# The plan always returns the full planned stage list for the run mode.
# This test documents that the plan is not filtered by start-at.
_reset_env
PIPELINE_ORDER="standard"
assert_eq "17.1 plan includes all stages regardless of any start-at flag" \
    "preflight intake coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Phase 18: get_run_stage_plan — fix-drift mode combination
# =============================================================================

echo "=== Phase 18: get_run_stage_plan fix-drift + SKIP_SECURITY ==="

_reset_env
PIPELINE_ORDER="standard"
FORCE_AUDIT="true"
SKIP_SECURITY="true"
assert_eq "18.1 fix-drift + SKIP_SECURITY: architect in plan, no security" \
    "preflight intake architect coder review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# PREFLIGHT_ENABLED=false + INTAKE_AGENT_ENABLED=false + FORCE_AUDIT=true
_reset_env
PIPELINE_ORDER="standard"
PREFLIGHT_ENABLED="false"
INTAKE_AGENT_ENABLED="false"
FORCE_AUDIT="true"
assert_eq "18.2 no preflight, no intake, architect promoted" \
    "architect coder security review tester wrap-up" \
    "$(get_run_stage_plan)"
_reset_env

# =============================================================================
# Done
# =============================================================================

if [[ "$FAIL" -ne 0 ]]; then
    echo "FAILED: one or more tests failed"
    exit 1
fi
echo "All tests passed!"
exit 0
