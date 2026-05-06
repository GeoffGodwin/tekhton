#!/usr/bin/env bash
# shellcheck disable=SC2034
# =============================================================================
# test_orchestrate_classify.sh — M130 causal-context-aware recovery routing
#
# Covers _classify_failure routing decisions across primary/secondary cause
# combinations, the TEKHTON_UI_GATE_FORCE_NONINTERACTIVE opt-out, build-gate
# confidence routing (M127), and the cause_summary line in _print_recovery_block.
#
# All tests use ORCH_CONTEXT_FILE_OVERRIDE to point the loader at a fixture
# without needing to manipulate $PROJECT_DIR.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stub `warn` etc. before sourcing — orchestrate_classify.sh's transitive deps
# pull in nothing that needs them at load time, but be defensive.
warn() { :; }
log()  { :; }
error() { :; }

# shellcheck source=lib/orchestrate_classify.sh
source "${TEKHTON_HOME}/lib/orchestrate_classify.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — missing '$needle'"
        echo "  ----- captured output -----"
        printf '%s\n' "$haystack" | sed 's/^/    /'
        echo "  ----- end -----"
        FAIL=$((FAIL + 1))
    fi
}

# Reset all state vars before each test case so prior test residue cannot
# bleed into the current decision.
_reset_test_state() {
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    VERDICT=""
    BUILD_ERRORS_FILE="$TMPDIR/build_errors_absent.md"
    LAST_BUILD_CLASSIFICATION=""
    BUILD_FIX_CLASSIFICATION_REQUIRED=true
    _CONF_KEYS_SET=""
    TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=""
    _reset_orch_recovery_state
    _ORCH_PRIMARY_CAT=""
    _ORCH_PRIMARY_SUB=""
    _ORCH_PRIMARY_SIGNAL=""
    _ORCH_SECONDARY_CAT=""
    _ORCH_SECONDARY_SUB=""
    _ORCH_SECONDARY_SIGNAL=""
    _ORCH_SCHEMA_VERSION=0
    ORCH_CONTEXT_FILE_OVERRIDE=""
}

# Fixture writers
_write_v2_env_primary() {
    cat > "$TMPDIR/ctx_v2_env.json" << 'EOF'
{
  "schema_version": 2,
  "classification": "UI_INTERACTIVE_REPORTER",
  "stage": "coder",
  "outcome": "failure",
  "task": "M03",
  "consecutive_count": 1,
  "category": "AGENT_SCOPE",
  "subcategory": "max_turns",
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted",
    "source": "coder_build_fix"
  }
}
EOF
    ORCH_CONTEXT_FILE_OVERRIDE="$TMPDIR/ctx_v2_env.json"
}

_write_v1_legacy() {
    cat > "$TMPDIR/ctx_v1.json" << 'EOF'
{
  "classification": "DISK_FULL",
  "category": "ENVIRONMENT",
  "subcategory": "disk_full"
}
EOF
    ORCH_CONTEXT_FILE_OVERRIDE="$TMPDIR/ctx_v1.json"
}

_make_build_errors_present() {
    BUILD_ERRORS_FILE="$TMPDIR/build_errors_present.md"
    printf 'fake build errors here\n' > "$BUILD_ERRORS_FILE"
}

# ============================================================================
# T1: env/test_infra primary → retry_ui_gate_env
# ============================================================================
# Note: _classify_failure is invoked via `recovery=$(_classify_failure)` from
# the dispatcher (subshell). Tests assert routing decisions only — the
# persistent retry guards are written by the dispatcher case branches in
# orchestrate_iteration.sh, not by _classify_failure itself.
echo "=== T1: env/test_infra primary → retry_ui_gate_env ==="
_reset_test_state
_write_v2_env_primary
AGENT_ERROR_CATEGORY=ENVIRONMENT
AGENT_ERROR_SUBCATEGORY=test_infra
out=$(_classify_failure)
assert_eq "T1.1 routes retry_ui_gate_env" "retry_ui_gate_env" "$out"
# Verify loader populates v2 schema correctly (call directly to side-step
# the subshell isolation that hides mutations made via $(...)).
_load_failure_cause_context
assert_eq "T1.2 v2 schema_version=2 loaded" "2" "${_ORCH_SCHEMA_VERSION}"
assert_eq "T1.3 primary_cat populated" "ENVIRONMENT" "${_ORCH_PRIMARY_CAT}"

