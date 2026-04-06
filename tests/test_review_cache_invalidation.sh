#!/usr/bin/env bash
# Test: stages/review.sh — M61 cache invalidation heuristic across review cycles
# Covers: run_stage_review() file-list comparison at lines 62-69, cycle-1 store at line 83
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

cd "$TMPDIR_BASE"

# Minimal git repo so any git calls don't fail
git init -q .
git config user.email "test@tekhton"
git config user.name "Tekhton Test"
git commit --allow-empty -q -m "init"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$(( PASS + 1 ))
    else
        echo "  FAIL: $desc"
        FAIL=$(( FAIL + 1 ))
    fi
}

# =============================================================================
# Pipeline globals
# =============================================================================

export TEKHTON_HOME PROJECT_DIR="$TMPDIR_BASE"
mkdir -p "${TMPDIR_BASE}/.claude/logs"

export LOG_FILE="${TMPDIR_BASE}/.claude/logs/test.log"
export LOG_DIR="${TMPDIR_BASE}/.claude/logs"
export TIMESTAMP="20260406_120000"
export TEKHTON_SESSION_DIR="${TMPDIR_BASE}/.claude/session"
mkdir -p "$TEKHTON_SESSION_DIR"

export PIPELINE_STATE_FILE="${TMPDIR_BASE}/.claude/PIPELINE_STATE.md"
export TASK="Implement cache layer"

export CLAUDE_REVIEWER_MODEL="claude-test"
export REVIEWER_MAX_TURNS=10
export ADJUSTED_REVIEWER_TURNS=10
export MAX_REVIEW_CYCLES=3
export AGENT_TOOLS_REVIEWER="Read,Glob"
export AGENT_TOOLS_CODER="Read,Write,Edit"
export AGENT_TOOLS_JR_CODER="Read,Write,Edit"
export AGENT_TOOLS_BUILD_FIX="Read,Write,Edit"

export MILESTONE_MODE=false
export REVIEW_SKIP_THRESHOLD=0
export NOTES_FILTER=""
export ARCHITECTURE_FILE="${TMPDIR_BASE}/ARCHITECTURE.md"
export ACTUAL_CODER_TURNS=10

export INDEXER_AVAILABLE=true
export REPO_MAP_ENABLED=true
export REPO_MAP_CONTENT=""

export CODER_MAX_TURNS=50
export JR_CODER_MAX_TURNS=20
export CLAUDE_CODER_MODEL="claude-test"
export CLAUDE_JR_CODER_MODEL="claude-test"

export PIPELINE_STAGE_COUNT=4
export PIPELINE_STAGE_POS=3

# =============================================================================
# Source real libraries
# =============================================================================

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh"

# =============================================================================
# Stub all external functions review.sh calls
# =============================================================================

# Phase timing stubs
_phase_start() { :; }
_phase_end()   { :; }

# General pipeline stubs
log_decision()                  { :; }
progress_status()               { :; }
estimate_post_coder_turns()     { :; }
_get_cached_architecture_content() { echo ""; }
build_context_packet()          { :; }
_add_context_component()        { :; }
log_context_report()            { :; }
render_prompt()                 { echo "mock_${1:-}"; }
print_run_summary()             { :; }
was_null_run()                  { return 1; }
detect_replan_required()        { return 1; }
run_build_gate()                { return 0; }
run_specialist_reviews()        { return 0; }
_route_specialist_rework()      { :; }
_build_resume_flag()            { echo "--resume"; }
write_pipeline_state()          { echo "STAGE=$1|REASON=$2" >> "${TMPDIR_BASE}/state_calls.log"; }

# _STAGE_DURATION and _STAGE_TURNS for the per-cycle recording code
declare -gA _STAGE_DURATION=()
declare -gA _STAGE_TURNS=()

# run_repo_map — default: does nothing (repo map already cached)
run_repo_map() { return 0; }

# get_repo_map_slice — default: returns a stub slice
get_repo_map_slice() { echo "## sliced content"; return 0; }

# =============================================================================
# Key stubs tracked per test
# =============================================================================

