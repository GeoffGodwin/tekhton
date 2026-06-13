#!/usr/bin/env bash
# tests/test_plan_batch_disk_rescued.sh — unit tests for the _disk_rescued
# fallback path in stages/plan_generate.sh.
#
# The _disk_rescued guard detects when a non-Claude provider (codex, qwen-local)
# writes the output file via the Write tool rather than returning it on stdout.
# In that case _call_planning_batch() returns a text summary (no leading '#'),
# while the actual document already exists on disk with proper markdown content.
# run_plan_generate() must detect this and preserve the on-disk version.
#
# Coverage:
#   I — disk_rescued=true path: mock returns summary text, disk file has full content
#       → CLAUDE.md retains disk content (not the summary)
#   J — stdout path: mock returns '# Heading ...' content, no pre-existing CLAUDE.md
#       → CLAUDE.md written from stdout capture
#   K — disk file present but too short (<= _MIN_SUBSTANTIVE_LINES=20): not rescued
#       → CLAUDE.md overwritten by stdout capture
set -uo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "FAIL: $1 — $2"; FAIL=$(( FAIL + 1 )); }

WORK_DIR=$(mktemp -d)
# shellcheck disable=SC2064
trap "rm -rf '${WORK_DIR}'" EXIT

# ---------------------------------------------------------------------------
# Common stubs — must be declared before sourcing any lib/stage file.
# ---------------------------------------------------------------------------
log_verbose() { :; }
log()         { :; }
warn()        { :; }
error()       { echo "[ERROR] $*" >&2; }
success()     { :; }
header()      { :; }

# count_lines: used with '<' redirect — read stdin and count lines.
count_lines() { wc -l | tr -d ' '; }

# plan_batch.sh shim dependencies.
_shim_resolve_binary() { echo "${WORK_DIR}/tekhton"; return 0; }
_shim_write_request()  { :; }
_shim_field()          { :; }

# plan.sh / render / DAG dependencies.
_assert_design_file_usable() { return 0; }
render_prompt()              { echo "test prompt text"; }
parse_milestones()           { return 1; }  # skip DAG post-processing
migrate_inline_milestones()  { :; }
_insert_milestone_pointer()  { :; }

export TEKHTON_HOME
export TEKHTON_TEST_MODE=true
export TEKHTON_SESSION_DIR="${WORK_DIR}"
export PROJECT_DIR="${WORK_DIR}"
export DESIGN_FILE=".tekhton/DESIGN.md"
export PLAN_GENERATION_MODEL="test-model"
export PLAN_GENERATION_MAX_TURNS="5"
export MILESTONE_DAG_ENABLED="false"

# Source plan_batch.sh for _trim_document_preamble and _plan_batch_emit_tail.
# shellcheck source=../lib/plan_batch.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# Source the stage under test.
# shellcheck source=../stages/plan_generate.sh
source "${TEKHTON_HOME}/stages/plan_generate.sh"

# ---------------------------------------------------------------------------
# Helper: build a valid CLAUDE.md on disk (>20 lines, starts with '# ')
# ---------------------------------------------------------------------------
_make_substantive_claude_md() {
    local path="$1"
    {
        echo "# Project Configuration"
        echo ""
        echo "## Overview"
        echo "This is a test project configuration file."
        echo ""
        echo "## Section A"
        echo "Line 1"
        echo "Line 2"
        echo "Line 3"
        echo "Line 4"
        echo ""
        echo "## Section B"
        echo "Line 5"
        echo "Line 6"
        echo "Line 7"
        echo "Line 8"
        echo ""
        echo "## Section C"
        echo "Line 9"
        echo "Line 10"
        echo "Line 11"
    } > "$path"
}

# ---------------------------------------------------------------------------
# Setup: create required directories and DESIGN.md fixture.
# ---------------------------------------------------------------------------
mkdir -p "${WORK_DIR}/.tekhton" "${WORK_DIR}/.claude/logs"
printf '# Design Doc\n\nSome design content.\n' > "${WORK_DIR}/.tekhton/DESIGN.md"

