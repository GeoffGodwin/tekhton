#!/usr/bin/env bash
# tests/test_clear_commit_skip_sentinels.sh — unit tests for
# _clear_commit_skip_sentinels() in lib/replan_midrun.sh (m46).
#
# _clear_commit_skip_sentinels removes three sentinel files from TEKHTON_DIR
# that cause finalize_commit to silently skip commits in auto-advance chains.
# It must:
#   A — remove .final_check_result, .final_check_reason, .commit_decision
#       when they exist (happy path — the primary observable behavior)
#   B — return 0 even when none of the sentinel files exist
#   C — work with TEKHTON_DIR set to an absolute path (does not prepend PROJECT_DIR)
#   D — work with relative TEKHTON_DIR + PROJECT_DIR set (joins them)
#   E — leave non-sentinel files in the dir untouched
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — $2"; FAIL=$(( FAIL + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# Stub the functions that replan_midrun.sh depends on at source time.
log()               { :; }
warn()              { :; }
error()             { :; }
success()           { :; }
header()            { :; }
write_pipeline_state() { :; }
_safe_read_file()   { cat "$1" 2>/dev/null || true; }
# Stub _call_planning_batch so _run_midrun_replan doesn't exec anything.
_call_planning_batch() { echo "stub"; return 0; }

export TEKHTON_HOME
export PROJECT_DIR="${WORK_DIR}"
export TEKHTON_SESSION_DIR="${WORK_DIR}"
export TEKHTON_TEST_MODE=true
export TASK="test task"
export MILESTONE_MODE=""
export PIPELINE_STATE_FILE="${WORK_DIR}/.claude/PIPELINE_STATE.md"
export LOG_DIR="${WORK_DIR}/.claude/logs"
export REPLAN_MODEL="opus"
export REPLAN_MAX_TURNS="5"

mkdir -p "${WORK_DIR}/.claude" "${WORK_DIR}/.claude/logs"

# Source libs that replan_midrun.sh expects to be pre-sourced.
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true
# Re-stub after common.sh to win over any real implementations.
log()               { :; }
warn()              { :; }
error()             { :; }
success()           { :; }
header()            { :; }

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/state.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/replan_midrun.sh"

# --- A: happy path — all three sentinels removed when present ----------------
TEKHTON_DIR_A="${WORK_DIR}/tekhton_a"
mkdir -p "$TEKHTON_DIR_A"
touch "${TEKHTON_DIR_A}/.final_check_result"
touch "${TEKHTON_DIR_A}/.final_check_reason"
touch "${TEKHTON_DIR_A}/.commit_decision"

set +e
(
    export TEKHTON_DIR="$TEKHTON_DIR_A"
    unset PROJECT_DIR
    _clear_commit_skip_sentinels
)
rc_a=$?
set -e

all_removed=true
for sentinel in .final_check_result .final_check_reason .commit_decision; do
    if [[ -f "${TEKHTON_DIR_A}/${sentinel}" ]]; then
        all_removed=false
        fail "A: ${sentinel} not removed" "file still exists in ${TEKHTON_DIR_A}"
    fi
done

if [[ "$all_removed" == true ]] && [[ "$rc_a" -eq 0 ]]; then
    pass "A: all three sentinel files removed and function returns 0"
fi

# --- B: returns 0 when no sentinel files exist -------------------------------
TEKHTON_DIR_B="${WORK_DIR}/tekhton_b"
mkdir -p "$TEKHTON_DIR_B"
# No sentinel files created.

set +e
(
    export TEKHTON_DIR="$TEKHTON_DIR_B"
    unset PROJECT_DIR
    _clear_commit_skip_sentinels
)
rc_b=$?
set -e

if [[ "$rc_b" -eq 0 ]]; then
    pass "B: returns 0 when sentinel files do not exist"
else
    fail "B: return code" "expected 0, got ${rc_b}"
fi