INVALIDATE_CALLED=0
invalidate_repo_map_run_cache() {
    INVALIDATE_CALLED=$(( INVALIDATE_CALLED + 1 ))
    echo "INVALIDATE_CALLED" >> "${TMPDIR_BASE}/invalidate_calls.log"
}

# =============================================================================
# Helper: produce REVIEWER_REPORT.md with given verdict
# =============================================================================

make_reviewer_report() {
    local verdict="$1"
    # CWD is TMPDIR_BASE — write directly to cwd so pipeline can find it
    cat > REVIEWER_REPORT.md <<EOF
## Verdict
${verdict}

## Complex Blockers
- None

## Simple Blockers
- None

## Non-Blocking Notes
- None
EOF
}

# =============================================================================
# Helper: reset shared test state
# =============================================================================

reset_test_state() {
    INVALIDATE_CALLED=0
    REVIEW_CYCLE=0
    _REVIEW_MAP_FILES=""
    VERDICT="CHANGES_REQUIRED"
    REPO_MAP_CONTENT=""
    rm -f "${TMPDIR_BASE}/agent_calls.log" \
          "${TMPDIR_BASE}/state_calls.log" \
          "${TMPDIR_BASE}/invalidate_calls.log" \
          REVIEWER_REPORT.md

    AGENT_CALL_COUNT=0
    INDEXER_AVAILABLE=true
    REPO_MAP_ENABLED=true

    # Default: extract_files_from_coder_summary returns same list each cycle
    extract_files_from_coder_summary() { echo "src/cache.sh src/indexer.sh"; }
    run_repo_map()      { return 0; }
    get_repo_map_slice(){ echo "## sliced content"; return 0; }
    was_null_run()      { return 1; }
}

# =============================================================================
# Source the review stage (defines run_stage_review)
# =============================================================================

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/review.sh"

# =============================================================================
# T1: Two cycles, identical basenames — no invalidation on cycle 2
# =============================================================================

echo "=== T1: Identical file list across cycles → no invalidation ==="

reset_test_state

# Cycle 1: CHANGES_REQUIRED → triggers rework loop
# Cycle 2: APPROVED → exits the loop
AGENT_CALL_COUNT=0
run_agent() {
    local _name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    echo "$_name" >> "${TMPDIR_BASE}/agent_calls.log"
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""

    if [[ "$_name" == "Reviewer (cycle 1)" ]]; then
        make_reviewer_report "CHANGES_REQUIRED"
    else
        # Cycle 2 reviewer + any rework calls → approve
        make_reviewer_report "APPROVED_WITH_NOTES"
    fi
}

# Same file list both cycles
extract_files_from_coder_summary() { echo "src/cache.sh src/indexer.sh"; }

run_stage_review

assert "T1: invalidate NOT called (same basenames)" \
    "$([ "$INVALIDATE_CALLED" -eq 0 ] && echo 0 || echo 1)"

assert "T1: _REVIEW_MAP_FILES set after cycle 1" \
    "$([ -n "$_REVIEW_MAP_FILES" ] && echo 0 || echo 1)"

# =============================================================================
# T2: Two cycles, different basenames on cycle 2 → invalidation triggered
# =============================================================================

echo "=== T2: New file in cycle-2 list → invalidation triggered ==="

reset_test_state

CYCLE_COUNT=0
run_agent() {
    local _name="$1"
    CYCLE_COUNT=$(( CYCLE_COUNT + 1 ))
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""

    if [[ "$_name" == "Reviewer (cycle 1)" ]]; then
        make_reviewer_report "CHANGES_REQUIRED"
    else
        make_reviewer_report "APPROVED_WITH_NOTES"
    fi
}

EXTRACT_CALL=0
extract_files_from_coder_summary() {
    EXTRACT_CALL=$(( EXTRACT_CALL + 1 ))
    if [[ "$REVIEW_CYCLE" -le 1 ]]; then
        # Cycle 1 file list
        echo "src/cache.sh src/indexer.sh"
    else
        # Cycle 2: rework added a new file
        echo "src/cache.sh src/indexer.sh src/new_helper.sh"
    fi
}

run_stage_review

