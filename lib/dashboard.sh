#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# dashboard.sh — Dashboard lifecycle and run-state emission
#
# Sourced by tekhton.sh — do not run directly.
# Expects: causality.sh and dashboard_parsers.sh sourced first.
# Expects: PROJECT_DIR, TEKHTON_HOME (set by caller/config)
#
# Provides:
#   is_dashboard_enabled        — check DASHBOARD_ENABLED config
#   init_dashboard              — create .claude/dashboard/ with data dir
#   sync_dashboard_static_files — ensure static UI files are up to date
#   _copy_static_files          — copy templates/watchtower/* into dash dir
#   cleanup_dashboard           — remove .claude/dashboard/
#   emit_dashboard_run_state    — generate data/run_state.js
# =============================================================================

# Source report parsers
# shellcheck source=lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"
# shellcheck source=lib/dashboard_emitters.sh
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# --- Enable check -------------------------------------------------------------

# is_dashboard_enabled
# Returns 0 if dashboard is enabled, 1 otherwise.
is_dashboard_enabled() {
    [[ "${DASHBOARD_ENABLED:-true}" = "true" ]]
}

# --- Lifecycle ----------------------------------------------------------------

# _ensure_dashboard_data_dir DASH_DIR
# Creates the data/ subdirectory and seeds empty data files if missing.
# Shared by init_dashboard and sync_dashboard_static_files.
_ensure_dashboard_data_dir() {
    local dash_dir="$1"
    mkdir -p "${dash_dir}/data" 2>/dev/null || true

    # Seed initial empty data files so the HTML doesn't 404 on script tags
    [[ -f "${dash_dir}/data/run_state.js" ]]  || _write_js_file "${dash_dir}/data/run_state.js" "TK_RUN_STATE" '{"pipeline_status":"initializing","stages":{}}'
    [[ -f "${dash_dir}/data/timeline.js" ]]   || _write_js_file "${dash_dir}/data/timeline.js" "TK_TIMELINE" '[]'
    [[ -f "${dash_dir}/data/milestones.js" ]]  || _write_js_file "${dash_dir}/data/milestones.js" "TK_MILESTONES" '[]'
    [[ -f "${dash_dir}/data/security.js" ]]   || _write_js_file "${dash_dir}/data/security.js" "TK_SECURITY" '{"findings":[]}'
    [[ -f "${dash_dir}/data/reports.js" ]]    || _write_js_file "${dash_dir}/data/reports.js" "TK_REPORTS" '{}'
    [[ -f "${dash_dir}/data/metrics.js" ]]    || _write_js_file "${dash_dir}/data/metrics.js" "TK_METRICS" '{"runs":[]}'
    [[ -f "${dash_dir}/data/health.js" ]]     || _write_js_file "${dash_dir}/data/health.js" "TK_HEALTH" '{"available":false}'
    [[ -f "${dash_dir}/data/diagnosis.js" ]]  || _write_js_file "${dash_dir}/data/diagnosis.js" "TK_DIAGNOSIS" '{"available":false}'
}

# init_dashboard [PROJECT_DIR]
# Creates .claude/dashboard/ directory with data subdirectory.
init_dashboard() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"

    if ! is_dashboard_enabled; then
        return 0
    fi

    local dash_dir="${project_dir}/${DASHBOARD_DIR:-.claude/dashboard}"

    # Create data dir + seed empty data files (also creates parent dir)
    _ensure_dashboard_data_dir "$dash_dir"

    # Copy static UI files from templates/watchtower/
    _copy_static_files "$dash_dir"
    _DASHBOARD_JUST_INITIALIZED=true
}

# sync_dashboard_static_files [PROJECT_DIR]
# Ensures static UI files and data directory are up to date.
# Called on every startup when dashboard is enabled.
sync_dashboard_static_files() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"
    if ! is_dashboard_enabled; then
        return 0
    fi
    local dash_dir="${project_dir}/${DASHBOARD_DIR:-.claude/dashboard}"
    if [[ ! -d "$dash_dir" ]]; then
        return 0
    fi
    _copy_static_files "$dash_dir"

    # Ensure data/ exists even when gitignored or cleaned (b3476d4)
    _ensure_dashboard_data_dir "$dash_dir"
}

