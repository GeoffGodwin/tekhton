#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_summary_collectors.sh — M132 RUN_SUMMARY enrichment collectors
#
# Sourced by finalize_summary.sh — do not run directly.
# Provides JSON-fragment helpers embedded into RUN_SUMMARY.json by
# _hook_emit_run_summary:
#   _collect_causal_context_json   — primary/secondary cause from m129 schema v2
#   _collect_build_fix_stats_json  — m128 build-fix loop attempt/outcome stats
#   _collect_recovery_routing_json — m130 recovery route + retry guards
#   _collect_preflight_ui_json     — m131 preflight UI config-audit findings
#   _collect_error_classes_json    — symptom + root-cause array (m132 enrichment)
#   _collect_recovery_actions_json — recovery action history array (m132 enrichment)
#
# Cross-milestone contracts (do not rename or restructure these keys after
# m132 lands — m133 / m134 read them by exact name; see m132 "Seeds Forward").
# =============================================================================

# _collect_causal_context_json
# Reads LAST_FAILURE_CONTEXT.json via m130's _load_failure_cause_context loader
# and returns a single-line JSON object. When the file is absent or the loader
# leaves _ORCH_SCHEMA_VERSION at 0 (m130 default), returns the absent-file
# sentinel `{"schema_version":0}` — m135's success-run cleanup relies on this.
_collect_causal_context_json() {
    local ctx_file="${ORCH_CONTEXT_FILE_OVERRIDE:-${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json}"
    if [[ ! -f "$ctx_file" ]]; then
        printf '{"schema_version":0}'
        return
    fi
    if declare -F _load_failure_cause_context >/dev/null 2>&1; then
        _load_failure_cause_context
    fi
    printf '{"schema_version":%d,"primary_category":"%s","primary_subcategory":"%s","primary_signal":"%s","secondary_category":"%s","secondary_subcategory":"%s","secondary_signal":"%s"}' \
        "${_ORCH_SCHEMA_VERSION:-0}" \
        "${_ORCH_PRIMARY_CAT:-}" "${_ORCH_PRIMARY_SUB:-}" "${_ORCH_PRIMARY_SIGNAL:-}" \
        "${_ORCH_SECONDARY_CAT:-}" "${_ORCH_SECONDARY_SUB:-}" "${_ORCH_SECONDARY_SIGNAL:-}"
}

# _collect_build_fix_stats_json
# Reads exported vars from the m128 build-fix loop (stages/coder.sh resets
# the four vars to their not-run defaults at stage entry) and emits the
# build_fix_stats object. `outcome` token vocabulary is frozen by m128:
# passed | exhausted | no_progress | not_run.
_collect_build_fix_stats_json() {
    local attempts="${BUILD_FIX_ATTEMPTS:-0}"
    local max_attempts="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    local outcome="${BUILD_FIX_OUTCOME:-not_run}"
    local turn_budget_used="${BUILD_FIX_TURN_BUDGET_USED:-0}"
    local pg_failures="${BUILD_FIX_PROGRESS_GATE_FAILURES:-0}"
    local enabled="true"

    if [[ "$attempts" =~ ^[0-9]+$ ]] && [[ "$attempts" -eq 0 ]]; then
        outcome="not_run"
        enabled="false"
    fi
    [[ "$attempts"          =~ ^[0-9]+$ ]] || attempts=0
    [[ "$max_attempts"      =~ ^[0-9]+$ ]] || max_attempts=3
    [[ "$turn_budget_used"  =~ ^[0-9]+$ ]] || turn_budget_used=0
    [[ "$pg_failures"       =~ ^[0-9]+$ ]] || pg_failures=0

    printf '{"enabled":%s,"attempts":%d,"max_attempts":%d,"outcome":"%s","turn_budget_used":%d,"progress_gate_failures":%d}' \
        "$enabled" "$attempts" "$max_attempts" "$outcome" "$turn_budget_used" "$pg_failures"
}

# _collect_recovery_routing_json
# Reads m130 module-level recovery vars (declared in
# orchestrate_recovery_causal.sh, captured per-iteration via the wrap added
# by m132 in orchestrate_loop.sh:_handle_pipeline_failure).
_collect_recovery_routing_json() {
    local route="${_ORCH_RECOVERY_ROUTE_TAKEN:-save_exit}"
    [[ -n "$route" ]] || route="save_exit"
    local env_retried="${_ORCH_ENV_GATE_RETRIED:-0}"
    local mixed_retried="${_ORCH_MIXED_BUILD_RETRIED:-0}"
    local schema_ver="${_ORCH_SCHEMA_VERSION:-0}"
    [[ "$schema_ver" =~ ^[0-9]+$ ]] || schema_ver=0

    local env_bool="false"
    [[ "$env_retried" = "1" ]] && env_bool="true"
    local mixed_bool="false"
    [[ "$mixed_retried" = "1" ]] && mixed_bool="true"

    printf '{"route_taken":"%s","env_gate_retried":%s,"mixed_build_retried":%s,"causal_schema_version":%d}' \
        "$route" "$env_bool" "$mixed_bool" "$schema_ver"
}

