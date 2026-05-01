#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# tests/resilience_arc_fixtures.sh — Shared fixture helpers for the M134
# resilience arc integration test suite.
#
# Sourced by tests/test_resilience_arc_integration.sh. NOT auto-run by
# tests/run_tests.sh — the runner only discovers files matching `test_*.sh`.
#
# Provides:
#   _arc_setup_scenario_dir         — fresh PROJECT_DIR under TMPDIR with
#                                     .claude/ and .tekhton/ scaffolding
#   _arc_reset_orch_state           — zero all _ORCH_* + cause slot vars
#   _arc_reset_preflight_state      — zero _PF_* + PREFLIGHT_UI_* contract vars
#   _arc_write_v2_failure_context   — write LAST_FAILURE_CONTEXT.json (v2)
#   _arc_write_v1_failure_context   — write LAST_FAILURE_CONTEXT.json (v1)
#   _arc_write_playwright_html      — playwright.config.ts with reporter:html
#   _setup_bifl_tracker_m03_fixture — replicates the bifl-tracker M03 state
#                                     (used by S6.1 + at least one other test)
# =============================================================================

# _arc_setup_scenario_dir — create a fresh sub-PROJECT_DIR with .claude/ and
# .tekhton/ scaffolding. Echoes the new directory path. Caller is responsible
# for `export PROJECT_DIR="$(_arc_setup_scenario_dir)"`.
_arc_setup_scenario_dir() {
    local dir
    dir=$(mktemp -d "${TMPDIR_TOP:-/tmp}/arc-scenario.XXXXXX")
    mkdir -p "${dir}/.claude/logs" "${dir}/.tekhton"
    echo "$dir"
}

# _arc_reset_orch_state — zeros every _ORCH_* var the recovery + summary
# collectors read. Use this between scenarios that exercise _classify_failure
# or _hook_emit_run_summary so leakage from a prior scenario does not pollute
# the next assertion.
_arc_reset_orch_state() {
    export _ORCH_PRIMARY_CAT=""
    export _ORCH_PRIMARY_SUB=""
    export _ORCH_PRIMARY_SIGNAL=""
    export _ORCH_SECONDARY_CAT=""
    export _ORCH_SECONDARY_SUB=""
    export _ORCH_SECONDARY_SIGNAL=""
    export _ORCH_SCHEMA_VERSION=0
    export _ORCH_ENV_GATE_RETRIED=0
    export _ORCH_MIXED_BUILD_RETRIED=0
    export _ORCH_RECOVERY_ROUTE_TAKEN=""
    export AGENT_ERROR_CATEGORY=""
    export AGENT_ERROR_SUBCATEGORY=""
    export PRIMARY_ERROR_CATEGORY=""
    export PRIMARY_ERROR_SUBCATEGORY=""
    export PRIMARY_ERROR_SIGNAL=""
    export PRIMARY_ERROR_SOURCE=""
    export SECONDARY_ERROR_CATEGORY=""
    export SECONDARY_ERROR_SUBCATEGORY=""
    export SECONDARY_ERROR_SIGNAL=""
    export SECONDARY_ERROR_SOURCE=""
    export VERDICT=""
    unset BUILD_FIX_OUTCOME BUILD_FIX_ATTEMPTS BUILD_FIX_TURN_BUDGET_USED \
          BUILD_FIX_PROGRESS_GATE_FAILURES LAST_BUILD_CLASSIFICATION
}

# _arc_reset_preflight_state — zeros _PF_* counters and unsets PREFLIGHT_UI_*
# contract vars. Mirrors test_preflight_ui_config.sh::_reset_pf_state.
_arc_reset_preflight_state() {
    _PF_PASS=0
    _PF_WARN=0
    _PF_FAIL=0
    _PF_REMEDIATED=0
    _PF_REPORT_LINES=()
    _PF_LANGUAGES=""
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE \
          PREFLIGHT_UI_REPORTER_PATCHED
}

# _arc_json_escape STR — minimal JSON string escape (backslash, quote, control chars).
# Mirrors lib/output_format.sh::_out_json_escape. Used by the failure-context
# writers below to keep heredocs valid even if a future caller passes dynamic
# input containing quotes, backslashes, or newlines.
_arc_json_escape() {
    local s="$*"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
    printf '%s' "$s"
}