# _copy_static_files DASH_DIR
# Copies templates/watchtower/* (index.html, style.css, app.js) into the
# dashboard directory. Overwrites unconditionally to ensure latest versions.
_copy_static_files() {
    local dash_dir="$1"
    local src_dir="${TEKHTON_HOME:-$(dirname "$(dirname "${BASH_SOURCE[0]}")")}/templates/watchtower"

    if [[ ! -d "$src_dir" ]]; then
        return 0
    fi

    local file
    for file in index.html style.css app.js; do
        if [[ -f "${src_dir}/${file}" ]]; then
            cp "${src_dir}/${file}" "${dash_dir}/${file}"
        fi
    done
}

# cleanup_dashboard [PROJECT_DIR]
# Removes .claude/dashboard/ directory cleanly.
cleanup_dashboard() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"
    local dash_dir="${project_dir}/${DASHBOARD_DIR:-.claude/dashboard}"

    if [[ -d "$dash_dir" ]]; then
        rm -rf "$dash_dir" 2>/dev/null || true
    fi
}

# --- Run state emission -------------------------------------------------------

# emit_dashboard_run_state
# Generates data/run_state.js with current pipeline state.
emit_dashboard_run_state() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0

    local status="${PIPELINE_STATUS:-running}"
    local current_stage="${CURRENT_STAGE:-unknown}"
    local ms_id="${_CURRENT_MILESTONE:-}"
    local ms_title=""
    if [[ -n "$ms_id" ]] && command -v get_milestone_title &>/dev/null; then
        ms_title=$(get_milestone_title "$ms_id" "${PROJECT_RULES_FILE:-CLAUDE.md}" 2>/dev/null || true)
    fi

    local started_at="${START_AT_TS:-}"
    local waiting="${WAITING_FOR:-}"

    # Build stages JSON
    local stages_json="{"
    local first=true
    for stg in intake scout coder build_gate security reviewer tester; do
        local stg_status="${_STAGE_STATUS[$stg]:-pending}"
        local stg_turns="${_STAGE_TURNS[$stg]:-0}"
        local stg_budget="${_STAGE_BUDGET[$stg]:-0}"
        local stg_dur="${_STAGE_DURATION[$stg]:-0}"

        if [[ "$first" = true ]]; then first=false; else stages_json="${stages_json},"; fi
        stages_json="${stages_json}\"${stg}\":{\"status\":\"${stg_status}\",\"turns\":${stg_turns},\"budget\":${stg_budget},\"duration_s\":${stg_dur}}"
    done
    stages_json="${stages_json}}"

    local ms_json="null"
    if [[ -n "$ms_id" ]]; then
        ms_json="{\"id\":\"$(_json_escape "$ms_id")\",\"title\":\"$(_json_escape "$ms_title")\"}"
    fi

    # Convert DASHBOARD_REFRESH_INTERVAL (seconds) to milliseconds for the UI
    local refresh_ms
    refresh_ms=$(( ${DASHBOARD_REFRESH_INTERVAL:-5} * 1000 ))

    # Quota status (M16)
    local quota_status="ok"
    local quota_paused_at=""
    local quota_retry_count="0"
    if [[ "${_QUOTA_PAUSED:-false}" = "true" ]]; then
        quota_status="paused"
        if [[ -f "${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED" ]]; then
            quota_paused_at=$(grep '^paused_at=' "${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED" 2>/dev/null | cut -d= -f2- || true)
        fi
        quota_retry_count="${_QUOTA_PAUSE_COUNT:-0}"
    fi

    # Build waiting_for JSON value explicitly
    local waiting_json="null"
    if [[ -n "$waiting" ]]; then
        waiting_json="\"$(_json_escape "$waiting")\""
    fi

    # completed_at timestamp (M34 §3) — set when pipeline_status is success/failed
    local completed_at_json="null"
    if [[ "$status" = "success" ]] || [[ "$status" = "failed" ]]; then
        local completed_ts
        completed_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
        completed_at_json="\"${completed_ts}\""
    fi

    local json
    json=$(printf '{"pipeline_status":"%s","current_stage":"%s","active_milestone":%s,"stages":%s,"waiting_for":%s,"started_at":"%s","completed_at":%s,"refresh_interval_ms":%d,"quota_status":"%s","quota_paused_at":"%s","quota_retry_count":%d}' \
        "$(_json_escape "$status")" \
        "$(_json_escape "$current_stage")" \
        "$ms_json" \
        "$stages_json" \
        "$waiting_json" \
        "$(_json_escape "$started_at")" \
        "$completed_at_json" \
        "$refresh_ms" \
        "$(_json_escape "$quota_status")" \
        "$(_json_escape "$quota_paused_at")" \
        "$quota_retry_count")

    _write_js_file "${dash_dir}/data/run_state.js" "TK_RUN_STATE" "$json"
}