# ============================================================================
# T2: second env failure → save_exit (idempotency guard)
# ============================================================================
echo "=== T2: second env failure → save_exit ==="
_reset_test_state
_write_v2_env_primary
AGENT_ERROR_CATEGORY=ENVIRONMENT
AGENT_ERROR_SUBCATEGORY=test_infra
_ORCH_ENV_GATE_RETRIED=1
out=$(_classify_failure)
assert_eq "T2.1 second attempt routes save_exit" "save_exit" "$out"

# ============================================================================
# T2b: explicit pipeline.conf opt-out suppresses env retry
# ============================================================================
echo "=== T2b: TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0 → save_exit ==="
_reset_test_state
_write_v2_env_primary
AGENT_ERROR_CATEGORY=ENVIRONMENT
AGENT_ERROR_SUBCATEGORY=test_infra
_CONF_KEYS_SET=" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE "
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
out=$(_classify_failure)
assert_eq "T2b.1 explicit opt-out routes save_exit" "save_exit" "$out"
assert_eq "T2b.2 _ORCH_ENV_GATE_RETRIED untouched" "0" "${_ORCH_ENV_GATE_RETRIED}"

# ============================================================================
# T3: max_turns with env primary → retry_ui_gate_env (not split)
# ============================================================================
echo "=== T3: max_turns with env primary → retry_ui_gate_env ==="
_reset_test_state
_write_v2_env_primary
AGENT_ERROR_CATEGORY=AGENT_SCOPE
AGENT_ERROR_SUBCATEGORY=max_turns
out=$(_classify_failure)
assert_eq "T3.1 routes retry_ui_gate_env" "retry_ui_gate_env" "$out"

# ============================================================================
# T4: max_turns with env primary, already retried → split (fallback)
# ============================================================================
echo "=== T4: max_turns + env primary + already retried → split ==="
_reset_test_state
_write_v2_env_primary
AGENT_ERROR_CATEGORY=AGENT_SCOPE
AGENT_ERROR_SUBCATEGORY=max_turns
_ORCH_ENV_GATE_RETRIED=1
out=$(_classify_failure)
assert_eq "T4.1 falls through to split" "split" "$out"

# ============================================================================
# T5: build gate code_dominant → retry_coder_build
# ============================================================================
echo "=== T5: build code_dominant → retry_coder_build ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=code_dominant
out=$(_classify_failure)
assert_eq "T5.1 routes retry_coder_build" "retry_coder_build" "$out"

# ============================================================================
# T6: build gate noncode_dominant → save_exit
# ============================================================================
echo "=== T6: build noncode_dominant → save_exit ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=noncode_dominant
out=$(_classify_failure)
assert_eq "T6.1 routes save_exit" "save_exit" "$out"

# ============================================================================
# T7: build gate mixed_uncertain, first attempt → retry_coder_build
# ============================================================================
echo "=== T7: build mixed_uncertain (first attempt) → retry_coder_build ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=mixed_uncertain
out=$(_classify_failure)
assert_eq "T7.1 first attempt routes retry_coder_build" "retry_coder_build" "$out"

# ============================================================================
# T8: build gate mixed_uncertain, already retried → save_exit
# ============================================================================
echo "=== T8: build mixed_uncertain (already retried) → save_exit ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=mixed_uncertain
_ORCH_MIXED_BUILD_RETRIED=1
out=$(_classify_failure)
assert_eq "T8.1 second attempt routes save_exit" "save_exit" "$out"