# _arc_write_v2_failure_context DIR PRIMARY_CAT PRIMARY_SUB PRIMARY_SIG \
#                              SECONDARY_CAT SECONDARY_SUB SECONDARY_SIG \
#                              [CLASSIFICATION]
# Writes a LAST_FAILURE_CONTEXT.json v2 into DIR/.claude/. Pretty-print
# layout matches the m129 writer contract (one inner key per line).
_arc_write_v2_failure_context() {
    local dir="$1"
    local p_cat p_sub p_sig s_cat s_sub s_sig classification
    p_cat=$(_arc_json_escape "$2")
    p_sub=$(_arc_json_escape "$3")
    p_sig=$(_arc_json_escape "$4")
    s_cat=$(_arc_json_escape "$5")
    s_sub=$(_arc_json_escape "$6")
    s_sig=$(_arc_json_escape "$7")
    classification=$(_arc_json_escape "${8:-FAILURE}")
    mkdir -p "${dir}/.claude"
    cat > "${dir}/.claude/LAST_FAILURE_CONTEXT.json" <<EOF
{
  "schema_version": 2,
  "classification": "${classification}",
  "stage": "coder",
  "outcome": "failure",
  "task": "arc-scenario",
  "consecutive_count": 1,
  "primary_cause": {
    "category": "${p_cat}",
    "subcategory": "${p_sub}",
    "signal": "${p_sig}",
    "source": "build_gate"
  },
  "secondary_cause": {
    "category": "${s_cat}",
    "subcategory": "${s_sub}",
    "signal": "${s_sig}",
    "source": "coder_build_fix"
  }
}
EOF
}

# _arc_write_v1_failure_context DIR CLASSIFICATION CATEGORY SUBCATEGORY
# Writes a flat (pre-m129) LAST_FAILURE_CONTEXT.json. Used by backward-compat
# scenarios (S4.4, S6.4).
_arc_write_v1_failure_context() {
    local dir="$1"
    local classification category sub
    classification=$(_arc_json_escape "$2")
    category=$(_arc_json_escape "$3")
    sub=$(_arc_json_escape "$4")
    mkdir -p "${dir}/.claude"
    cat > "${dir}/.claude/LAST_FAILURE_CONTEXT.json" <<EOF
{
  "classification": "${classification}",
  "category": "${category}",
  "subcategory": "${sub}"
}
EOF
}

# _arc_write_playwright_html DIR
# Writes a minimal playwright.config.ts that triggers PW-1 in m131's audit.
_arc_write_playwright_html() {
    local dir="$1"
    cat > "${dir}/playwright.config.ts" <<'EOF'
import { defineConfig } from '@playwright/test';
export default defineConfig({
  reporter: 'html',
  testDir: './tests',
});
EOF
}

# _setup_bifl_tracker_m03_fixture DIR
# Replicates the bifl-tracker M03 failure state — the exact scenario that
# motivated the resilience arc. Used by S6.1 (golden path) and S5.1
# (RUN_SUMMARY enrichment from a real failure shape) to keep fixture wiring
# consistent across both. Writes:
#   .claude/LAST_FAILURE_CONTEXT.json (v2)
#   .claude/PIPELINE_STATE.md
#   .claude/logs/<ts>.log with interactive-reporter evidence
#   playwright.config.ts with reporter: 'html'
#   ${BUILD_RAW_ERRORS_FILE} non-empty (TS errors)
_setup_bifl_tracker_m03_fixture() {
    local dir="$1"
    mkdir -p "${dir}/.claude/logs" "${dir}/.tekhton"

    _arc_write_v2_failure_context "$dir" \
        "ENVIRONMENT" "test_infra" "ui_timeout_interactive_report" \
        "AGENT_SCOPE" "max_turns" "build_fix_budget_exhausted" \
        "UI_INTERACTIVE_REPORTER"

    cat > "${dir}/.claude/PIPELINE_STATE.md" <<'EOF'
## Exit Stage
coder
## Exit Reason
complete_loop_max_attempts
## Task
M03
## Notes
Primary cause: ENVIRONMENT/test_infra (ui_timeout_interactive_report)
Secondary cause: AGENT_SCOPE/max_turns (build_fix_budget_exhausted)
EOF

    echo "Serving HTML report at http://localhost:9323. Press Ctrl+C to quit." \
        > "${dir}/.claude/logs/20260425_182710_m03.log"

    _arc_write_playwright_html "$dir"

    local raw_errors_path="${BUILD_RAW_ERRORS_FILE:-.tekhton/BUILD_RAW_ERRORS.txt}"
    local raw_errors_file="${dir}/${raw_errors_path}"
    mkdir -p "$(dirname "${raw_errors_file}")"
    cat > "${raw_errors_file}" <<'EOF'
src/app/page.tsx(12,5): error TS2304: Cannot find name 'undefined'.
src/lib/db.ts(8,3): error TS2339: Property 'query' does not exist.
EOF
}
