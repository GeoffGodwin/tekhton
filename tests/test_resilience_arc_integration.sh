#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_resilience_arc_integration.sh — M134 cross-cutting regression harness
#
# Exercises the full resilience arc (m126–m133) end-to-end with controlled
# fixtures: preflight scan → gate env normalization → timeout signature →
# log classification → build-fix loop → failure-context write → recovery
# routing → RUN_SUMMARY enrichment → --diagnose classification.
#
# Each scenario has its own fresh PROJECT_DIR sub-directory so cross-scenario
# contamination is impossible. Per-scenario state is reset via the helpers in
# tests/resilience_arc_fixtures.sh. Unimplemented arc functions short-circuit
# to SKIP rather than FAIL so this file can land before its dependencies do.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

TMPDIR_TOP=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TOP"' EXIT
export TMPDIR_TOP

# Disable any inherited TUI state so log() reaches stdout.
unset _TUI_ACTIVE 2>/dev/null || true

# m135: clear any inherited PROJECT_DIR / PREFLIGHT_BAK_DIR so artifact_defaults.sh
# (sourced via common.sh below) does not bake a parent-shell value into
# PREFLIGHT_BAK_DIR. Each scenario sets its own PROJECT_DIR; m131 resolves
# the bak dir via its `${PREFLIGHT_BAK_DIR:-${proj}/.claude/preflight_bak}` fallback.
unset PROJECT_DIR PREFLIGHT_BAK_DIR 2>/dev/null || true

# Default artifact paths used by the arc modules. Tests set PROJECT_DIR per
# scenario and the modules resolve these relative to it.
export BUILD_RAW_ERRORS_FILE="${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
export BUILD_ERRORS_FILE="${BUILD_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_ERRORS.md}"
export BUILD_FIX_REPORT_FILE="${BUILD_FIX_REPORT_FILE:-${TEKHTON_DIR}/BUILD_FIX_REPORT.md}"
export BUILD_ROUTING_DIAGNOSIS_FILE="${BUILD_ROUTING_DIAGNOSIS_FILE:-${TEKHTON_DIR}/BUILD_ROUTING_DIAGNOSIS.md}"
export UI_TEST_ERRORS_FILE="${UI_TEST_ERRORS_FILE:-${TEKHTON_DIR}/UI_TEST_ERRORS.md}"
export REVIEWER_REPORT_FILE="${REVIEWER_REPORT_FILE:-${TEKHTON_DIR}/REVIEWER_REPORT.md}"
export SECURITY_REPORT_FILE="${SECURITY_REPORT_FILE:-${TEKHTON_DIR}/SECURITY_REPORT.md}"
export CLARIFICATIONS_FILE="${CLARIFICATIONS_FILE:-${TEKHTON_DIR}/CLARIFICATIONS.md}"
export TEST_AUDIT_REPORT_FILE="${TEST_AUDIT_REPORT_FILE:-${TEKHTON_DIR}/TEST_AUDIT_REPORT.md}"

# --- Source common.sh + arc modules with a SKIP guard for milestone-pending ---
# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"

PASS=0
FAIL=0
SKIP=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then pass "$desc"; else fail "$desc — expected '$expected', got '$actual'"; fi
}
assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then pass "$desc"; else fail "$desc — '$needle' not in '$haystack'"; fi
}

# _arc_source LIB_FILE — source a lib file when present, skip with note when not.
_arc_source() {
    local rel="$1"
    local f="${TEKHTON_HOME}/${rel}"
    if [[ -f "$f" ]]; then
        # shellcheck disable=SC1090
        source "$f"
    else
        echo "  SKIP (not yet implemented): ${rel}"
    fi
}

_arc_source "lib/state.sh"
_arc_source "lib/preflight.sh"
_arc_source "lib/preflight_checks_ui.sh"
_arc_source "lib/error_patterns.sh"
_arc_source "lib/gates_ui_helpers.sh"
_arc_source "lib/failure_context.sh"
_arc_source "lib/orchestrate_cause.sh"
_arc_source "lib/orchestrate_diagnose.sh"
_arc_source "lib/orchestrate_classify.sh"
_arc_source "lib/finalize_summary_collectors.sh"
_arc_source "lib/finalize_summary.sh"
_arc_source "lib/diagnose.sh"

# Fixture helpers (must be sourced after PROJECT_DIR scaffold helpers above).
# shellcheck source=tests/resilience_arc_fixtures.sh
source "${TEKHTON_HOME}/tests/resilience_arc_fixtures.sh"

