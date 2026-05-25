#!/usr/bin/env bash
# =============================================================================
# pipeline_order_policy.sh — M110 policy, metrics, and plan helpers extracted
# from lib/pipeline_order.sh to keep the parent module under the 300-line
# ceiling.
#
# Sourced by lib/pipeline_order.sh at load time. Do not source directly.
# Provides: get_stage_metrics_key(), get_stage_array_key(), get_stage_policy(),
#           get_run_stage_plan().
#
# All functions are pure: they read env vars and emit strings on stdout.
# Every new stage/alias MUST be added here AND in get_stage_display_label
# (in lib/pipeline_order.sh) to stay consistent across metrics, timings,
# policy records, and the TUI pill row.
# =============================================================================
set -euo pipefail

# get_stage_metrics_key NAME
# Canonical key resolver for stage metric / timings lookups (M110).
# Accepts either the internal pipeline name (test_verify, jr_coder, reviewer)
# or the display label (tester, rework, review) and returns the canonical
# display label used as the stable key across metrics, timings, and TUI rows.
# Idempotent: passing a canonical key returns it unchanged.
get_stage_metrics_key() {
    case "${1:-}" in
        reviewer|review)                       echo "review" ;;
        test_verify|tester|test)               echo "tester" ;;
        test_write|tester-write|tester_write)  echo "tester-write" ;;
        jr_coder|jr-coder|rework)              echo "rework" ;;
        wrap_up|wrap-up)                       echo "wrap-up" ;;
        *)                                     get_stage_display_label "$1" ;;
    esac
}

# get_stage_array_key NAME
# Translate a pipeline dispatch name (the values iterated by
# `for _stage_name in $_pipeline_stages`) into the display-label key
# used by `_STAGE_{STATUS,TURNS,BUDGET,DURATION,START_TS}` associative arrays.
#
# This is intentionally distinct from get_stage_metrics_key:
#   - get_stage_metrics_key returns the display-label convention used by
#     metrics.jsonl and the TUI row labels (review / tester / tester-write).
#   - get_stage_array_key returns the display-label key used by the
#     shell associative arrays populated in tekhton.sh's main loop.
# Idempotent: passing a display label returns it unchanged.
get_stage_array_key() {
    case "${1:-}" in
        review)      echo "review" ;;
        test_verify) echo "tester" ;;
        test_write)  echo "tester-write" ;;
        *)           echo "${1:-}" ;;
    esac
}

# get_stage_policy NAME
# Return a fixed-shape record "class|pill|timings|active|parent" for a stage.
# class   ∈ pipeline|pre|post|sub|op
# pill    ∈ yes|no|conditional
# timings ∈ yes|no
# active  ∈ yes|no
# parent  ∈ stage display label or "-"
# NAME may be an internal name or a display label; callers should not rely
# on raw field access — use `tekhton tui stage-begin/end` or the planner
# helpers instead.
get_stage_policy() {
    local key
    key=$(get_stage_metrics_key "${1:-}")
    case "$key" in
        preflight)              echo "pre|yes|yes|yes|-" ;;
        intake)                 echo "pre|yes|yes|yes|-" ;;
        architect)              echo "pre|conditional|yes|yes|-" ;;
        architect-remediation)  echo "sub|no|yes|yes|architect" ;;
        scout)                  echo "sub|no|yes|yes|coder" ;;
        coder)                  echo "pipeline|yes|yes|yes|-" ;;
        security)               echo "pipeline|yes|yes|yes|-" ;;
        review)                 echo "pipeline|yes|yes|yes|-" ;;
        docs)                   echo "pipeline|yes|yes|yes|-" ;;
        tester)                 echo "pipeline|yes|yes|yes|-" ;;
        tester-write)           echo "pipeline|yes|yes|yes|-" ;;
        rework)                 echo "sub|no|yes|yes|review" ;;
        wrap-up)                echo "post|yes|yes|yes|-" ;;
        *)                      echo "op|no|no|yes|-" ;;
    esac
}

# get_run_stage_plan — Deterministic stage planner (M110).
# Emits a space-separated list of display labels ordered as:
#   preflight? intake? architect? <pipeline stages> wrap-up
# Pre-stages honor their own enabled flags; architect is included only when
# promoted via FORCE_AUDIT or drift thresholds. This feeds _OUT_CTX[stage_order]
# and the TUI bootstrap; per-stage callers must NOT manually patch stage order.
#
# Inputs (env): PREFLIGHT_ENABLED, INTAKE_AGENT_ENABLED, FORCE_AUDIT,
#   DRIFT_OBSERVATION_COUNT, DRIFT_OBSERVATION_THRESHOLD,
#   DRIFT_RUNS_SINCE_AUDIT, DRIFT_RUNS_SINCE_AUDIT_THRESHOLD,
#   SKIP_SECURITY, SECURITY_AGENT_ENABLED, SKIP_DOCS, DOCS_AGENT_ENABLED,
#   PIPELINE_ORDER.
get_run_stage_plan() {
    local out=""
    [[ "${PREFLIGHT_ENABLED:-true}" == "true" ]] && out="preflight"
    if [[ "${INTAKE_AGENT_ENABLED:-true}" == "true" ]]; then
        out="${out:+$out }intake"
    fi
    local _drift_obs="${DRIFT_OBSERVATION_COUNT:-0}"
    local _drift_thr="${DRIFT_OBSERVATION_THRESHOLD:-8}"
    local _runs_since="${DRIFT_RUNS_SINCE_AUDIT:-0}"
    local _runs_thr="${DRIFT_RUNS_SINCE_AUDIT_THRESHOLD:-5}"
    if [[ "${FORCE_AUDIT:-false}" == "true" ]] \
       || (( _drift_obs >= _drift_thr )) \
       || (( _runs_since >= _runs_thr )); then
        out="${out:+$out }architect"
    fi
    local stages s label
    stages=$(get_pipeline_order)
    # shellcheck disable=SC2086
    for s in $stages; do
        case "$s" in
            scout) continue ;;
            security)
                [[ "${SECURITY_AGENT_ENABLED:-true}" != "true" ]] && continue
                [[ "${SKIP_SECURITY:-false}" == "true" ]] && continue
                ;;
            docs)
                [[ "${SKIP_DOCS:-false}" == "true" ]] && continue
                ;;
        esac
        label=$(get_stage_display_label "$s")
        out="${out:+$out }${label}"
    done
    out="${out:+$out }wrap-up"
    echo "$out"
}
