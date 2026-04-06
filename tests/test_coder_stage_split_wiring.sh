#!/usr/bin/env bash
# Test: Integration wiring for coder.sh pre-flight sizing gate and null-run auto-split
# Covers: stages/coder.sh lines 78-127 (pre-flight), 326-345 (null-run), 457-471 (turn-limit minimal)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

cd "$TMPDIR_BASE"

# Initialise a minimal git repo so git commands in coder.sh don't fail
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
# Global pipeline defaults (coder.sh reads these)
# =============================================================================

export TEKHTON_HOME PROJECT_DIR="$TMPDIR_BASE"
mkdir -p "${TMPDIR_BASE}/.claude/logs"

export LOG_FILE="${TMPDIR_BASE}/.claude/logs/test.log"
export LOG_DIR="${TMPDIR_BASE}/.claude/logs"
export TIMESTAMP="20260101_000000"
export TEKHTON_SESSION_DIR="${TMPDIR_BASE}/.claude/session"
mkdir -p "$TEKHTON_SESSION_DIR"

export PIPELINE_STATE_FILE="${TMPDIR_BASE}/.claude/PIPELINE_STATE.md"
export MILESTONE_STATE_FILE="${TMPDIR_BASE}/.claude/MILESTONE_STATE.md"
export MILESTONE_ARCHIVE_FILE="${TMPDIR_BASE}/MILESTONE_ARCHIVE.md"

export NOTES_FILTER="FEAT"
export HUMAN_NOTE_COUNT=0
export DYNAMIC_TURNS_ENABLED=true   # causes SHOULD_SCOUT=true

export ARCHITECTURE_FILE="${TMPDIR_BASE}/ARCHITECTURE.md"
export GLOSSARY_FILE=""
export PROJECT_RULES_FILE="${TMPDIR_BASE}/CLAUDE.md"
export DESIGN_FILE=""

export CLAUDE_SCOUT_MODEL="claude-test"
export CLAUDE_CODER_MODEL="claude-test"
export SCOUT_MAX_TURNS=5
export CODER_MAX_TURNS=50
export ADJUSTED_CODER_TURNS=50
export CODER_MAX_TURNS_CAP=200
export AGENT_TOOLS_SCOUT="Read,Glob"
export AGENT_TOOLS_CODER="Read,Write,Edit"
export AGENT_TOOLS_BUILD_FIX="Read,Write,Edit"

export MILESTONE_MODE=true
export MILESTONE_SPLIT_ENABLED=true
export MILESTONE_SPLIT_THRESHOLD_PCT=120
export MILESTONE_SPLIT_MAX_TURNS=15
export MILESTONE_AUTO_RETRY=true
export MILESTONE_MAX_SPLIT_DEPTH=3

export TEST_CMD=""
export ANALYZE_CMD=""
export START_AT="coder"
export NON_BLOCKING_INJECTION_THRESHOLD=99
export TASK="Implement Milestone 5: Big Milestone"
export _CURRENT_MILESTONE="5"

# =============================================================================
# Source real libraries
# =============================================================================

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate before sourcing milestones.sh (it expects it declared)
run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_split.sh"

# Stub _phase_start/_phase_end before sourcing context_cache.sh
if ! declare -f _phase_start &>/dev/null; then
    _phase_start() { :; }
    _phase_end() { :; }
fi

# =============================================================================
# Stub all functions coder.sh calls (defaults — overridden per test)
# =============================================================================

log_decision()              { :; }
progress_status()           { :; }
invalidate_repo_map_run_cache() { :; }  # M61: stub for run cache invalidation
extract_human_notes()       { echo ""; }
claim_human_notes()         { true; }
resolve_human_notes()       { true; }
count_open_nonblocking_notes() { echo "0"; }
get_open_nonblocking_notes()   { echo ""; }
load_clarifications_content()  { export CLARIFICATIONS_CONTENT=""; }
build_context_packet()      { true; }
_add_context_component()    { true; }
log_context_report()        { true; }
detect_clarifications()     { return 1; }
render_prompt()             { echo "mock_prompt_${1:-}"; }
print_run_summary()         { true; }
apply_scout_turn_limits()   { export SCOUT_REC_CODER_TURNS=30; }
run_completion_gate()       { return 0; }
run_repo_map()              { return 1; }
extract_files_from_coder_summary() { echo ""; }
is_substantive_work()       { return 1; }

