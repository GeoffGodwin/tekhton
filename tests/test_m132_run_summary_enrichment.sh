#!/usr/bin/env bash
# Test: M132 RUN_SUMMARY causal fidelity enrichment.
# Exercises finalize_summary_collectors.sh and the four enrichment fields
# emitted by _hook_emit_run_summary.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOG_DIR="$TEST_TMPDIR/logs"
PROJECT_DIR="$TEST_TMPDIR"
mkdir -p "$LOG_DIR"
mkdir -p "${PROJECT_DIR}/.claude"

# Globals expected by _hook_emit_run_summary
_ORCH_ATTEMPT=1
_ORCH_AGENT_CALLS=2
_ORCH_ELAPSED=60
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_REVIEW_BUMPED=false
AUTONOMOUS_TIMEOUT=7200
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
REVIEW_CYCLE=1
MILESTONE_CURRENT_SPLIT_DEPTH=0

HUMAN_MODE=false
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false
TASK="m132 test"

# Stage tracking arrays (M34)
declare -A _STAGE_TURNS=()
declare -A _STAGE_DURATION=()
declare -A _STAGE_BUDGET=()

export LOG_DIR PROJECT_DIR

# Stub logging
log()         { :; }
warn()        { :; }
error()       { :; }
success()     { :; }
header()      { :; }
log_verbose() { :; }

# Mock git
git() { return 1; }

# Provide a minimal _load_failure_cause_context that re-reads the override file.
# (Mirrors orchestrate_cause.sh's contract for this test fixture.)
_ORCH_PRIMARY_CAT=""
_ORCH_PRIMARY_SUB=""
_ORCH_PRIMARY_SIGNAL=""
_ORCH_SECONDARY_CAT=""
_ORCH_SECONDARY_SUB=""
_ORCH_SECONDARY_SIGNAL=""
_ORCH_SCHEMA_VERSION=0

