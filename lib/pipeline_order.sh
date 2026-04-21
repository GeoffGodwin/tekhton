#!/usr/bin/env bash
# =============================================================================
# pipeline_order.sh — Configurable pipeline stage ordering (Milestone 27)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: get_pipeline_order(), validate_pipeline_order(), get_stage_count(),
#           get_stage_position(), should_run_stage()
#
# Pipeline orders:
#   standard   — Scout → Coder → Security → Review → Test (default)
#   test_first — Scout → Test(write) → Coder → Security → Review → Test(verify)
#   auto       — Reserved for V4 PM agent; falls back to standard with warning
# =============================================================================
set -euo pipefail

# --- Order definitions -------------------------------------------------------
# Each order is a space-separated list of stage names.
# The tester stage appears as "test_write" (TDD: write failing tests) or
# "test_verify" (verify tests pass). In standard order, the single tester
# invocation uses "test_verify" (same behavior as pre-M27).

readonly PIPELINE_ORDER_STANDARD="scout coder security review test_verify"
readonly PIPELINE_ORDER_TEST_FIRST="scout test_write coder security review test_verify"

# --- Validation --------------------------------------------------------------

# NOTE: load_config() in config.sh contains a parallel inline case block that runs before
# this library is sourced. Any new order value must be added to both locations.
# This function is the test-facing validation API; config.sh is the runtime normalizer.

# validate_pipeline_order — Check that a pipeline order string is valid.
# Args: $1 = order string (standard|test_first|auto)
# Returns: 0 if valid, 1 if invalid (prints warning).
validate_pipeline_order() {
    local order="$1"
    case "$order" in
        standard|test_first)
            return 0
            ;;
        auto)
            warn "[pipeline_order] auto mode requires V4 PM agent — using standard."
            return 0
            ;;
        *)
            warn "[pipeline_order] Unknown PIPELINE_ORDER '${order}'. Must be standard|test_first|auto. Using standard."
            return 1
            ;;
    esac
}

# --- Order resolution --------------------------------------------------------

# get_pipeline_order — Echo the stage list for the active pipeline order.
# Reads PIPELINE_ORDER global. Returns space-separated stage names.
# When DOCS_AGENT_ENABLED=true, inserts "docs" between coder and security.
get_pipeline_order() {
    local order="${PIPELINE_ORDER:-standard}"
    local stages
    case "$order" in
        test_first)
            stages="$PIPELINE_ORDER_TEST_FIRST"
            ;;
        *)
            # standard, auto (fallback), or any unrecognized value
            stages="$PIPELINE_ORDER_STANDARD"
            ;;
    esac
    # Conditionally insert docs stage between coder and security
    if [[ "${DOCS_AGENT_ENABLED:-false}" == "true" ]]; then
        stages="${stages/coder security/coder docs security}"
    fi
    echo "$stages"
}

# get_stage_count — Return the number of *visible* stages in the active order.
# Excludes scout, which runs as a sub-step of the coder stage (never displayed).
get_stage_count() {
    local stages count=0
    stages=$(get_pipeline_order)
    # shellcheck disable=SC2086
    for _s in $stages; do
        [[ "$_s" == "scout" ]] && continue
        count=$((count + 1))
    done
    echo "$count"
}

# get_stage_position — Return the 1-based position of a stage in the active order.
# Args: $1 = stage name to find
# Returns: position number via stdout, or 0 if not found.
get_stage_position() {
    local target="$1"
    local stages pos=0
    stages=$(get_pipeline_order)
    # shellcheck disable=SC2086
    for stage in $stages; do
        pos=$((pos + 1))
        if [[ "$stage" == "$target" ]]; then
            echo "$pos"
            return 0
        fi
    done
    echo "0"
    return 1
}

# should_run_stage — Check if a stage should run given the START_AT resume point.
# In standard order, this replicates the existing cascading if/elif logic.
# In test_first order, the stage runs if its position >= START_AT's position.
#
# Args: $1 = stage name to check, $2 = START_AT value
# Returns: 0 if stage should run, 1 if it should be skipped.
should_run_stage() {
    local stage="$1"
    local start_at="$2"

    # Map START_AT values to stage names in the pipeline order.
    # The CLI uses "coder", "security", "review", "test"/"tester" —
    # map these to pipeline order stage names.
    local start_stage
    case "$start_at" in
        coder)    start_stage="coder" ;;
        security) start_stage="security" ;;
        review)   start_stage="review" ;;
        test|tester)
            # In test_first, --start-at test means resume at test_verify (second pass)
            start_stage="test_verify"
            ;;
        intake)   start_stage="scout" ;;  # intake runs before scout; if starting at intake, run everything
        *)        start_stage="scout" ;;  # default: run everything
    esac

    local stage_pos start_pos
    stage_pos=$(get_stage_position "$stage") || stage_pos=0
    start_pos=$(get_stage_position "$start_stage") || start_pos=0

    # Stage runs if it's at or after the start position
    [[ "$stage_pos" -ge "$start_pos" ]]
}