# _safe_read_file FILE LABEL — return empty content
_safe_read_file()           { echo ""; }

# _wrap_file_content LABEL CONTENT — return content unchanged
_wrap_file_content()        { echo "${2:-}"; }

# Source context cache (M47 — needed by coder.sh)
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/context_cache.sh"

# write_pipeline_state STAGE REASON RESUME TASK NOTES
write_pipeline_state() {
    echo "STAGE=$1|REASON=$2" >> "${TMPDIR_BASE}/state_calls.log"
}

# was_null_run — default: not a null run
was_null_run() { return 1; }

# run_agent NAME MODEL TURNS PROMPT LOG TOOLS
# Default: sets LAST_AGENT_TURNS=10, LAST_AGENT_EXIT_CODE=0
# Creates SCOUT_REPORT.md for scout calls, CODER_SUMMARY.md for coder calls
AGENT_CALL_COUNT=0
run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    echo "$agent_name" >> "${TMPDIR_BASE}/agent_calls.log"
    export LAST_AGENT_TURNS=10
    export LAST_AGENT_EXIT_CODE=0

    case "$agent_name" in
        Scout*)
            echo "## Complexity: Low" > SCOUT_REPORT.md
            ;;
        Coder*)
            printf "## Status: COMPLETE\n- item 1\n- item 2\n- item 3\n- item 4\n" > CODER_SUMMARY.md
            ;;
    esac
}

# =============================================================================
# Source the coder stage (defines run_stage_coder)
# =============================================================================

source "${TEKHTON_HOME}/stages/coder.sh"

# Wrap run_stage_coder with a recursion guard that records state at recursive call
declare -f run_stage_coder | sed '1s/run_stage_coder/_base_run_stage_coder/' \
    > "${TMPDIR_BASE}/base_coder_fn.sh"
# shellcheck source=/dev/null
source "${TMPDIR_BASE}/base_coder_fn.sh"

run_stage_coder() {
    if [[ -f "${TMPDIR_BASE}/recursion_stop" ]]; then
        # Record what state the recursive call sees
        echo "_CURRENT_MILESTONE=${_CURRENT_MILESTONE}" >> "${TMPDIR_BASE}/recursive_state.txt"
        echo "TASK=${TASK}" >> "${TMPDIR_BASE}/recursive_state.txt"
        return 0
    fi
    touch "${TMPDIR_BASE}/recursion_stop"
    _base_run_stage_coder "$@"
    rm -f "${TMPDIR_BASE}/recursion_stop"
}

# =============================================================================
# Helper: reset shared test state between tests
# =============================================================================
reset_test_state() {
    rm -f SCOUT_REPORT.md CODER_SUMMARY.md CLAUDE.md \
        "${TMPDIR_BASE}/agent_calls.log" \
        "${TMPDIR_BASE}/state_calls.log" \
        "${TMPDIR_BASE}/recursive_state.txt" \
        "${TMPDIR_BASE}/recursion_stop"

    AGENT_CALL_COUNT=0
    TASK="Implement Milestone 5: Big Milestone"
    export _CURRENT_MILESTONE="5"
    export LAST_AGENT_TURNS=10
    export LAST_AGENT_EXIT_CODE=0
    export SCOUT_REC_CODER_TURNS=30
    export MILESTONE_SPLIT_ENABLED=true
    export MILESTONE_AUTO_RETRY=true
    export MILESTONE_MAX_SPLIT_DEPTH=3
    export MILESTONE_MODE=true
    export ADJUSTED_CODER_TURNS=50

    # Restore default stubs
    run_agent() {
        local agent_name="$1"
        AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
        echo "$agent_name" >> "${TMPDIR_BASE}/agent_calls.log"
        export LAST_AGENT_TURNS=10
        export LAST_AGENT_EXIT_CODE=0
        case "$agent_name" in
            Scout*)  echo "## Complexity: Low" > SCOUT_REPORT.md ;;
            Coder*)  printf "## Status: COMPLETE\n- item 1\n- item 2\n- item 3\n- item 4\n" > CODER_SUMMARY.md ;;
        esac
    }
    was_null_run() { return 1; }
    run_completion_gate() { return 0; }
    apply_scout_turn_limits() { export SCOUT_REC_CODER_TURNS=30; }
    split_milestone() { return 1; }
    handle_null_run_split() { return 1; }
    write_pipeline_state() {
        echo "STAGE=$1|REASON=$2" >> "${TMPDIR_BASE}/state_calls.log"
    }
}