assert "T2: invalidate called once when new file detected" \
    "$([ "$INVALIDATE_CALLED" -eq 1 ] && echo 0 || echo 1)"

# =============================================================================
# T3: Single cycle approval — _REVIEW_MAP_FILES set, no invalidation check needed
# =============================================================================

echo "=== T3: Single cycle approval → _REVIEW_MAP_FILES stored, invalidate not triggered ==="

reset_test_state

run_agent() {
    local _name="$1"
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""
    make_reviewer_report "APPROVED"
}

extract_files_from_coder_summary() { echo "src/cache.sh"; }

run_stage_review

assert "T3: _REVIEW_MAP_FILES contains cycle-1 file list" \
    "$(echo "$_REVIEW_MAP_FILES" | grep -q 'cache.sh' && echo 0 || echo 1)"

assert "T3: invalidate NOT called on single-cycle approval" \
    "$([ "$INVALIDATE_CALLED" -eq 0 ] && echo 0 || echo 1)"

# =============================================================================
# T4: Indexer not available → invalidation logic skipped entirely
# =============================================================================

echo "=== T4: INDEXER_AVAILABLE=false → no extract/invalidate calls ==="

reset_test_state
INDEXER_AVAILABLE=false

run_agent() {
    local _name="$1"
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""
    if [[ "$_name" == "Reviewer (cycle 1)" ]]; then
        make_reviewer_report "CHANGES_REQUIRED"
    else
        make_reviewer_report "APPROVED"
    fi
}

EXTRACT_CALLED_T4=0
extract_files_from_coder_summary() {
    EXTRACT_CALLED_T4=$(( EXTRACT_CALLED_T4 + 1 ))
    echo "src/cache.sh"
}

run_stage_review

assert "T4: extract_files_from_coder_summary not called when indexer unavailable" \
    "$([ "$EXTRACT_CALLED_T4" -eq 0 ] && echo 0 || echo 1)"

assert "T4: invalidate_repo_map_run_cache not called" \
    "$([ "$INVALIDATE_CALLED" -eq 0 ] && echo 0 || echo 1)"

INDEXER_AVAILABLE=true  # restore

# =============================================================================
# T5: REPO_MAP_ENABLED=false → invalidation logic skipped
# =============================================================================

echo "=== T5: REPO_MAP_ENABLED=false → no invalidate calls ==="

reset_test_state
REPO_MAP_ENABLED=false

run_agent() {
    local _name="$1"
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""
    if [[ "$_name" == "Reviewer (cycle 1)" ]]; then
        make_reviewer_report "CHANGES_REQUIRED"
    else
        make_reviewer_report "APPROVED"
    fi
}

run_stage_review

assert "T5: invalidate not called when REPO_MAP_ENABLED=false" \
    "$([ "$INVALIDATE_CALLED" -eq 0 ] && echo 0 || echo 1)"

REPO_MAP_ENABLED=true  # restore

# =============================================================================
# T6: Three cycles — invalidation only triggered when basenames actually differ
# =============================================================================

echo "=== T6: Three cycles, new file on cycle 3 only → one invalidation ==="

reset_test_state

CYCLE_COUNT_T6=0
run_agent() {
    local _name="$1"
    CYCLE_COUNT_T6=$(( CYCLE_COUNT_T6 + 1 ))
    export LAST_AGENT_TURNS=5
    export LAST_AGENT_EXIT_CODE=0
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    AGENT_ERROR_MESSAGE=""

    if [[ "$REVIEW_CYCLE" -lt 3 ]]; then
        make_reviewer_report "CHANGES_REQUIRED"
    else
        make_reviewer_report "APPROVED"
    fi
}

extract_files_from_coder_summary() {
    if [[ "$REVIEW_CYCLE" -le 2 ]]; then
        echo "src/cache.sh src/indexer.sh"
    else
        # Cycle 3: a new file was added by rework
        echo "src/cache.sh src/indexer.sh src/extra.sh"
    fi
}

run_stage_review

assert "T6: invalidate called exactly once (cycle 3 new file)" \
    "$([ "$INVALIDATE_CALLED" -eq 1 ] && echo 0 || echo 1)"

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
