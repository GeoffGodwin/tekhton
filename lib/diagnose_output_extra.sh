#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# diagnose_output_extra.sh — Crash first-aid + dashboard integration
#
# Extracted from lib/diagnose_output.sh as part of M129 to keep that file
# under the 300-line ceiling. Sourced by lib/diagnose.sh after
# diagnose_output.sh — do not run directly.
#
# Provides:
#   print_crash_first_aid     — quick checks for common failure modes
#   emit_dashboard_diagnosis  — generate data/diagnosis.js for Watchtower
# =============================================================================

# --- Smart crash first-aid ---------------------------------------------------

# print_crash_first_aid
# Quick checks for common failure modes. Called from crash handler.
# No agent calls — pure shell checks. Must be fast.
print_crash_first_aid() {
    # Quota pause
    if [[ -f "${PROJECT_DIR:-.}/.claude/QUOTA_PAUSED" ]]; then
        warn "Looks like a quota issue — the pipeline is paused and will resume"
        warn "when quota refreshes. Or run 'tekhton' to resume manually."
        return 0
    fi

    # Build failure
    if [[ -f "${PROJECT_DIR:-.}/${BUILD_ERRORS_FILE}" ]] && [[ -s "${PROJECT_DIR:-.}/${BUILD_ERRORS_FILE}" ]]; then
        warn "Build failure detected — run 'tekhton --diagnose' for detailed"
        warn "analysis, or fix ${BUILD_ERRORS_FILE} manually."
        return 0
    fi

    # Resumable state
    local state_file="${PIPELINE_STATE_FILE:-${PROJECT_DIR:-.}/.claude/PIPELINE_STATE.md}"
    if [[ -f "$state_file" ]]; then
        local stage
        stage=$(awk '/^## Exit Stage$/{getline; print; exit}' "$state_file" 2>/dev/null || true)
        warn "Crash during ${stage:-unknown} stage — your code is safe (checkpoint saved)."
        warn "Run 'tekhton' to resume from where it left off."
        return 0
    fi

    # Transient error check in recent log
    local latest_log
    latest_log=$(find "${PROJECT_DIR:-.}/.claude/logs" -maxdepth 1 -name '*.log' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$latest_log" ]]; then
        if tail -20 "$latest_log" 2>/dev/null | grep -qiE 'rate.limit|overloaded|server_error|timeout' 2>/dev/null; then
            warn "Transient API error detected. Re-run 'tekhton' to retry."
            return 0
        fi
    fi
}

# --- Dashboard integration ----------------------------------------------------

# emit_dashboard_diagnosis
# Reads ${DIAGNOSIS_FILE} and generates data/diagnosis.js for Watchtower.
emit_dashboard_diagnosis() {
    if ! command -v is_dashboard_enabled &>/dev/null || ! is_dashboard_enabled; then
        return 0
    fi

    local dash_dir="${PROJECT_DIR:-.}/${DASHBOARD_DIR:-.claude/dashboard}"
    [[ -d "${dash_dir}/data" ]] || return 0

    local json
    if [[ -n "$DIAG_CLASSIFICATION" ]] && [[ "$DIAG_CLASSIFICATION" != "SUCCESS" ]]; then
        # Build suggestions JSON array
        local sugg_json="["
        local first=true
        for s in "${DIAG_SUGGESTIONS[@]}"; do
            local safe_s
            safe_s=$(printf '%s' "$s" | sed 's/\\/\\\\/g; s/"/\\"/g')
            if [[ "$first" = true ]]; then first=false; else sugg_json="${sugg_json},"; fi
            sugg_json="${sugg_json}\"${safe_s}\""
        done
        sugg_json="${sugg_json}]"

        local safe_chain=""
        if [[ -n "$_DIAG_CAUSE_CHAIN_SHORT" ]]; then
            safe_chain=$(printf '%s' "$_DIAG_CAUSE_CHAIN_SHORT" | sed 's/\\/\\\\/g; s/"/\\"/g')
        fi

        json=$(printf '{"available":true,"classification":"%s","confidence":"%s","stage":"%s","cause_chain":"%s","suggestions":%s,"recurring_count":%d}' \
            "$DIAG_CLASSIFICATION" \
            "$DIAG_CONFIDENCE" \
            "$(_json_escape "${_DIAG_PIPELINE_STAGE:-}")" \
            "$safe_chain" \
            "$sugg_json" \
            "$_DIAG_RECURRING_COUNT")
    else
        json='{"available":false}'
    fi

    _write_js_file "${dash_dir}/data/diagnosis.js" "TK_DIAGNOSIS" "$json"
}