# Pre-load split_milestone and handle_null_run_split as stubs (real versions need _call_planning_batch)
split_milestone()       { return 1; }
handle_null_run_split() { return 1; }

echo "=== Pre-flight sizing gate ==="

# --------------------------------------------------------------------------
# T1: Oversized milestone — split succeeds → task and current milestone updated
# --------------------------------------------------------------------------
reset_test_state

# Make a CLAUDE.md with sub-milestones so get_milestone_title works
cat > CLAUDE.md <<'MDEOF'
#### Milestone 5.1: First Sub-milestone
Small scoped work.

Acceptance criteria:
- Files exist
MDEOF

# Stub check_milestone_size to return 1 (oversized)
check_milestone_size() { return 1; }

# Stub split_milestone to succeed (sub-milestones already in CLAUDE.md above)
split_milestone() {
    echo "SPLIT_CALLED" >> "${TMPDIR_BASE}/agent_calls.log"
    return 0
}

run_stage_coder

# Pre-flight path updates globals directly (no recursive coder call — just continues)
assert "T1: split fires → _CURRENT_MILESTONE updated to 5.1" \
    "$([ "${_CURRENT_MILESTONE}" = "5.1" ] && echo 0 || echo 1)"

assert "T1: split fires → TASK references 5.1" \
    "$(echo "$TASK" | grep -q '5\.1' && echo 0 || echo 1)"

assert "T1: split_milestone was called" \
    "$(grep -c 'SPLIT_CALLED' "${TMPDIR_BASE}/agent_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

assert "T1: re-scout ran (second Scout call)" \
    "$(grep -c 'Scout (post-split)' "${TMPDIR_BASE}/agent_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T2: Oversized milestone — split fails → original scope preserved
# --------------------------------------------------------------------------
reset_test_state

check_milestone_size() { return 1; }
# split_milestone already stubbed to return 1 by reset_test_state

TASK="Implement Milestone 5: Big Milestone"
export _CURRENT_MILESTONE="5"

run_stage_coder

assert "T2: split fails → _CURRENT_MILESTONE stays 5" \
    "$([ "${_CURRENT_MILESTONE}" = "5" ] && echo 0 || echo 1)"

assert "T2: split fails → TASK unchanged" \
    "$([ "${TASK}" = "Implement Milestone 5: Big Milestone" ] && echo 0 || echo 1)"

assert "T2: no recursive coder call" \
    "$([ ! -f "${TMPDIR_BASE}/recursive_state.txt" ] && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T3: Within-cap estimate → no split attempt (check_milestone_size returns 0)
# --------------------------------------------------------------------------
reset_test_state

# Use real check_milestone_size with estimate below threshold
# ADJUSTED_CODER_TURNS=50, threshold_pct=120 → threshold=60. Estimate=30 → fits
apply_scout_turn_limits() { export SCOUT_REC_CODER_TURNS=30; }

SPLIT_CALLED_T3=false
split_milestone() {
    SPLIT_CALLED_T3=true
    return 1
}

# Restore real check_milestone_size
unset -f check_milestone_size
source "${TEKHTON_HOME}/lib/milestone_split.sh"  # re-source to get real check_milestone_size
# Also re-stub handle_null_run_split after re-source
handle_null_run_split() { return 1; }

run_stage_coder

assert "T3: estimate within cap → split NOT called" \
    "$([ "$SPLIT_CALLED_T3" = false ] && echo 0 || echo 1)"