# _collect_preflight_ui_json
# Reads the four PREFLIGHT_UI_* contract vars set by m131's UI-config audit.
# Vars are unset on success runs and on pre-m131 deployments; defaults
# emit the empty-state variant so the JSON shape is stable across all runs.
_collect_preflight_ui_json() {
    local detected="${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-0}"
    local rule="${PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE:-}"
    local file="${PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE:-}"
    local patched="${PREFLIGHT_UI_REPORTER_PATCHED:-0}"
    local pf_fail="${_PF_FAIL:-0}"
    local pf_warn="${_PF_WARN:-0}"
    [[ "$pf_fail" =~ ^[0-9]+$ ]] || pf_fail=0
    [[ "$pf_warn" =~ ^[0-9]+$ ]] || pf_warn=0

    local det_bool="false"
    [[ "$detected" = "1" ]] && det_bool="true"
    local pat_bool="false"
    [[ "$patched" = "1" ]] && pat_bool="true"

    rule=$(printf '%s' "$rule" | sed 's/\\/\\\\/g; s/"/\\"/g')
    file=$(printf '%s' "$file" | sed 's/\\/\\\\/g; s/"/\\"/g')

    printf '{"interactive_config_detected":%s,"interactive_config_rule":"%s","interactive_config_file":"%s","reporter_auto_patched":%s,"fail_count":%d,"warn_count":%d}' \
        "$det_bool" "$rule" "$file" "$pat_bool" "$pf_fail" "$pf_warn"
}

# _collect_error_classes_json
# Builds the error_classes_encountered JSON array. Element 0 is the surface
# symptom (AGENT_ERROR_CATEGORY/SUBCATEGORY); element 1 — when present — is
# `root:CAT/SUB` derived from m130's primary cause when distinct from symptom.
# Refreshes _ORCH_PRIMARY_* via the m130 loader if they are not yet populated.
_collect_error_classes_json() {
    local ec_items=()
    local symptom_class=""
    if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
        symptom_class="${AGENT_ERROR_CATEGORY}/${AGENT_ERROR_SUBCATEGORY:-unknown}"
        ec_items+=("\"${symptom_class}\"")
    fi
    local primary_cat="${_ORCH_PRIMARY_CAT:-}"
    local primary_sub="${_ORCH_PRIMARY_SUB:-}"
    if [[ -z "$primary_cat" ]] && declare -F _load_failure_cause_context >/dev/null 2>&1; then
        _load_failure_cause_context
        primary_cat="${_ORCH_PRIMARY_CAT:-}"
        primary_sub="${_ORCH_PRIMARY_SUB:-}"
    fi
    if [[ -n "$primary_cat" ]] \
       && [[ "${primary_cat}/${primary_sub:-unknown}" != "$symptom_class" ]]; then
        ec_items+=("\"root:${primary_cat}/${primary_sub:-unknown}\"")
    fi
    if [[ ${#ec_items[@]} -eq 0 ]]; then
        printf '%s' "[]"
        return
    fi
    local joined
    joined=$(printf ',%s' "${ec_items[@]}")
    printf '[%s]' "${joined:1}"
}

# _clear_arc_artifacts_on_success (m135)
# Removes transient resilience-arc failure artifacts on success runs so stale
# context cannot contaminate the next --diagnose. Failure runs preserve them
# — they are the primary input to recovery routing and diagnose rules.
# Targets use absolute paths because BUILD_FIX_REPORT_FILE / BUILD_RAW_ERRORS_FILE
# are stored as project-relative strings in artifact_defaults.sh.
_clear_arc_artifacts_on_success() {
    local _p="${PROJECT_DIR:-.}" _f _c=0
    for _f in "${_p}/.claude/LAST_FAILURE_CONTEXT.json" \
              "${_p}/${BUILD_FIX_REPORT_FILE:-.tekhton/BUILD_FIX_REPORT.md}" \
              "${_p}/${BUILD_RAW_ERRORS_FILE:-.tekhton/BUILD_RAW_ERRORS.txt}"; do
        if [[ -f "$_f" ]] && rm -f "$_f" 2>/dev/null; then
            _c=$((_c+1))
        fi
    done
    (( _c > 0 )) && log_verbose "[artifact lifecycle] Cleared ${_c} stale failure artifact(s) on success"
    return 0
}

# _collect_recovery_actions_json
# Builds the recovery_actions_taken JSON array. Combines the legacy in-run
# event flags (review-cycle bump, continuation, transient retry) with the
# m130 recovery route — appended only when non-default (save_exit/empty are
# the no-op defaults; any other route is a meaningful event worth surfacing).
_collect_recovery_actions_json() {
    local ra_items=()
    if [[ "${_ORCH_REVIEW_BUMPED:-false}" = true ]]; then
        ra_items+=("\"review_cycle_bump\"")
    fi
    if [[ "${CONTINUATION_ATTEMPTS:-0}" -gt 0 ]]; then
        ra_items+=("\"continuation\"")
    fi
    if [[ "${LAST_AGENT_RETRY_COUNT:-0}" -gt 0 ]]; then
        ra_items+=("\"transient_retry\"")
    fi
    local route="${_ORCH_RECOVERY_ROUTE_TAKEN:-}"
    if [[ -n "$route" ]] && [[ "$route" != "save_exit" ]]; then
        ra_items+=("\"${route}\"")
    fi
    if [[ ${#ra_items[@]} -eq 0 ]]; then
        printf '%s' "[]"
        return
    fi
    local joined
    joined=$(printf ',%s' "${ra_items[@]}")
    printf '[%s]' "${joined:1}"
}