# ============================================================================
# T8b: build gate unknown_only → retry_coder_build (treated as code)
# ============================================================================
echo "=== T8b: build unknown_only → retry_coder_build ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=unknown_only
out=$(_classify_failure)
assert_eq "T8b.1 unknown_only routes retry_coder_build" "retry_coder_build" "$out"

# ============================================================================
# T8c: kill switch BUILD_FIX_CLASSIFICATION_REQUIRED=false → always retry
# ============================================================================
echo "=== T8c: kill switch reverts to pre-M130 retry ==="
_reset_test_state
_make_build_errors_present
LAST_BUILD_CLASSIFICATION=noncode_dominant
BUILD_FIX_CLASSIFICATION_REQUIRED=false
out=$(_classify_failure)
assert_eq "T8c.1 kill switch forces retry_coder_build" "retry_coder_build" "$out"

# ============================================================================
# T9: v1 schema compat — flat ENVIRONMENT still routes save_exit
# ============================================================================
echo "=== T9: v1 schema ENVIRONMENT/disk_full → save_exit ==="
_reset_test_state
_write_v1_legacy
AGENT_ERROR_CATEGORY=ENVIRONMENT
AGENT_ERROR_SUBCATEGORY=disk_full
out=$(_classify_failure)
assert_eq "T9.1 v1 ENVIRONMENT routes save_exit" "save_exit" "$out"
# Direct loader call (no subshell) so the schema_version mutation is visible.
_load_failure_cause_context
assert_eq "T9.2 v1 schema_version detected" "1" "${_ORCH_SCHEMA_VERSION}"
assert_eq "T9.3 v1 secondary_cat populated from top-level" "ENVIRONMENT" "${_ORCH_SECONDARY_CAT}"
assert_eq "T9.4 v1 primary_cat empty (only secondary populated)" "" "${_ORCH_PRIMARY_CAT}"

# ============================================================================
# T10: no failure context file — original decision tree unchanged
# ============================================================================
echo "=== T10: no context file, UPSTREAM error → save_exit ==="
_reset_test_state
ORCH_CONTEXT_FILE_OVERRIDE="$TMPDIR/never_exists.json"
AGENT_ERROR_CATEGORY=UPSTREAM
out=$(_classify_failure)
assert_eq "T10.1 UPSTREAM falls through to save_exit" "save_exit" "$out"
# Direct loader call to verify file-absent handling
_load_failure_cause_context
assert_eq "T10.2 schema_version=0 (file absent)" "0" "${_ORCH_SCHEMA_VERSION}"
assert_eq "T10.3 primary_cat empty" "" "${_ORCH_PRIMARY_CAT}"
assert_eq "T10.4 secondary_cat empty" "" "${_ORCH_SECONDARY_CAT}"

# ============================================================================
# T11: cause_summary in recovery block
# ============================================================================
echo "=== T11: _print_recovery_block prints Root cause line ==="
_reset_test_state
output=$(_print_recovery_block \
    "max_attempts" \
    "Pipeline hit 5 consecutive failing attempts." \
    'tekhton --complete --milestone --start-at test "M130"' \
    "M130" \
    "ENVIRONMENT/test_infra (ui_timeout_interactive_report)" 2>&1)
assert_contains "T11.1 Root cause line emitted" "Root cause: ENVIRONMENT/test_infra" "$output"
assert_contains "T11.2 signal included" "ui_timeout_interactive_report" "$output"

# Negative case: no 5th arg = no Root cause line
output=$(_print_recovery_block \
    "max_attempts" "" 'tekhton --complete "M130"' "M130" 2>&1)
if printf '%s' "$output" | grep -qF "Root cause:"; then
    echo "  FAIL: T11.3 missing 5th arg should suppress Root cause line"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: T11.3 missing 5th arg suppresses Root cause line"
    PASS=$((PASS + 1))
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "════════════════════════════════════════"
echo "  M130 recovery-routing tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All M130 recovery-routing tests passed"
