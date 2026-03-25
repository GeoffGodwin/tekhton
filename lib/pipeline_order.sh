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
get_pipeline_order() {
    local order="${PIPELINE_ORDER:-standard}"
    case "$order" in
        test_first)
            echo "$PIPELINE_ORDER_TEST_FIRST"
            ;;
        *)
            # standard, auto (fallback), or any unrecognized value
            echo "$PIPELINE_ORDER_STANDARD"
            ;;
    esac
}

# get_stage_count — Return the number of stages in the active order.
get_stage_count() {
    local stages
    stages=$(get_pipeline_order)
    # shellcheck disable=SC2086
    set -- $stages
    echo "$#"
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