# --- C: absolute TEKHTON_DIR — PROJECT_DIR is not prepended ------------------
TEKHTON_DIR_C="${WORK_DIR}/abs_tekhton_c"
DECOY_DIR="${WORK_DIR}/decoy_project_c"
mkdir -p "$TEKHTON_DIR_C" "$DECOY_DIR"
touch "${TEKHTON_DIR_C}/.final_check_result"
touch "${TEKHTON_DIR_C}/.commit_decision"
# Also create sentinels under decoy to verify they're NOT touched.
touch "${DECOY_DIR}/${TEKHTON_DIR_C}/.final_check_result" 2>/dev/null || true

set +e
(
    export TEKHTON_DIR="$TEKHTON_DIR_C"
    export PROJECT_DIR="$DECOY_DIR"
    _clear_commit_skip_sentinels
)
rc_c=$?
set -e

if [[ ! -f "${TEKHTON_DIR_C}/.final_check_result" ]] && \
   [[ ! -f "${TEKHTON_DIR_C}/.commit_decision" ]] && \
   [[ "$rc_c" -eq 0 ]]; then
    pass "C: absolute TEKHTON_DIR used directly (PROJECT_DIR not prepended)"
else
    fail "C: absolute TEKHTON_DIR" "rc=${rc_c} sentinels_remain=$(ls "${TEKHTON_DIR_C}"/. 2>/dev/null)"
fi

# --- D: relative TEKHTON_DIR + PROJECT_DIR — path is joined ------------------
REL_DIR="tekhton_d_subdir"
PROJ_DIR_D="${WORK_DIR}/project_d"
FULL_DIR_D="${PROJ_DIR_D}/${REL_DIR}"
mkdir -p "$FULL_DIR_D"
touch "${FULL_DIR_D}/.final_check_result"
touch "${FULL_DIR_D}/.final_check_reason"
touch "${FULL_DIR_D}/.commit_decision"

set +e
(
    export TEKHTON_DIR="$REL_DIR"
    export PROJECT_DIR="$PROJ_DIR_D"
    _clear_commit_skip_sentinels
)
rc_d=$?
set -e

all_d_removed=true
for sentinel in .final_check_result .final_check_reason .commit_decision; do
    if [[ -f "${FULL_DIR_D}/${sentinel}" ]]; then
        all_d_removed=false
        fail "D: ${sentinel} not removed" "still exists in ${FULL_DIR_D}"
    fi
done

if [[ "$all_d_removed" == true ]] && [[ "$rc_d" -eq 0 ]]; then
    pass "D: relative TEKHTON_DIR + PROJECT_DIR joined correctly, sentinels removed"
fi

# --- E: non-sentinel files in the dir are not removed ------------------------
TEKHTON_DIR_E="${WORK_DIR}/tekhton_e"
mkdir -p "$TEKHTON_DIR_E"
touch "${TEKHTON_DIR_E}/.final_check_result"
touch "${TEKHTON_DIR_E}/keep_me.txt"
touch "${TEKHTON_DIR_E}/BUILD_ERRORS.md"

set +e
(
    export TEKHTON_DIR="$TEKHTON_DIR_E"
    unset PROJECT_DIR
    _clear_commit_skip_sentinels
)
set -e

if [[ ! -f "${TEKHTON_DIR_E}/.final_check_result" ]] && \
   [[ -f "${TEKHTON_DIR_E}/keep_me.txt" ]] && \
   [[ -f "${TEKHTON_DIR_E}/BUILD_ERRORS.md" ]]; then
    pass "E: only sentinel files removed; other files untouched"
else
    fail "E: file selectivity" \
        "sentinel=$(ls "${TEKHTON_DIR_E}"/.final_check_result 2>/dev/null && echo exists || echo removed) keep_me=$(ls "${TEKHTON_DIR_E}/keep_me.txt" 2>/dev/null && echo exists || echo missing)"
fi

# --- summary -----------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All _clear_commit_skip_sentinels tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    exit 1
fi