echo ""
echo "=== Null-run auto-split ==="

# --------------------------------------------------------------------------
# T4: Null-run + milestone mode + split succeeds → recursive coder call
# --------------------------------------------------------------------------
reset_test_state
check_milestone_size() { return 0; }  # not oversized — skip pre-flight

cat > CLAUDE.md <<'MDEOF'
#### Milestone 5.1: First Sub-milestone
Reduced scope.

Acceptance criteria:
- Files exist
MDEOF

was_null_run() { return 0; }   # IS a null run

handle_null_run_split() {
    echo "NULL_RUN_SPLIT_CALLED" >> "${TMPDIR_BASE}/agent_calls.log"
    # Simulate split: update CLAUDE.md (already done above)
    return 0
}

run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    echo "$agent_name" >> "${TMPDIR_BASE}/agent_calls.log"
    export LAST_AGENT_TURNS=0    # coder does 0 turns → null run
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
    esac
    # No CODER_SUMMARY.md — it's a null run
}

run_stage_coder

assert "T4: null-run split called" \
    "$(grep -c 'NULL_RUN_SPLIT_CALLED' "${TMPDIR_BASE}/agent_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

assert "T4: recursive coder call fired" \
    "$([ -f "${TMPDIR_BASE}/recursive_state.txt" ] && echo 0 || echo 1)"

assert "T4: recursive call sees _CURRENT_MILESTONE=5.1" \
    "$(grep -c '_CURRENT_MILESTONE=5.1' "${TMPDIR_BASE}/recursive_state.txt" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T5: Null-run + milestone mode + split fails → saves state, exits
# --------------------------------------------------------------------------
reset_test_state
check_milestone_size() { return 0; }

was_null_run() { return 0; }
handle_null_run_split() { return 1; }   # split fails

# Coder produces nothing
run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    echo "$agent_name" >> "${TMPDIR_BASE}/agent_calls.log"
    export LAST_AGENT_TURNS=0
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
    esac
}

# Run in subshell to catch exit 1
_exit_code=0
( run_stage_coder ) > /dev/null 2>&1 || _exit_code=$?

assert "T5: null-run, split fails → exits with code 1" \
    "$([ "$_exit_code" -eq 1 ] && echo 0 || echo 1)"

assert "T5: state written with null_run reason" \
    "$(grep -c 'REASON=null_run' "${TMPDIR_BASE}/state_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

assert "T5: no recursive coder call" \
    "$([ ! -f "${TMPDIR_BASE}/recursive_state.txt" ] && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T6: Null-run + NON-milestone mode → exits, no split attempted
# --------------------------------------------------------------------------
reset_test_state
export MILESTONE_MODE=false

was_null_run() { return 0; }
SPLIT_CALLED_T6=false
handle_null_run_split() { SPLIT_CALLED_T6=true; return 0; }

run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    export LAST_AGENT_TURNS=0
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
    esac
}

_exit_code=0
( run_stage_coder ) > /dev/null 2>&1 || _exit_code=$?

assert "T6: non-milestone null-run → exits with code 1" \
    "$([ "$_exit_code" -eq 1 ] && echo 0 || echo 1)"

assert "T6: split NOT attempted in non-milestone mode" \
    "$([ "$SPLIT_CALLED_T6" = false ] && echo 0 || echo 1)"

export MILESTONE_MODE=true  # restore

echo ""
echo "=== Turn-limit minimal output branch (lines 457-471) ==="

# --------------------------------------------------------------------------
# T7: Turn-limit + minimal output + milestone mode + split succeeds → recursive call
# --------------------------------------------------------------------------
reset_test_state
check_milestone_size() { return 0; }
was_null_run() { return 1; }  # NOT null run — turn limit scenario

cat > CLAUDE.md <<'MDEOF'
#### Milestone 5.1: First Sub-milestone
Reduced scope.

Acceptance criteria:
- Files exist
MDEOF

# Coder produces IN PROGRESS summary with <= 3 bullet lines
run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    echo "$agent_name" >> "${TMPDIR_BASE}/agent_calls.log"
    export LAST_AGENT_TURNS=50
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
        Coder*) printf "## Status: IN PROGRESS\n- one item\n" > CODER_SUMMARY.md ;;
    esac
}

