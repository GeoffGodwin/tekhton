#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# dashboard.sh — Dashboard data emission module (views over causal log)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: causality.sh and dashboard_parsers.sh sourced first.
# Expects: PROJECT_DIR, TEKHTON_HOME (set by caller/config)
#
# Provides:
#   init_dashboard             — create .claude/dashboard/ with data dir
#   cleanup_dashboard          — remove .claude/dashboard/
#   is_dashboard_enabled       — check DASHBOARD_ENABLED config
#   emit_dashboard_run_state   — generate data/run_state.js
#   emit_dashboard_milestones  — generate data/milestones.js
#   emit_dashboard_security    — generate data/security.js
#   emit_dashboard_reports     — generate data/reports.js
#   emit_dashboard_metrics     — generate data/metrics.js
#   _regenerate_timeline_js    — rebuild data/timeline.js from causal log
# =============================================================================

# Source report parsers
# shellcheck source=lib/dashboard_parsers.sh
source "$(dirname "${BASH_SOURCE[0]}")/dashboard_parsers.sh"

# --- Enable check -------------------------------------------------------------

# is_dashboard_enabled
# Returns 0 if dashboard is enabled, 1 otherwise.
is_dashboard_enabled() {
    [[ "${DASHBOARD_ENABLED:-true}" = "true" ]]
}

# --- Lifecycle ----------------------------------------------------------------

# init_dashboard [PROJECT_DIR]
# Creates .claude/dashboard/ directory with data subdirectory.
init_dashboard() {
    local project_dir="${1:-${PROJECT_DIR:-.}}"

    if ! is_dashboard_enabled; then
        return 0
    fi

    local dash_dir="${project_dir}/${DASHBOARD_DIR:-.claude/dashboard}"
    mkdir -p "${dash_dir}/data" 2>/dev/null || true

    # Generate initial empty data files
    _write_js_file "${dash_dir}/data/run_state.js" "TK_RUN_STATE" '{"pipeline_status":"initializing","stages":{}}'
    _write_js_file "${dash_dir}/data/timeline.js" "TK_TIMELINE" '[]'
    _write_js_file "${dash_dir}/data/milestones.js" "TK_MILESTONES" '[]'
    _write_js_file "${dash_dir}/data/security.js" "TK_SECURITY" '{"findings":[]}'
    _write_js_file "${dash_dir}/data/reports.js" "TK_REPORTS" '{}'
    _write_js_file "${dash_dir}/data/metrics.js" "TK_METRICS" '{"runs":[]}'
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

    local json
    json=$(printf '{"pipeline_status":"%s","current_stage":"%s","active_milestone":%s,"stages":%s,"waiting_for":%s,"started_at":"%s"}' \
        "$(_json_escape "$status")" \
        "$(_json_escape "$current_stage")" \
        "$ms_json" \
        "$stages_json" \
        "${waiting:+\"$(_json_escape "$waiting")\"}" \
        "$(_json_escape "$started_at")")
    # Fix null for waiting_for when empty
    if [[ -z "$waiting" ]]; then
        json="${json/\"waiting_for\":,/\"waiting_for\":null,}"
    fi

    _write_js_file "${dash_dir}/data/run_state.js" "TK_RUN_STATE" "$json"
}

# --- Timeline emission --------------------------------------------------------

# _regenerate_timeline_js
# Rebuild data/timeline.js from the causal log.
# Respects DASHBOARD_MAX_TIMELINE_EVENTS cap.
_regenerate_timeline_js() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0
    [[ ! -f "${CAUSAL_LOG_FILE:-}" ]] && return 0

    : "${DASHBOARD_MAX_TIMELINE_EVENTS:=500}"
    : "${DASHBOARD_VERBOSITY:=normal}"

    local tmpfile="${dash_dir}/data/timeline.js.tmp.$$"
    {
        printf '// Generated by Tekhton Watchtower — do not edit\n'
        printf '// Updated: %s\n' "$(_to_js_timestamp)"
        printf 'window.TK_TIMELINE = [\n'

        local count=0
        local first=true
        # Apply verbosity filter
        local filter_pattern=""
        case "$DASHBOARD_VERBOSITY" in
            minimal) filter_pattern='"type":"stage_end"\|"type":"verdict"' ;;
            normal)  filter_pattern='"type":"stage_\|"type":"verdict"\|"type":"finding"\|"type":"build_gate"\|"type":"pipeline_\|"type":"milestone_"' ;;
            verbose) filter_pattern="" ;;  # no filter — include everything
        esac

        # Read from causal log, apply filter, cap at max events
        # Use tail to get most recent events if log exceeds cap
        local lines
        if [[ -n "$filter_pattern" ]]; then
            lines=$(grep "$filter_pattern" "$CAUSAL_LOG_FILE" 2>/dev/null | tail -n "$DASHBOARD_MAX_TIMELINE_EVENTS" || true)
        else
            lines=$(tail -n "$DASHBOARD_MAX_TIMELINE_EVENTS" "$CAUSAL_LOG_FILE" 2>/dev/null || true)
        fi

        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if [[ "$first" = true ]]; then
                first=false
            else
                printf ',\n'
            fi
            printf '  %s' "$line"
            count=$(( count + 1 ))
        done <<< "$lines"

        printf '\n];\n'
    } > "$tmpfile"
    mv "$tmpfile" "${dash_dir}/data/timeline.js"
}

