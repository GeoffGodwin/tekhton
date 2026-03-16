#!/usr/bin/env bash
# Test: Post-clarification null-run detection in stages/coder.sh
#
# Tests the was_null_run() function behavior and verifies that the
# null_run_post_clarification state is written correctly when a coder
# re-run after clarification produces no work.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME
export TEKHTON_SESSION_DIR="$TMPDIR"
export TEKHTON_TEST_MODE="true"

mkdir -p "${TMPDIR}/.claude" "${TMPDIR}/.claude/logs"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stub logging
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_safe_read_file() { cat "$1" 2>/dev/null || true; }
BOLD="" ; NC=""

# Source common.sh and agent.sh for was_null_run
# shellcheck source=../lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true
log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }

# Source agent.sh for was_null_run and LAST_AGENT_NULL_RUN
# We need to stub claude to avoid invocation
claude() { return 1; }
# shellcheck source=../lib/agent.sh
source "${TEKHTON_HOME}/lib/agent.sh"

# Source state.sh for write_pipeline_state
export PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
# shellcheck source=../lib/state.sh
source "${TEKHTON_HOME}/lib/state.sh"

# Source clarify.sh for detect_clarifications
# shellcheck source=../lib/clarify.sh
source "${TEKHTON_HOME}/lib/clarify.sh"

# ============================================================
# Test: was_null_run() when LAST_AGENT_NULL_RUN=false
# ============================================================
echo "=== was_null_run — productive run ==="

LAST_AGENT_NULL_RUN=false
if ! was_null_run; then
    pass "was_null_run returns false (1) for productive run"
else
    fail "was_null_run should return false when LAST_AGENT_NULL_RUN=false"
fi

# ============================================================
# Test: was_null_run() when LAST_AGENT_NULL_RUN=true
# ============================================================
echo "=== was_null_run — null run ==="

LAST_AGENT_NULL_RUN=true
if was_null_run; then
    pass "was_null_run returns true (0) for null run"
else
    fail "was_null_run should return true when LAST_AGENT_NULL_RUN=true"
fi

# ============================================================
# Test: post-clarification null-run path writes correct pipeline state
# ============================================================
echo "=== post-clarification null-run — state written ==="

export TASK="Implement Milestone 4"
export LAST_AGENT_TURNS=1
export LAST_AGENT_EXIT_CODE=0
LAST_AGENT_NULL_RUN=true

# Simulate the null-run detection code path from stages/coder.sh
# (run in a subprocess to safely capture the exit 1)
BASH_EXIT_CODE=0
bash -c '
    export TEKHTON_HOME='"\"$TEKHTON_HOME\""'
    export PROJECT_DIR='"\"$TMPDIR\""'
    export PIPELINE_STATE_FILE='"\"${TMPDIR}/.claude/PIPELINE_STATE.md\""'
    export TASK="Implement Milestone 4"

    log()     { :; }
    success() { :; }
    warn()    { :; }
    error()   { :; }
    header()  { :; }
    source '"\"${TEKHTON_HOME}/lib/common.sh\""' 2>/dev/null || true
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    claude() { return 1; }
    source '"\"${TEKHTON_HOME}/lib/agent.sh\""'
    source '"\"${TEKHTON_HOME}/lib/state.sh\""'

    # Set AFTER sourcing — agent.sh resets LAST_AGENT_NULL_RUN=false at source time
    LAST_AGENT_NULL_RUN=true
    LAST_AGENT_TURNS=1
    LAST_AGENT_EXIT_CODE=0

    if was_null_run; then
        write_pipeline_state \
            "coder" \
            "null_run_post_clarification" \
            "--start-at coder" \
            "$TASK" \
            "Post-clarification coder used ${LAST_AGENT_TURNS} turn(s) and exited ${LAST_AGENT_EXIT_CODE}."
        exit 1
    fi
    exit 0
' 2>/dev/null || BASH_EXIT_CODE=$?

if [[ "$BASH_EXIT_CODE" -eq 1 ]]; then
    pass "Post-clarification null-run path exits with code 1"
else
    fail "Expected exit code 1 from null-run path, got ${BASH_EXIT_CODE}"
fi

if [[ -f "${TMPDIR}/.claude/PIPELINE_STATE.md" ]]; then
    pass "PIPELINE_STATE.md created on post-clarification null run"
else
    fail "PIPELINE_STATE.md should be created on null run"
fi

if grep -q "null_run_post_clarification" "${TMPDIR}/.claude/PIPELINE_STATE.md" 2>/dev/null; then
    pass "State reason is 'null_run_post_clarification'"
else
    fail "State reason should be 'null_run_post_clarification'"
fi