# Globals required by _hook_emit_run_summary (S5.x). Mirror test_m132.
# Exported so shellcheck recognizes them as consumed by sourced libs.
declare -A _STAGE_TURNS=() _STAGE_DURATION=() _STAGE_BUDGET=()
export _ORCH_ATTEMPT=1
export _ORCH_AGENT_CALLS=2
export _ORCH_ELAPSED=60
export _ORCH_NO_PROGRESS_COUNT=0
export _ORCH_REVIEW_BUMPED=false
export AUTONOMOUS_TIMEOUT=7200
export CONTINUATION_ATTEMPTS=0
export LAST_AGENT_RETRY_COUNT=0
export REVIEW_CYCLE=1
export MILESTONE_CURRENT_SPLIT_DEPTH=0
export HUMAN_MODE=false
export HUMAN_NOTES_TAG=""
export FIX_DRIFT_MODE=false
export FIX_NONBLOCKERS_MODE=false
export TASK="m134-arc-integration"
export _CURRENT_MILESTONE="m134"

# Stub `git` so finalize_summary has a deterministic empty file list.
git() { return 1; }

# =============================================================================
# Scenario group 1 — Preflight → Gate first-run determinism (m131 + m126)
# =============================================================================
echo "=== S1.1: Preflight detects html reporter; gate env hardens (auto-fix off) ==="
if declare -f _preflight_check_ui_test_config &>/dev/null \
   && declare -f _ui_deterministic_env_list &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_preflight_state
    export UI_TEST_CMD="npx playwright test"
    _arc_write_playwright_html "$PROJECT_DIR"
    PREFLIGHT_UI_CONFIG_AUTO_FIX=false _preflight_check_ui_test_config
    assert_eq "S1.1 DETECTED=1" "1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
    assert_eq "S1.1 PATCHED=0 (auto-fix off)" "0" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
    env_list=$(_ui_deterministic_env_list)
    assert_contains "S1.1 env list has PLAYWRIGHT_HTML_OPEN=never" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
    assert_contains "S1.1 env list escalated to CI=1 by preflight signal" "CI=1" "$env_list"
else
    skip "S1.1 — preflight or gate helpers not yet implemented"
fi

echo "=== S1.2: Auto-patch html reporter; backup written ==="
if declare -f _preflight_check_ui_test_config &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_preflight_state
    export UI_TEST_CMD="npx playwright test"
    _arc_write_playwright_html "$PROJECT_DIR"
    PREFLIGHT_UI_CONFIG_AUTO_FIX=true _preflight_check_ui_test_config
    assert_eq "S1.2 PATCHED=1" "1" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"
    if grep -q "process.env.CI ? 'dot' : 'html'" "$PROJECT_DIR/playwright.config.ts"; then
        pass "S1.2 source rewritten to CI-guarded form"
    else
        fail "S1.2 source not rewritten"
    fi
    bak=$(find "$PROJECT_DIR/.claude/preflight_bak" -maxdepth 1 -type f -name '*_playwright.config.ts' 2>/dev/null | head -1 || true)
    if [[ -n "$bak" ]]; then pass "S1.2 backup created"; else fail "S1.2 backup missing"; fi
else
    skip "S1.2 — preflight not yet implemented"
fi

echo "=== S1.3: No playwright.config; framework still detected from UI_TEST_CMD ==="
if declare -f _preflight_check_ui_test_config &>/dev/null \
   && declare -f _ui_deterministic_env_list &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_preflight_state
    export UI_TEST_CMD="npx playwright test"
    _preflight_check_ui_test_config
    assert_eq "S1.3 no preflight detection" "" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
    env_list=$(_ui_deterministic_env_list)
    assert_contains "S1.3 PLAYWRIGHT_HTML_OPEN=never still injected" \
        "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
    if [[ "$env_list" == *"CI=1"* ]]; then
        fail "S1.3 unexpected CI=1 escalation without preflight signal"
    else
        pass "S1.3 no CI=1 escalation without preflight signal"
    fi
else
    skip "S1.3 — preflight or gate helpers not yet implemented"
fi