handle_null_run_split() {
    echo "TURN_LIMIT_SPLIT_CALLED" >> "${TMPDIR_BASE}/agent_calls.log"
    return 0
}

# Need git to be clean so IMPLEMENTED_LINES check runs (no git diff output)
# (TMPDIR_BASE is not a git repo, so git diff will fail — stub it away)
# The code checks: [ "$IMPLEMENTED_LINES" -gt 3 ] where IMPLEMENTED_LINES is line count from grep -c "^- "
# CODER_SUMMARY.md has 1 bullet → IMPLEMENTED_LINES=1 → goes to auto-split branch

run_stage_coder

assert "T7: turn-limit minimal → handle_null_run_split called" \
    "$(grep -c 'TURN_LIMIT_SPLIT_CALLED' "${TMPDIR_BASE}/agent_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

assert "T7: turn-limit minimal → recursive coder call" \
    "$([ -f "${TMPDIR_BASE}/recursive_state.txt" ] && echo 0 || echo 1)"

assert "T7: recursive call sees _CURRENT_MILESTONE=5.1" \
    "$(grep -c '_CURRENT_MILESTONE=5.1' "${TMPDIR_BASE}/recursive_state.txt" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T8: Turn-limit + substantial output (>3 lines) → saves state for resume, no split
# --------------------------------------------------------------------------
reset_test_state
check_milestone_size() { return 0; }
was_null_run() { return 1; }

# Coder produces IN PROGRESS with many bullet lines (substantive work)
run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    export LAST_AGENT_TURNS=50
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
        Coder*)
            printf "## Status: IN PROGRESS\n" > CODER_SUMMARY.md
            for i in 1 2 3 4 5; do
                echo "- item $i" >> CODER_SUMMARY.md
            done
            ;;
    esac
}

SPLIT_CALLED_T8=false
handle_null_run_split() { SPLIT_CALLED_T8=true; return 0; }

_exit_code=0
( run_stage_coder ) > /dev/null 2>&1 || _exit_code=$?

assert "T8: substantial turn-limit → exits with code 1 (state save)" \
    "$([ "$_exit_code" -eq 1 ] && echo 0 || echo 1)"

assert "T8: substantial turn-limit → split NOT attempted (>3 summary lines)" \
    "$([ "$SPLIT_CALLED_T8" = false ] && echo 0 || echo 1)"

assert "T8: state written with turn_limit reason" \
    "$(grep -c 'REASON=turn_limit' "${TMPDIR_BASE}/state_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

# --------------------------------------------------------------------------
# T9: Turn-limit + minimal + milestone + split fails → state saved, exits
# --------------------------------------------------------------------------
reset_test_state
check_milestone_size() { return 0; }
was_null_run() { return 1; }

run_agent() {
    local agent_name="$1"
    AGENT_CALL_COUNT=$(( AGENT_CALL_COUNT + 1 ))
    export LAST_AGENT_TURNS=50
    export LAST_AGENT_EXIT_CODE=0
    case "$agent_name" in
        Scout*) echo "## Complexity: Low" > SCOUT_REPORT.md ;;
        Coder*) printf "## Status: IN PROGRESS\n- one item\n" > CODER_SUMMARY.md ;;
    esac
}

handle_null_run_split() { return 1; }   # split fails

_exit_code=0
( run_stage_coder ) > /dev/null 2>&1 || _exit_code=$?

assert "T9: turn-limit minimal, split fails → exits with code 1" \
    "$([ "$_exit_code" -eq 1 ] && echo 0 || echo 1)"

assert "T9: state saved with turn_limit reason" \
    "$(grep -c 'REASON=turn_limit' "${TMPDIR_BASE}/state_calls.log" 2>/dev/null | grep -q '[^0]' && echo 0 || echo 1)"

assert "T9: no recursive coder call" \
    "$([ ! -f "${TMPDIR_BASE}/recursive_state.txt" ] && echo 0 || echo 1)"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[ "$FAIL" -eq 0 ]