# ---------------------------------------------------------------------------
# Test I — disk_rescued=true: agent writes via Write tool, not stdout
# ---------------------------------------------------------------------------
# Mock _call_planning_batch to return a summary (non-heading) and exit 0.
_call_planning_batch() {
    printf 'I have written CLAUDE.md for you using the Write tool.'
    return 0
}

# Pre-create a proper CLAUDE.md on disk (what the agent wrote via Write tool).
_make_substantive_claude_md "${WORK_DIR}/CLAUDE.md"
disk_first=$(head -1 "${WORK_DIR}/CLAUDE.md")
disk_lines=$(wc -l < "${WORK_DIR}/CLAUDE.md")

set +e
run_plan_generate >/dev/null 2>&1
rc_i=$?
set -e

final_first=$(head -1 "${WORK_DIR}/CLAUDE.md" 2>/dev/null || echo "")
# grep -c exits 1 on no match but still prints "0"; capture separately to avoid
# the `|| echo "0"` double-zero issue when using set -e.
set +e
final_contains_summary=$(grep -c "I have written CLAUDE.md" "${WORK_DIR}/CLAUDE.md" 2>/dev/null)
set -e

if [[ "$rc_i" -eq 0 ]] \
    && [[ "$final_first" == "# Project Configuration" ]] \
    && [[ "${final_contains_summary:-0}" -eq 0 ]]; then
    pass "I: disk_rescued=true — disk content preserved when stdout is non-heading summary"
else
    fail "I: disk_rescued path" \
        "rc=${rc_i} first_line=$(printf '%q' "$final_first") summary_lines=${final_contains_summary}"
fi

# ---------------------------------------------------------------------------
# Test J — stdout path: agent returns proper heading content, no disk file
# ---------------------------------------------------------------------------
_call_planning_batch() {
    printf '# Generated CLAUDE.md\n\n## Overview\nThis was generated.\n'
    return 0
}

# Remove any pre-existing CLAUDE.md.
rm -f "${WORK_DIR}/CLAUDE.md"

set +e
run_plan_generate >/dev/null 2>&1
rc_j=$?
set -e

final_first_j=$(head -1 "${WORK_DIR}/CLAUDE.md" 2>/dev/null || echo "")
if [[ "$rc_j" -eq 0 ]] && [[ "$final_first_j" == "# Generated CLAUDE.md" ]]; then
    pass "J: stdout path — CLAUDE.md written from agent's heading output"
else
    fail "J: stdout path" \
        "rc=${rc_j} first_line=$(printf '%q' "$final_first_j")"
fi

# ---------------------------------------------------------------------------
# Test K — disk file too short (<= _MIN_SUBSTANTIVE_LINES=20): not rescued
# ---------------------------------------------------------------------------
_call_planning_batch() {
    printf 'I wrote a short CLAUDE.md for you.'
    return 0
}

# Create a CLAUDE.md that starts with '# ' but has only 5 lines (below threshold).
{
    echo "# Short Document"
    echo ""
    echo "Line 1"
    echo "Line 2"
    echo "Line 3"
} > "${WORK_DIR}/CLAUDE.md"

set +e
run_plan_generate >/dev/null 2>&1
rc_k=$?
set -e

# disk_rescued should NOT have triggered (only 5 lines <= 20 threshold).
# The summary text should have been written to CLAUDE.md instead.
final_content_k=$(cat "${WORK_DIR}/CLAUDE.md" 2>/dev/null || echo "")
if [[ "$rc_k" -eq 0 ]] && printf '%s\n' "$final_content_k" | grep -q "I wrote a short CLAUDE.md"; then
    pass "K: short disk file not rescued — stdout content written to CLAUDE.md"
else
    fail "K: short disk file threshold" \
        "rc=${rc_k} content=$(printf '%q' "$final_content_k")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "All _disk_rescued tests passed (${PASS})"
    exit 0
else
    echo "FAIL: ${FAIL} tests failed (${PASS} passed)"
    exit 1
fi