# =============================================================================
# Scenario group 2 — Gate timeout → interactive signature detection (m126)
# =============================================================================
echo "=== S2.1: timeout with interactive reporter output → interactive_report ==="
if declare -f _ui_timeout_signature &>/dev/null; then
    sig=$(_ui_timeout_signature 124 "Running 3 tests...
Serving HTML report at http://localhost:9323. Press Ctrl+C to quit.")
    assert_eq "S2.1 signature=interactive_report" "interactive_report" "$sig"
else
    skip "S2.1 — _ui_timeout_signature not yet implemented"
fi

echo "=== S2.2: timeout without interactive output → generic_timeout ==="
if declare -f _ui_timeout_signature &>/dev/null; then
    sig=$(_ui_timeout_signature 124 "Test runner died after 60s")
    assert_eq "S2.2 signature=generic_timeout" "generic_timeout" "$sig"
    sig=$(_ui_timeout_signature 0 "")
    assert_eq "S2.2 exit 0 → none" "none" "$sig"
else
    skip "S2.2 — _ui_timeout_signature not yet implemented"
fi

# =============================================================================
# Scenario group 3 — Log classification → build-fix routing (m127 + m128)
# =============================================================================
echo "=== S3.1: code_dominant TS errors → loop runs to MAX_ATTEMPTS ==="
if declare -f classify_routing_decision &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    raw="src/app/page.tsx(12,5): error TS2304: Cannot find name 'undefined'.
src/lib/db.ts(8,3): error TS2339: Property 'query' does not exist."
    classify_routing_decision "$raw" >/dev/null
    assert_eq "S3.1 LAST_BUILD_CLASSIFICATION=code_dominant" \
        "code_dominant" "${LAST_BUILD_CLASSIFICATION:-}"
else
    skip "S3.1 — classify_routing_decision not yet implemented"
fi

echo "=== S3.2: noncode_dominant env errors → routing token only ==="
if declare -f classify_routing_decision &>/dev/null; then
    _arc_reset_orch_state
    raw="Error: connect ECONNREFUSED 127.0.0.1:3000
Error: connect ECONNREFUSED 127.0.0.1:6379
Cannot find module 'express'"
    classify_routing_decision "$raw" >/dev/null
    assert_eq "S3.2 LAST_BUILD_CLASSIFICATION=noncode_dominant" \
        "noncode_dominant" "${LAST_BUILD_CLASSIFICATION:-}"
else
    skip "S3.2 — classify_routing_decision not yet implemented"
fi

echo "=== S3.3: mixed_uncertain → first retry allowed, second → save_exit ==="
if declare -f classify_routing_decision &>/dev/null \
   && declare -f _classify_failure &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    raw="error TS2304: Cannot find name 'foo'
ECONNREFUSED 127.0.0.1:5432
ECONNREFUSED 127.0.0.1:6379"
    classify_routing_decision "$raw" >/dev/null
    assert_eq "S3.3 LAST_BUILD_CLASSIFICATION=mixed_uncertain" \
        "mixed_uncertain" "${LAST_BUILD_CLASSIFICATION:-}"

    BUILD_ERRORS_FILE_ABS="${PROJECT_DIR}/${BUILD_ERRORS_FILE}"
    mkdir -p "$(dirname "$BUILD_ERRORS_FILE_ABS")"
    echo "errors present" > "$BUILD_ERRORS_FILE_ABS"
    export BUILD_ERRORS_FILE="$BUILD_ERRORS_FILE_ABS"
    export _ORCH_MIXED_BUILD_RETRIED=1
    export AGENT_ERROR_CATEGORY=""
    export AGENT_ERROR_SUBCATEGORY=""
    export VERDICT=""
    decision=$(_classify_failure)
    assert_eq "S3.3 second mixed retry → save_exit" "save_exit" "$decision"
    unset BUILD_ERRORS_FILE
    export BUILD_ERRORS_FILE="${TEKHTON_DIR}/BUILD_ERRORS.md"
else
    skip "S3.3 — classify_routing_decision or _classify_failure not yet implemented"
fi

# =============================================================================
# Scenario group 4 — Failure context write → recovery routing (m129 + m130)
# =============================================================================
echo "=== S4.1: ENVIRONMENT/test_infra primary → retry_ui_gate_env ==="
if declare -f write_last_failure_context &>/dev/null \
   && declare -f _classify_failure &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    set_primary_cause "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" "build_gate"
    AGENT_ERROR_CATEGORY="ENVIRONMENT"
    AGENT_ERROR_SUBCATEGORY="test_infra"
    write_last_failure_context "UI_INTERACTIVE_REPORTER" "coder" "failure"
    if [[ -f "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" ]]; then
        pass "S4.1 LAST_FAILURE_CONTEXT.json written"
    else
        fail "S4.1 LAST_FAILURE_CONTEXT.json missing"
    fi
    schema=$(grep -oE '"schema_version"[[:space:]]*:[[:space:]]*[0-9]+' \
        "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" | grep -oE '[0-9]+$' || true)
    assert_eq "S4.1 schema_version=2" "2" "${schema:-}"
    _load_failure_cause_context
    assert_eq "S4.1 _ORCH_PRIMARY_CAT=ENVIRONMENT" "ENVIRONMENT" "${_ORCH_PRIMARY_CAT:-}"
    decision=$(_classify_failure)
    assert_eq "S4.1 _classify_failure=retry_ui_gate_env" "retry_ui_gate_env" "$decision"
else
    skip "S4.1 — failure-context writer or classifier not yet implemented"
fi

echo "=== S4.2: AGENT_SCOPE/max_turns w/ ENVIRONMENT primary → retry_ui_gate_env ==="
if declare -f _classify_failure &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    _arc_write_v2_failure_context "$PROJECT_DIR" \
        "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" \
        "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted"
    AGENT_ERROR_CATEGORY="AGENT_SCOPE"
    AGENT_ERROR_SUBCATEGORY="max_turns"
    _load_failure_cause_context
    decision=$(_classify_failure)
    assert_eq "S4.2 max_turns symptom + env primary → retry_ui_gate_env" \
        "retry_ui_gate_env" "$decision"
else
    skip "S4.2 — _classify_failure not yet implemented"
fi

echo "=== S4.3: second env failure → save_exit (loop guard) ==="
if declare -f _classify_failure &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    _arc_write_v2_failure_context "$PROJECT_DIR" \
        "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" \
        "" "" ""
    AGENT_ERROR_CATEGORY="ENVIRONMENT"
    AGENT_ERROR_SUBCATEGORY="test_infra"
    _load_failure_cause_context
    _ORCH_ENV_GATE_RETRIED=1
    decision=$(_classify_failure)
    assert_eq "S4.3 already-retried env → save_exit" "save_exit" "$decision"
else
    skip "S4.3 — _classify_failure not yet implemented"
fi

echo "=== S4.4: v1 schema + flat ENVIRONMENT → save_exit (legacy compat) ==="
if declare -f _classify_failure &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    _arc_write_v1_failure_context "$PROJECT_DIR" "ENVIRONMENT" "ENVIRONMENT" "disk_full"
    AGENT_ERROR_CATEGORY="ENVIRONMENT"
    AGENT_ERROR_SUBCATEGORY="disk_full"
    _load_failure_cause_context
    assert_eq "S4.4 v1 schema → no _ORCH_PRIMARY_CAT" "" "${_ORCH_PRIMARY_CAT:-}"
    decision=$(_classify_failure)
    assert_eq "S4.4 v1 ENVIRONMENT → save_exit" "save_exit" "$decision"
else
    skip "S4.4 — _classify_failure not yet implemented"
fi

# =============================================================================
# Scenario group 5 — RUN_SUMMARY enrichment (m132)
# =============================================================================
echo "=== S5.1: failure run RUN_SUMMARY has all four enrichment keys ==="
if declare -f _hook_emit_run_summary &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    LOG_DIR="${PROJECT_DIR}/.claude/logs"
    export LOG_DIR
    _arc_reset_orch_state
    # Reuse the bifl-tracker M03 fixture so this scenario's v2 cause shape stays
    # in lockstep with S6.1 (golden path). Satisfies the M134 acceptance
    # criterion that the fixture be used by at least two scenarios.
    _setup_bifl_tracker_m03_fixture "$PROJECT_DIR"
    export BUILD_FIX_ATTEMPTS=2
    export BUILD_FIX_OUTCOME=exhausted
    export BUILD_FIX_TURN_BUDGET_USED=40
    export BUILD_FIX_PROGRESS_GATE_FAILURES=1
    export BUILD_FIX_MAX_ATTEMPTS=3
    export _ORCH_PRIMARY_CAT=ENVIRONMENT
    export _ORCH_PRIMARY_SUB=test_infra
    export _ORCH_RECOVERY_ROUTE_TAKEN=retry_ui_gate_env
    export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
    export PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE=PW-1
    export AGENT_ERROR_CATEGORY=AGENT_SCOPE
    export AGENT_ERROR_SUBCATEGORY=max_turns
    _hook_emit_run_summary 1 >/dev/null 2>&1
    json=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
    for key in causal_context build_fix_stats recovery_routing preflight_ui; do
        if echo "$json" | grep -q "\"${key}\""; then
            pass "S5.1 RUN_SUMMARY contains ${key}"
        else
            fail "S5.1 RUN_SUMMARY missing ${key}"
        fi
    done
    assert_contains "S5.1 primary_category=ENVIRONMENT" \
        '"primary_category":"ENVIRONMENT"' "$json"
    assert_contains "S5.1 build_fix_stats.outcome=exhausted" \
        '"outcome":"exhausted"' "$json"
    assert_contains "S5.1 recovery_routing.route_taken=retry_ui_gate_env" \
        '"route_taken":"retry_ui_gate_env"' "$json"
    assert_contains "S5.1 preflight_ui.interactive_config_detected=true" \
        '"interactive_config_detected":true' "$json"
    assert_contains "S5.1 error_classes contains root prefix" \
        '"root:ENVIRONMENT/test_infra"' "$json"
    assert_contains "S5.1 recovery_actions contains route" \
        '"retry_ui_gate_env"' "$json"
    unset BUILD_FIX_ATTEMPTS BUILD_FIX_OUTCOME BUILD_FIX_TURN_BUDGET_USED \
          BUILD_FIX_PROGRESS_GATE_FAILURES BUILD_FIX_MAX_ATTEMPTS \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE
else
    skip "S5.1 — _hook_emit_run_summary not yet implemented"
fi

echo "=== S5.2: success run RUN_SUMMARY emits empty-state defaults ==="
if declare -f _hook_emit_run_summary &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    LOG_DIR="${PROJECT_DIR}/.claude/logs"
    export LOG_DIR
    _arc_reset_orch_state
    _hook_emit_run_summary 0 >/dev/null 2>&1
    json=$(cat "${LOG_DIR}/RUN_SUMMARY.json")
    assert_contains "S5.2 causal_context.schema_version=0" \
        '"causal_context":' "$json"
    if echo "$json" | grep -q '"schema_version":0'; then
        pass "S5.2 schema_version=0 present"
    else
        fail "S5.2 schema_version=0 missing"
    fi
    assert_contains "S5.2 build_fix_stats.outcome=not_run" \
        '"outcome":"not_run"' "$json"
    assert_contains "S5.2 recovery_routing.route_taken=save_exit (default)" \
        '"route_taken":"save_exit"' "$json"
    assert_contains "S5.2 preflight_ui.interactive_config_detected=false" \
        '"interactive_config_detected":false' "$json"
    if command -v python3 >/dev/null 2>&1; then
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" \
           "${LOG_DIR}/RUN_SUMMARY.json" 2>/dev/null; then
            pass "S5.2 RUN_SUMMARY parses as valid JSON"
        else
            fail "S5.2 RUN_SUMMARY is not valid JSON"
        fi
    fi
else
    skip "S5.2 — _hook_emit_run_summary not yet implemented"
fi

# =============================================================================
# Scenario group 6 — --diagnose end-to-end classification (m133)
# =============================================================================
echo "=== S6.1: bifl-tracker M03 golden path → UI_GATE_INTERACTIVE_REPORTER ==="
if declare -f classify_failure_diag &>/dev/null \
   && declare -f _read_diagnostic_context &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    _setup_bifl_tracker_m03_fixture "$PROJECT_DIR"
    PIPELINE_STATE_FILE="${PROJECT_DIR}/.claude/PIPELINE_STATE.md"
    export PIPELINE_STATE_FILE
    DIAG_CLASSIFICATION=""
    DIAG_CONFIDENCE=""
    DIAG_SUGGESTIONS=()
    _read_diagnostic_context
    classify_failure_diag
    assert_eq "S6.1 classification" "UI_GATE_INTERACTIVE_REPORTER" "$DIAG_CLASSIFICATION"
    assert_eq "S6.1 confidence=high" "high" "$DIAG_CONFIDENCE"
    sug_text="${DIAG_SUGGESTIONS[*]}"
    assert_contains "S6.1 suggests reporter: 'html'" "reporter: 'html'" "$sug_text"
    assert_contains "S6.1 suggests CI-guarded form" \
        "process.env.CI ? 'dot' : 'html'" "$sug_text"
    if [[ "$sug_text" == *"CODER_MAX_TURNS"* ]]; then
        fail "S6.1 wrong advice present (CODER_MAX_TURNS)"
    else
        pass "S6.1 wrong CODER_MAX_TURNS advice suppressed"
    fi
    if [[ "$sug_text" == *"Split the milestone"* ]]; then
        fail "S6.1 wrong advice present (Split the milestone)"
    else
        pass "S6.1 wrong split-milestone advice suppressed"
    fi
else
    skip "S6.1 — classify_failure_diag not yet implemented"
fi

echo "=== S6.2: build-fix exhausted → BUILD_FIX_EXHAUSTED ==="
if declare -f classify_failure_diag &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    PIPELINE_STATE_FILE="${PROJECT_DIR}/.claude/PIPELINE_STATE.md"
    export PIPELINE_STATE_FILE
    rm -f "$PIPELINE_STATE_FILE" "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json"
    report_path="${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}"
    raw_path="${PROJECT_DIR}/${BUILD_RAW_ERRORS_FILE}"
    mkdir -p "$(dirname "$report_path")" "$(dirname "$raw_path")"
    cat > "$report_path" <<'EOF'
## Attempt 1
- Progress signal: improved
## Attempt 2
- Progress signal: improved
## Attempt 3
- Progress signal: unchanged
EOF
    echo "src/foo.ts(1,1): error TS2304: x" > "$raw_path"
    DIAG_CLASSIFICATION=""
    DIAG_SUGGESTIONS=()
    _read_diagnostic_context
    classify_failure_diag
    assert_eq "S6.2 classification=BUILD_FIX_EXHAUSTED" \
        "BUILD_FIX_EXHAUSTED" "$DIAG_CLASSIFICATION"
    sug_text="${DIAG_SUGGESTIONS[*]}"
    assert_contains "S6.2 suggests BUILD_FIX_MAX_ATTEMPTS knob" \
        "BUILD_FIX_MAX_ATTEMPTS" "$sug_text"
else
    skip "S6.2 — classify_failure_diag not yet implemented"
fi

echo "=== S6.3: max_turns w/ env primary → MAX_TURNS_ENV_ROOT ==="
if declare -f classify_failure_diag &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    PIPELINE_STATE_FILE="${PROJECT_DIR}/.claude/PIPELINE_STATE.md"
    export PIPELINE_STATE_FILE
    # Use a non-interactive-reporter signal so the higher-priority
    # _rule_ui_gate_interactive_reporter does not preempt. Per milestone S6.3:
    # "no ${BUILD_FIX_REPORT_FILE}, no interactive reporter log evidence".
    _arc_write_v2_failure_context "$PROJECT_DIR" \
        "ENVIRONMENT" "test_infra" "test_env_misconfigured" \
        "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted"
    cat > "$PIPELINE_STATE_FILE" <<'EOF'
## Exit Stage
coder
## Exit Reason
complete_loop_max_attempts
## Task
arc-S6.3
EOF
    DIAG_CLASSIFICATION=""
    DIAG_SUGGESTIONS=()
    _read_diagnostic_context
    classify_failure_diag
    assert_eq "S6.3 classification=MAX_TURNS_ENV_ROOT" \
        "MAX_TURNS_ENV_ROOT" "$DIAG_CLASSIFICATION"
    sug_text="${DIAG_SUGGESTIONS[*]}"
    assert_contains "S6.3 mentions Primary cause" "Primary cause" "$sug_text"
    if [[ "$sug_text" == *"CODER_MAX_TURNS="* ]]; then
        fail "S6.3 wrong advice present (CODER_MAX_TURNS=)"
    else
        pass "S6.3 CODER_MAX_TURNS= advice correctly suppressed"
    fi
else
    skip "S6.3 — classify_failure_diag not yet implemented"
fi

echo "=== S6.4: v1 schema max_turns → MAX_TURNS_EXHAUSTED (legacy preserved) ==="
if declare -f classify_failure_diag &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_orch_state
    PIPELINE_STATE_FILE="${PROJECT_DIR}/.claude/PIPELINE_STATE.md"
    export PIPELINE_STATE_FILE
    _arc_write_v1_failure_context "$PROJECT_DIR" \
        "MAX_TURNS_EXHAUSTED" "AGENT_SCOPE" "max_turns"
    cat > "$PIPELINE_STATE_FILE" <<'EOF'
## Exit Stage
coder
## Exit Reason
complete_loop_max_attempts
## Task
arc-S6.4
EOF
    DIAG_CLASSIFICATION=""
    DIAG_SUGGESTIONS=()
    _read_diagnostic_context
    classify_failure_diag
    assert_eq "S6.4 classification=MAX_TURNS_EXHAUSTED" \
        "MAX_TURNS_EXHAUSTED" "$DIAG_CLASSIFICATION"
    sug_text="${DIAG_SUGGESTIONS[*]}"
    assert_contains "S6.4 mentions CODER_MAX_TURNS knob" \
        "CODER_MAX_TURNS" "$sug_text"
else
    skip "S6.4 — classify_failure_diag not yet implemented"
fi

# =============================================================================
# Scenario group 7 — State reset between iterations (no cross-contamination)
# =============================================================================
echo "=== S7.1: _reset_orch_recovery_state zeroes persistent retry guards only ==="
if declare -f _reset_orch_recovery_state &>/dev/null; then
    _ORCH_ENV_GATE_RETRIED=1
    _ORCH_MIXED_BUILD_RETRIED=1
    _ORCH_RECOVERY_ROUTE_TAKEN=retry_ui_gate_env
    _ORCH_PRIMARY_CAT=ENVIRONMENT
    _ORCH_PRIMARY_SUB=test_infra
    _ORCH_SCHEMA_VERSION=2
    _reset_orch_recovery_state
    assert_eq "S7.1 _ORCH_ENV_GATE_RETRIED=0" "0" "${_ORCH_ENV_GATE_RETRIED:-}"
    assert_eq "S7.1 _ORCH_MIXED_BUILD_RETRIED=0" "0" "${_ORCH_MIXED_BUILD_RETRIED:-}"
    assert_eq "S7.1 _ORCH_RECOVERY_ROUTE_TAKEN=''" "" "${_ORCH_RECOVERY_ROUTE_TAKEN:-}"
    assert_eq "S7.1 _ORCH_PRIMARY_CAT preserved (loader-owned)" \
        "ENVIRONMENT" "${_ORCH_PRIMARY_CAT:-}"
    assert_eq "S7.1 _ORCH_SCHEMA_VERSION preserved (loader-owned)" \
        "2" "${_ORCH_SCHEMA_VERSION:-}"
else
    skip "S7.1 — _reset_orch_recovery_state not yet implemented"
fi

echo "=== S7.2: PREFLIGHT_UI_* persists within run; resets at preflight start ==="
if declare -f _preflight_check_ui_test_config &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_preflight_state
    PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
    PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE=PW-1
    export PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE
    # Iteration boundary — these vars must NOT be touched mid-run.
    assert_eq "S7.2 DETECTED persists across iteration" \
        "1" "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}"
    # New-run boundary — preflight resets the contract block before scanning.
    export UI_TEST_CMD="npx playwright test"
    _preflight_check_ui_test_config
    # No playwright config in this dir → preflight emits no PW-1 detection,
    # so the contract var must be cleared (or remain 0).
    if [[ -z "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}" ]] \
       || [[ "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}" == "0" ]]; then
        pass "S7.2 preflight reset DETECTED at new-run boundary"
    else
        fail "S7.2 preflight did not reset DETECTED (got '${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED}')"
    fi
else
    skip "S7.2 — _preflight_check_ui_test_config not yet implemented"
fi

# =============================================================================
# Scenario group 8 — Artifact lifecycle (m135)
# =============================================================================
_arc_source "lib/preflight_checks.sh"

echo "=== S8.T3: success run → LAST_FAILURE_CONTEXT.json removed ==="
if declare -f _hook_emit_run_summary &>/dev/null \
   && declare -f _clear_arc_artifacts_on_success &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    LOG_DIR="${PROJECT_DIR}/.claude/logs"
    export LOG_DIR
    _arc_reset_orch_state
    _arc_write_v1_failure_context "$PROJECT_DIR" "ENVIRONMENT" "ENVIRONMENT" "test_infra"
    _hook_emit_run_summary 0 >/dev/null 2>&1
    if [[ ! -f "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" ]]; then
        pass "S8.T3 LAST_FAILURE_CONTEXT.json removed on success"
    else
        fail "S8.T3 LAST_FAILURE_CONTEXT.json was not removed on success"
    fi
else
    skip "S8.T3 — _clear_arc_artifacts_on_success not yet implemented"
fi

echo "=== S8.T4: success run → BUILD_FIX_REPORT.md removed ==="
if declare -f _hook_emit_run_summary &>/dev/null \
   && declare -f _clear_arc_artifacts_on_success &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    LOG_DIR="${PROJECT_DIR}/.claude/logs"
    export LOG_DIR
    _arc_reset_orch_state
    bf_report="${PROJECT_DIR}/${BUILD_FIX_REPORT_FILE}"
    raw_errors="${PROJECT_DIR}/${BUILD_RAW_ERRORS_FILE}"
    mkdir -p "$(dirname "$bf_report")" "$(dirname "$raw_errors")"
    echo "## Attempt 1" > "$bf_report"
    echo "src/foo.ts(1,1): error TS2304: x" > "$raw_errors"
    _hook_emit_run_summary 0 >/dev/null 2>&1
    if [[ ! -f "$bf_report" ]]; then
        pass "S8.T4 BUILD_FIX_REPORT.md removed on success"
    else
        fail "S8.T4 BUILD_FIX_REPORT.md was not removed on success"
    fi
    if [[ ! -f "$raw_errors" ]]; then
        pass "S8.T4 BUILD_RAW_ERRORS.txt removed on success"
    else
        fail "S8.T4 BUILD_RAW_ERRORS.txt was not removed on success"
    fi
else
    skip "S8.T4 — _clear_arc_artifacts_on_success not yet implemented"
fi

echo "=== S8.T5: failure run → LAST_FAILURE_CONTEXT.json retained ==="
if declare -f _hook_emit_run_summary &>/dev/null \
   && declare -f _clear_arc_artifacts_on_success &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    LOG_DIR="${PROJECT_DIR}/.claude/logs"
    export LOG_DIR
    _arc_reset_orch_state
    _arc_write_v1_failure_context "$PROJECT_DIR" "ENVIRONMENT" "ENVIRONMENT" "test_infra"
    _hook_emit_run_summary 1 >/dev/null 2>&1
    if [[ -f "${PROJECT_DIR}/.claude/LAST_FAILURE_CONTEXT.json" ]]; then
        pass "S8.T5 LAST_FAILURE_CONTEXT.json retained on failure"
    else
        fail "S8.T5 LAST_FAILURE_CONTEXT.json was incorrectly removed on failure"
    fi
else
    skip "S8.T5 — _clear_arc_artifacts_on_success not yet implemented"
fi

echo "=== S8.T6: preflight_bak with 7 files, retain=5 → 2 oldest removed ==="
if declare -f _trim_preflight_bak_dir &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    bak_dir="${PROJECT_DIR}/.claude/preflight_bak"
    mkdir -p "$bak_dir"
    for ts in 20260101_010101 20260102_010101 20260103_010101 20260104_010101 \
              20260105_010101 20260106_010101 20260107_010101; do
        echo "backup-${ts}" > "${bak_dir}/${ts}_playwright.config.ts"
    done
    _trim_preflight_bak_dir "$bak_dir" 5
    remaining=$(find "$bak_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
    assert_eq "S8.T6 5 backups remain after trim" "5" "$remaining"
    if [[ ! -f "${bak_dir}/20260101_010101_playwright.config.ts" ]] \
       && [[ ! -f "${bak_dir}/20260102_010101_playwright.config.ts" ]]; then
        pass "S8.T6 oldest 2 backups removed"
    else
        fail "S8.T6 oldest backups not removed"
    fi
    if [[ -f "${bak_dir}/20260107_010101_playwright.config.ts" ]] \
       && [[ -f "${bak_dir}/20260103_010101_playwright.config.ts" ]]; then
        pass "S8.T6 newest 5 backups retained"
    else
        fail "S8.T6 newest backups not retained"
    fi
else
    skip "S8.T6 — _trim_preflight_bak_dir not yet implemented"
fi

echo "=== S8.T7: preflight_bak with 3 files, retain=5 → no files removed ==="
if declare -f _trim_preflight_bak_dir &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    bak_dir="${PROJECT_DIR}/.claude/preflight_bak"
    mkdir -p "$bak_dir"
    for ts in 20260101_010101 20260102_010101 20260103_010101; do
        echo "backup-${ts}" > "${bak_dir}/${ts}_playwright.config.ts"
    done
    _trim_preflight_bak_dir "$bak_dir" 5
    remaining=$(find "$bak_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
    assert_eq "S8.T7 3 backups remain (no trim)" "3" "$remaining"
else
    skip "S8.T7 — _trim_preflight_bak_dir not yet implemented"
fi

echo "=== S8.T8: PREFLIGHT_BAK_RETAIN_COUNT=0 → no files removed (keep all) ==="
if declare -f _trim_preflight_bak_dir &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    bak_dir="${PROJECT_DIR}/.claude/preflight_bak"
    mkdir -p "$bak_dir"
    for ts in 20260101_010101 20260102_010101 20260103_010101 20260104_010101 \
              20260105_010101 20260106_010101 20260107_010101; do
        echo "backup-${ts}" > "${bak_dir}/${ts}_playwright.config.ts"
    done
    PREFLIGHT_BAK_RETAIN_COUNT=0 _trim_preflight_bak_dir "$bak_dir"
    remaining=$(find "$bak_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
    assert_eq "S8.T8 retain=0 keeps all 7 backups" "7" "$remaining"
else
    skip "S8.T8 — _trim_preflight_bak_dir not yet implemented"
fi

echo "=== S8.T9: _trim_preflight_bak_dir on missing dir is a no-op ==="
if declare -f _trim_preflight_bak_dir &>/dev/null; then
    if _trim_preflight_bak_dir "/nonexistent-path-m135" 5; then
        pass "S8.T9 missing dir → no-op (return 0)"
    else
        fail "S8.T9 missing dir → unexpected non-zero exit"
    fi
else
    skip "S8.T9 — _trim_preflight_bak_dir not yet implemented"
fi

echo "=== S8.T10: auto-patch triggers _trim_preflight_bak_dir via declare -f guard ==="
# Closes the integration coverage gap noted by the reviewer: the declare -f guard
# in _pf_uitest_playwright_fix_reporter (preflight_checks_ui.sh:185) is the call
# site that was untested. Runs the full _preflight_check_ui_test_config → fix →
# backup-write → trim chain with 7 pre-existing overflow backups so that the trim
# is observable (8 total → 5 retained = 3 deleted).
if declare -f _preflight_check_ui_test_config &>/dev/null \
   && declare -f _trim_preflight_bak_dir &>/dev/null; then
    PROJECT_DIR=$(_arc_setup_scenario_dir); export PROJECT_DIR
    _arc_reset_preflight_state
    export UI_TEST_CMD="npx playwright test"
    _arc_write_playwright_html "$PROJECT_DIR"

    # Pre-populate preflight_bak with 7 old-timestamped backups.
    # 7 old + 1 new (written by fix helper) = 8 total; default retain=5 → 3 removed.
    bak_dir="${PROJECT_DIR}/.claude/preflight_bak"
    mkdir -p "$bak_dir"
    for ts in 20250101_010101 20250102_010101 20250103_010101 20250104_010101 \
              20250105_010101 20250106_010101 20250107_010101; do
        echo "old-backup-${ts}" > "${bak_dir}/${ts}_playwright.config.ts"
    done

    unset PREFLIGHT_BAK_RETAIN_COUNT  # use default (5)
    PREFLIGHT_UI_CONFIG_AUTO_FIX=true _preflight_check_ui_test_config

    # Auto-fix must have succeeded — otherwise the trim call site was never reached.
    assert_eq "S8.T10 reporter patched by auto-fix" "1" "${PREFLIGHT_UI_REPORTER_PATCHED:-}"

    # The bak dir should now hold exactly 5 files (trim enforced default retain=5).
    remaining=$(find "$bak_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
    assert_eq "S8.T10 bak_dir trimmed to retain count (5)" "5" "$remaining"

    # The 3 lexicographically-oldest backups must have been removed.
    if [[ ! -f "${bak_dir}/20250101_010101_playwright.config.ts" ]] \
       && [[ ! -f "${bak_dir}/20250102_010101_playwright.config.ts" ]] \
       && [[ ! -f "${bak_dir}/20250103_010101_playwright.config.ts" ]]; then
        pass "S8.T10 3 oldest overflow backups removed"
    else
        fail "S8.T10 oldest overflow backups were not removed"
    fi

    # The newest pre-existing backup must be retained.
    if [[ -f "${bak_dir}/20250107_010101_playwright.config.ts" ]]; then
        pass "S8.T10 newest pre-existing backup retained"
    else
        fail "S8.T10 newest pre-existing backup was incorrectly removed"
    fi
else
    skip "S8.T10 — _preflight_check_ui_test_config or _trim_preflight_bak_dir not yet implemented"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  Resilience arc integration: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