# get_tester_mode — Return the TESTER_MODE for a given stage name.
# Args: $1 = stage name (test_write or test_verify)
# Returns: write_failing or verify_passing via stdout.
get_tester_mode() {
    local stage="$1"
    case "$stage" in
        test_write)    echo "write_failing" ;;
        test_verify|*) echo "verify_passing" ;;
    esac
}

# is_test_first_order — Check if the active pipeline order is test_first.
# Returns: 0 if test_first, 1 otherwise.
is_test_first_order() {
    [[ "${PIPELINE_ORDER:-standard}" == "test_first" ]]
}

# get_display_stage_order — Echo the space-separated display stage labels for
# the TUI stage-pill row. Prepends "intake" when INTAKE_AGENT_ENABLED=true,
# maps internal names (test_verify, test_write) to display labels, and filters
# out stages disabled via runtime skip flags or *_AGENT_ENABLED toggles.
#
# Honors:
#   INTAKE_AGENT_ENABLED  (default true)  — prepends "intake"
#   SECURITY_AGENT_ENABLED (default true) — filters "security"
#   SKIP_SECURITY          (default false) — filters "security"
#   SKIP_DOCS              (default false) — filters "docs"
#   DOCS_AGENT_ENABLED handled inside get_pipeline_order()
#
# Output: space-separated string (no trailing newline beyond echo's).
get_display_stage_order() {
    local stages display=""

    if [[ "${INTAKE_AGENT_ENABLED:-true}" == "true" ]]; then
        display="intake"
    fi

    stages=$(get_pipeline_order)
    local s label
    # shellcheck disable=SC2086
    for s in $stages; do
        case "$s" in
            security)
                if [[ "${SECURITY_AGENT_ENABLED:-true}" != "true" ]] \
                   || [[ "${SKIP_SECURITY:-false}" == "true" ]]; then
                    continue
                fi
                ;;
            docs)
                if [[ "${SKIP_DOCS:-false}" == "true" ]]; then
                    continue
                fi
                ;;
        esac
        # Single canonical label mapping — keeps pill labels in lockstep with
        # tui_stage_begin/end call sites, which also route through
        # get_stage_display_label. A new stage added to the pipeline order is
        # labeled consistently in both paths via the shared registry.
        label=$(get_stage_display_label "$s")
        display="${display:+$display }${label}"
    done

    # wrap-up is always the final pill; it activates during finalize_run().
    display="${display:+$display }wrap-up"

    echo "$display"
}

# get_stage_display_label NAME
# Returns the display label used in the TUI pill bar for a given internal stage name.
# This is the single extension point: add new stage mappings HERE ONLY.
# Both get_display_stage_order() and all tui_stage_begin/end call sites depend on
# this function. When a new stage is added to the pipeline, add its mapping here
# first; the pill bar, timings column, and stage-complete records all update automatically.
get_stage_display_label() {
    case "${1:-}" in
        intake)          echo "intake" ;;
        scout)           echo "scout" ;;
        coder)           echo "coder" ;;
        test_write)      echo "tester-write" ;;
        test_verify)     echo "tester" ;;
        security)        echo "security" ;;
        review)          echo "review" ;;
        docs)            echo "docs" ;;
        rework)          echo "rework" ;;
        wrap_up|wrap-up) echo "wrap-up" ;;
        # Fallback: replace underscores with hyphens. New stages MUST be added
        # above; this catch-all prevents hard failures during development.
        # get_display_stage_order() routes its labels through this function,
        # so pill-row output and tui_stage_begin/end call sites stay aligned
        # even if a new stage only hits the fallback.
        *)               echo "${1//_/-}" ;;
    esac
}

# get_stage_metrics_key NAME
# Canonical key resolver for stage metric / timings lookups (M110).
# Accepts either the internal pipeline name (test_verify, jr_coder, reviewer)
# or the display label (tester, rework, review) and returns the canonical
# display label used as the stable key across metrics, timings, and TUI rows.
# Idempotent: passing a canonical key returns it unchanged.
# Every new stage/alias MUST be added here and in get_stage_display_label.
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

# get_stage_policy NAME
# Return a fixed-shape record "class|pill|timings|active|parent" for a stage.
# class   ∈ pipeline|pre|post|sub|op
# pill    ∈ yes|no|conditional
# timings ∈ yes|no
# active  ∈ yes|no
# parent  ∈ stage display label or "-"
# NAME may be an internal name or a display label; callers should not rely
# on raw field access — use tui_stage_begin/end / planner helpers instead.
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

# _policy_field RECORD INDEX — extract 1-based field from "a|b|c|d|e".
_policy_field() {
    local rec="${1:-}" idx="${2:-1}" IFS='|'
    # shellcheck disable=SC2206
    local parts=($rec)
    echo "${parts[$((idx - 1))]:-}"
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