# --- Milestone emission -------------------------------------------------------

# emit_dashboard_milestones
# Reads MANIFEST.cfg and generates data/milestones.js.
emit_dashboard_milestones() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0

    local manifest="${MILESTONE_DIR:-${PROJECT_DIR:-.}/.claude/milestones}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"

    local json="["
    local first=true

    if [[ -f "$manifest" ]]; then
        while IFS='|' read -r mid title status deps _mfile pgroup; do
            # Skip comments and empty lines
            [[ -z "$mid" ]] && continue
            [[ "$mid" =~ ^[[:space:]]*# ]] && continue
            mid="${mid## }"; mid="${mid%% }"
            title="${title## }"; title="${title%% }"
            status="${status## }"; status="${status%% }"
            deps="${deps## }"; deps="${deps%% }"
            pgroup="${pgroup## }"; pgroup="${pgroup%% }"

            if [[ "$first" = true ]]; then first=false; else json="${json},"; fi
            json="${json}{\"id\":\"$(_json_escape "$mid")\",\"title\":\"$(_json_escape "$title")\",\"status\":\"$(_json_escape "$status")\",\"depends_on\":\"$(_json_escape "$deps")\",\"parallel_group\":\"$(_json_escape "$pgroup")\"}"
        done < "$manifest"
    fi

    json="${json}]"
    _write_js_file "${dash_dir}/data/milestones.js" "TK_MILESTONES" "$json"
}

# --- Security emission --------------------------------------------------------

# emit_dashboard_security
# Parses SECURITY_REPORT.md and generates data/security.js.
emit_dashboard_security() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0

    local findings
    findings=$(_parse_security_report "${SECURITY_REPORT_FILE:-SECURITY_REPORT.md}")

    local json="{\"findings\":${findings}}"
    _write_js_file "${dash_dir}/data/security.js" "TK_SECURITY" "$json"
}

# --- Reports emission ---------------------------------------------------------

# emit_dashboard_reports
# Parses stage reports and generates data/reports.js.
emit_dashboard_reports() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0

    local intake
    intake=$(_parse_intake_report "${INTAKE_REPORT_FILE:-INTAKE_REPORT.md}")
    local coder
    coder=$(_parse_coder_summary "CODER_SUMMARY.md")
    local reviewer
    reviewer=$(_parse_reviewer_report "REVIEWER_REPORT.md")

    local json
    json="{\"intake\":${intake},\"coder\":${coder},\"reviewer\":${reviewer}}"
    _write_js_file "${dash_dir}/data/reports.js" "TK_REPORTS" "$json"
}

# --- Metrics emission ---------------------------------------------------------

# emit_dashboard_metrics
# Reads RUN_SUMMARY.json files and generates data/metrics.js.
emit_dashboard_metrics() {
    if ! is_dashboard_enabled; then return 0; fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ ! -d "${dash_dir}/data" ]] && return 0

    local summary_dir="${LOG_DIR:-${PROJECT_DIR:-.}/.claude/logs}"
    local depth="${DASHBOARD_HISTORY_DEPTH:-50}"

    local runs
    runs=$(_parse_run_summaries "$summary_dir" "$depth")

    local json="{\"runs\":${runs}}"
    _write_js_file "${dash_dir}/data/metrics.js" "TK_METRICS" "$json"
}