_load_failure_cause_context() {
    _ORCH_PRIMARY_CAT=""
    _ORCH_PRIMARY_SUB=""
    _ORCH_PRIMARY_SIGNAL=""
    _ORCH_SECONDARY_CAT=""
    _ORCH_SECONDARY_SUB=""
    _ORCH_SECONDARY_SIGNAL=""
    _ORCH_SCHEMA_VERSION=0
    local ctx_file="${ORCH_CONTEXT_FILE_OVERRIDE:-${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json}"
    [[ -f "$ctx_file" ]] || return 0
    local schema
    schema=$(grep -oE '"schema_version"[[:space:]]*:[[:space:]]*[0-9]+' "$ctx_file" 2>/dev/null \
             | grep -oE '[0-9]+$' | head -1 || true)
    if [[ -z "$schema" ]]; then
        _ORCH_SCHEMA_VERSION=1
    else
        _ORCH_SCHEMA_VERSION="$schema"
    fi
    if [[ "$_ORCH_SCHEMA_VERSION" -ge 2 ]]; then
        local in_primary=0 in_secondary=0 line
        while IFS= read -r line; do
            if [[ "$line" == *'"primary_cause"'* ]]; then
                in_primary=1; in_secondary=0; continue
            fi
            if [[ "$line" == *'"secondary_cause"'* ]]; then
                in_secondary=1; in_primary=0; continue
            fi
            if [[ "$in_primary" -eq 1 ]]; then
                if [[ "$line" =~ \"category\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_PRIMARY_CAT="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ \"subcategory\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_PRIMARY_SUB="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ \"signal\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_PRIMARY_SIGNAL="${BASH_REMATCH[1]}"
                fi
                [[ "$line" == *'}'* ]] && in_primary=0
                continue
            fi
            if [[ "$in_secondary" -eq 1 ]]; then
                if [[ "$line" =~ \"category\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_SECONDARY_CAT="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ \"subcategory\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_SECONDARY_SUB="${BASH_REMATCH[1]}"
                elif [[ "$line" =~ \"signal\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
                    _ORCH_SECONDARY_SIGNAL="${BASH_REMATCH[1]}"
                fi
                [[ "$line" == *'}'* ]] && in_secondary=0
                continue
            fi
        done < "$ctx_file"
    else
        local sec_cat sec_sub
        sec_cat=$(sed -n 's/.*"category"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ctx_file" 2>/dev/null | head -1)
        sec_sub=$(sed -n 's/.*"subcategory"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$ctx_file" 2>/dev/null | head -1)
        _ORCH_SECONDARY_CAT="${sec_cat:-}"
        _ORCH_SECONDARY_SUB="${sec_sub:-}"
    fi
}

# Source under test
# shellcheck source=../lib/finalize_summary.sh
source "${TEKHTON_HOME}/lib/finalize_summary.sh"

# Helper — resets the cause vars + LAST_FAILURE_CONTEXT.json fixture.
reset_cause_state() {
    _ORCH_PRIMARY_CAT=""
    _ORCH_PRIMARY_SUB=""
    _ORCH_PRIMARY_SIGNAL=""
    _ORCH_SECONDARY_CAT=""
    _ORCH_SECONDARY_SUB=""
    _ORCH_SECONDARY_SIGNAL=""
    _ORCH_SCHEMA_VERSION=0
    rm -f "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json"
    unset ORCH_CONTEXT_FILE_OVERRIDE
}

write_v2_fixture() {
    cat > "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" <<'EOF'
{
  "schema_version": 2,
  "primary_cause": {
    "category": "ENVIRONMENT",
    "subcategory": "test_infra",
    "signal": "ui_timeout_interactive_report"
  },
  "secondary_cause": {
    "category": "AGENT_SCOPE",
    "subcategory": "max_turns",
    "signal": "build_fix_budget_exhausted"
  }
}
EOF
}

write_v1_fixture() {
    cat > "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" <<'EOF'
{
  "category": "ENVIRONMENT",
  "subcategory": "test_infra",
  "signal": "ui_timeout"
}
EOF
}

# =============================================================================
# T1 — _collect_causal_context_json with v2 fixture
# =============================================================================
echo "=== T1: _collect_causal_context_json (schema v2) ==="
reset_cause_state
write_v2_fixture
out=$(_collect_causal_context_json)
if [[ "$out" == *'"schema_version":2'* ]] \
   && [[ "$out" == *'"primary_category":"ENVIRONMENT"'* ]] \
   && [[ "$out" == *'"primary_subcategory":"test_infra"'* ]] \
   && [[ "$out" == *'"secondary_category":"AGENT_SCOPE"'* ]] \
   && [[ "$out" == *'"secondary_subcategory":"max_turns"'* ]]; then
    pass "v2 fixture produces populated primary + secondary fields"
else
    fail "v2 output missing expected fields: $out"
fi

# =============================================================================
# T2 — _collect_causal_context_json with v1 fixture
# =============================================================================
echo "=== T2: _collect_causal_context_json (schema v1) ==="
reset_cause_state
write_v1_fixture
out=$(_collect_causal_context_json)
if [[ "$out" == *'"schema_version":1'* ]] \
   && [[ "$out" == *'"primary_category":""'* ]] \
   && [[ "$out" == *'"primary_subcategory":""'* ]] \
   && [[ "$out" == *'"secondary_category":"ENVIRONMENT"'* ]] \
   && [[ "$out" == *'"secondary_subcategory":"test_infra"'* ]]; then
    pass "v1 fixture leaves primary empty, populates secondary from top-level"
else
    fail "v1 output unexpected: $out"
fi

# =============================================================================
# T3 — _collect_causal_context_json when file absent
# =============================================================================
echo "=== T3: _collect_causal_context_json (file absent) ==="
reset_cause_state
out=$(_collect_causal_context_json)
if [[ "$out" == '{"schema_version":0}' ]]; then
    pass "absent file returns sentinel {\"schema_version\":0}"
else
    fail "expected schema_version=0 sentinel, got: $out"
fi

# =============================================================================
# T4 — _collect_build_fix_stats_json with m128 vars set
# =============================================================================
echo "=== T4: _collect_build_fix_stats_json (m128 vars set) ==="
BUILD_FIX_ATTEMPTS=2
BUILD_FIX_OUTCOME=exhausted
BUILD_FIX_TURN_BUDGET_USED=40
BUILD_FIX_PROGRESS_GATE_FAILURES=1
BUILD_FIX_MAX_ATTEMPTS=3
out=$(_collect_build_fix_stats_json)
if [[ "$out" == *'"attempts":2'* ]] \
   && [[ "$out" == *'"outcome":"exhausted"'* ]] \
   && [[ "$out" == *'"enabled":true'* ]] \
   && [[ "$out" == *'"turn_budget_used":40'* ]] \
   && [[ "$out" == *'"progress_gate_failures":1'* ]]; then
    pass "m128 vars surface correctly"
else
    fail "m128 vars not reflected: $out"
fi
unset BUILD_FIX_ATTEMPTS BUILD_FIX_OUTCOME BUILD_FIX_TURN_BUDGET_USED \
      BUILD_FIX_PROGRESS_GATE_FAILURES BUILD_FIX_MAX_ATTEMPTS

# =============================================================================
# T5 — _collect_build_fix_stats_json without vars (pre-m128)
# =============================================================================
echo "=== T5: _collect_build_fix_stats_json (no vars) ==="
out=$(_collect_build_fix_stats_json)
if [[ "$out" == *'"attempts":0'* ]] \
   && [[ "$out" == *'"outcome":"not_run"'* ]] \
   && [[ "$out" == *'"enabled":false'* ]]; then
    pass "absent vars produce not_run/enabled=false"
else
    fail "not_run default missing: $out"
fi

# =============================================================================
# T6 — error_classes_encountered contains root: when primary != symptom
# =============================================================================
echo "=== T6: error_classes adds root: prefix on distinct primary ==="
AGENT_ERROR_CATEGORY=AGENT_SCOPE
AGENT_ERROR_SUBCATEGORY=max_turns
_ORCH_PRIMARY_CAT=ENVIRONMENT
_ORCH_PRIMARY_SUB=test_infra
out=$(_collect_error_classes_json)
if [[ "$out" == *'"AGENT_SCOPE/max_turns"'* ]] \
   && [[ "$out" == *'"root:ENVIRONMENT/test_infra"'* ]]; then
    pass "error_classes contains both symptom and root: prefix"
else
    fail "missing symptom or root prefix: $out"
fi

# =============================================================================
# T7 — no root: duplicate when primary matches symptom
# =============================================================================
echo "=== T7: error_classes does not duplicate when primary == symptom ==="
AGENT_ERROR_CATEGORY=ENVIRONMENT
AGENT_ERROR_SUBCATEGORY=test_infra
_ORCH_PRIMARY_CAT=ENVIRONMENT
_ORCH_PRIMARY_SUB=test_infra
out=$(_collect_error_classes_json)
# Should be exactly: ["ENVIRONMENT/test_infra"] — no root: entry
if [[ "$out" == '["ENVIRONMENT/test_infra"]' ]]; then
    pass "no root duplicate when symptom == primary"
else
    fail "expected exactly one entry, got: $out"
fi

# Reset for subsequent tests
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
_ORCH_PRIMARY_CAT=""
_ORCH_PRIMARY_SUB=""

# =============================================================================
# T8 — recovery_actions_taken includes route when non-default
# =============================================================================
echo "=== T8: recovery_actions includes m130 route when non-default ==="
_ORCH_RECOVERY_ROUTE_TAKEN=retry_ui_gate_env
_ORCH_REVIEW_BUMPED=false
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
out=$(_collect_recovery_actions_json)
if [[ "$out" == *'"retry_ui_gate_env"'* ]]; then
    pass "non-default route appended to recovery_actions"
else
    fail "route not appended: $out"
fi

# =============================================================================
# T9 — recovery_actions excludes save_exit (default)
# =============================================================================
echo "=== T9: recovery_actions excludes save_exit ==="
_ORCH_RECOVERY_ROUTE_TAKEN=save_exit
out=$(_collect_recovery_actions_json)
if [[ "$out" != *'save_exit'* ]]; then
    pass "save_exit not appended (no-op default)"
else
    fail "save_exit leaked into recovery_actions: $out"
fi
_ORCH_RECOVERY_ROUTE_TAKEN=""
out=$(_collect_recovery_actions_json)
if [[ "$out" != *'save_exit'* ]]; then
    pass "empty route also produces no save_exit entry"
else
    fail "empty route produced save_exit entry: $out"
fi

# =============================================================================
# T10 — Full RUN_SUMMARY.json emitted with all four new fields
# =============================================================================
echo "=== T10: full RUN_SUMMARY.json contains all four enrichment keys ==="
reset_cause_state
unset BUILD_FIX_ATTEMPTS BUILD_FIX_OUTCOME BUILD_FIX_MAX_ATTEMPTS \
      BUILD_FIX_TURN_BUDGET_USED BUILD_FIX_PROGRESS_GATE_FAILURES \
      PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
      PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE PREFLIGHT_UI_REPORTER_PATCHED \
      _PF_FAIL _PF_WARN
_ORCH_RECOVERY_ROUTE_TAKEN=""
_CURRENT_MILESTONE="m132-test"
_hook_emit_run_summary 0
json=$(cat "${LOG_DIR}/RUN_SUMMARY.json")

all_keys_present=true
for key in causal_context build_fix_stats recovery_routing preflight_ui; do
    if ! echo "$json" | grep -q "\"${key}\""; then
        fail "RUN_SUMMARY.json missing key: $key"
        all_keys_present=false
    fi
done
if [[ "$all_keys_present" = true ]]; then
    pass "all four M132 keys present in RUN_SUMMARY.json"
fi

# Empty-state assertions on success run (M134 S5.2 contract).
# Match without leading whitespace requirement — the nested objects are
# emitted compact by printf (no space after colon inside nested fragments).
if echo "$json" | grep -q '"causal_context":[[:space:]]*{"schema_version":0}'; then
    pass "causal_context.schema_version=0 on success (no LAST_FAILURE_CONTEXT.json)"
else
    fail "expected causal_context.schema_version=0 on success"
fi
if echo "$json" | grep -q '"outcome":"not_run"'; then
    pass "build_fix_stats.outcome=not_run on success"
else
    fail "expected build_fix_stats.outcome=not_run"
fi
if echo "$json" | grep -q '"route_taken":"save_exit"'; then
    pass "recovery_routing.route_taken=save_exit on success (default)"
else
    fail "expected recovery_routing.route_taken=save_exit"
fi
if echo "$json" | grep -q '"interactive_config_detected":false'; then
    pass "preflight_ui.interactive_config_detected=false on success"
else
    fail "expected preflight_ui.interactive_config_detected=false"
fi

# Validate JSON parses cleanly
if command -v python3 &>/dev/null; then
    if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "${LOG_DIR}/RUN_SUMMARY.json" 2>/dev/null; then
        pass "RUN_SUMMARY.json parses as valid JSON"
    else
        fail "RUN_SUMMARY.json is not valid JSON"
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