if grep -q "stage.*coder\|coder" "${TMPDIR}/.claude/PIPELINE_STATE.md" 2>/dev/null; then
    pass "State stage is 'coder'"
else
    fail "State stage should be 'coder'"
fi

# ============================================================
# Test: post-clarification productive run does NOT exit 1
# ============================================================
echo "=== post-clarification productive run — does not exit ==="

rm -f "${TMPDIR}/.claude/PIPELINE_STATE.md"

BASH_EXIT_CODE=0
bash -c '
    export TEKHTON_HOME='"\"$TEKHTON_HOME\""'
    export PROJECT_DIR='"\"$TMPDIR\""'
    export PIPELINE_STATE_FILE='"\"${TMPDIR}/.claude/PIPELINE_STATE.md\""'
    export TASK="Implement Milestone 4"

    log()     { :; }
    success() { :; }
    warn()    { :; }
    error()   { :; }
    header()  { :; }
    source '"\"${TEKHTON_HOME}/lib/common.sh\""' 2>/dev/null || true
    log() { :; }; success() { :; }; warn() { :; }; error() { :; }; header() { :; }
    claude() { return 1; }
    source '"\"${TEKHTON_HOME}/lib/agent.sh\""'
    source '"\"${TEKHTON_HOME}/lib/state.sh\""'

    # agent.sh resets LAST_AGENT_NULL_RUN=false at source time — productive run
    LAST_AGENT_NULL_RUN=false

    if was_null_run; then
        write_pipeline_state "coder" "null_run_post_clarification" "--start-at coder" "$TASK" "..."
        exit 1
    fi
    # Productive run: continue
    exit 0
' 2>/dev/null || BASH_EXIT_CODE=$?

if [[ "$BASH_EXIT_CODE" -eq 0 ]]; then
    pass "Productive run exits 0 (no null-run path taken)"
else
    fail "Productive run should exit 0, got ${BASH_EXIT_CODE}"
fi

if [[ ! -f "${TMPDIR}/.claude/PIPELINE_STATE.md" ]]; then
    pass "PIPELINE_STATE.md NOT created for productive post-clarification run"
else
    fail "PIPELINE_STATE.md should NOT be created for productive run"
fi

# ============================================================
# Test: detect_clarifications + blocking file presence drives re-run
# ============================================================
echo "=== clarification + blocking file — re-run condition ==="

BLOCKING_FILE="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
NB_FILE="${TEKHTON_SESSION_DIR}/clarify_nonblocking.txt"
rm -f "$BLOCKING_FILE" "$NB_FILE"

# Simulate CODER_SUMMARY.md with a Clarification Required section
CODER_SUMMARY="${TMPDIR}/CODER_SUMMARY.md"
cat > "$CODER_SUMMARY" << 'EOF'
## Status: COMPLETE
## What Was Implemented
- Feature X

## Clarification Required
- [BLOCKING] Which API version should be targeted?
EOF

# Simulate detect_clarifications finding the blocking item
export CLARIFICATION_ENABLED=true
LAST_AGENT_NULL_RUN=false

if detect_clarifications "$CODER_SUMMARY" 2>/dev/null; then
    pass "detect_clarifications finds blocking item in CODER_SUMMARY.md"
else
    fail "detect_clarifications should find blocking item"
fi

if [[ -s "$BLOCKING_FILE" ]]; then
    pass "Blocking file populated — re-run condition is met"
else
    fail "Blocking file should be populated for re-run"
fi

BLOCKING_COUNT=$(wc -l < "$BLOCKING_FILE" | tr -d '[:space:]')
if [[ "$BLOCKING_COUNT" -eq 1 ]]; then
    pass "One blocking item ready for re-run"
else
    fail "Expected 1 blocking item, got ${BLOCKING_COUNT}"
fi

# ============================================================
# Test: no clarifications — blocking file empty — re-run NOT triggered
# ============================================================
echo "=== no clarifications — re-run not triggered ==="

rm -f "$BLOCKING_FILE" "$NB_FILE"

CODER_SUMMARY_CLEAN="${TMPDIR}/CODER_SUMMARY_clean.md"
cat > "$CODER_SUMMARY_CLEAN" << 'EOF'
## Status: COMPLETE
## What Was Implemented
- Feature X built successfully
EOF

if ! detect_clarifications "$CODER_SUMMARY_CLEAN" 2>/dev/null; then
    pass "No clarifications detected in clean CODER_SUMMARY.md"
else
    fail "Should not detect clarifications in clean summary"
fi

if [[ ! -s "$BLOCKING_FILE" ]]; then
    pass "Blocking file empty — re-run NOT triggered"
else
    fail "Blocking file should be empty when no clarifications"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
