#!/usr/bin/env bash
# Test: _compute_next_action() — decision table for post-run guidance
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Stubs for config values
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude/milestones" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_AUTO_MIGRATE=true
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
BUILD_ERRORS_FILE="${TMPDIR}/BUILD_ERRORS.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_progress.sh"

cd "$TMPDIR"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$(( PASS + 1 )); }
fail() { echo "  FAIL: $1"; FAIL=$(( FAIL + 1 )); }

# Helper: write manifest
write_manifest() {
    local dir="${TMPDIR}/.claude/milestones"
    mkdir -p "$dir"
    cat > "${dir}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF
    cat >> "${dir}/MANIFEST.cfg"
    _DAG_LOADED=false
    load_manifest 2>/dev/null || true
}

# Helper: reset state
reset_state() {
    _PIPELINE_EXIT_CODE=0
    MILESTONE_MODE=false
    _CACHED_DISPOSITION=""
    _CURRENT_MILESTONE=""
    AGENT_ERROR_CATEGORY=""
    AGENT_ERROR_SUBCATEGORY=""
    VERDICT=""
    rm -f "$BUILD_ERRORS_FILE"
}

# ── Test 1: success + complete + more milestones → next milestone ─────
echo "Test 1: success + complete + more milestones"
write_manifest << 'DATA'
m01|Auth|done||m01.md|
m02|Database|pending||m02.md|
DATA
for f in m01.md m02.md; do echo "# M" > "${TMPDIR}/.claude/milestones/$f"; done

reset_state
_PIPELINE_EXIT_CODE=0
MILESTONE_MODE=true
_CACHED_DISPOSITION="COMPLETE_AND_CONTINUE"
_CURRENT_MILESTONE="1"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q 'tekhton --milestone.*M2.*Database'; then
    pass "Suggests next milestone"
else
    fail "Expected next milestone command: $output"
fi

# ── Test 2: success + complete + none remaining → all complete ────────
echo "Test 2: success + complete + none remaining"
write_manifest << 'DATA'
m01|Auth|done||m01.md|
DATA

reset_state
_PIPELINE_EXIT_CODE=0
MILESTONE_MODE=true
_CACHED_DISPOSITION="COMPLETE_AND_CONTINUE"
_CURRENT_MILESTONE="1"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "All milestones complete"; then
    pass "All milestones complete message"
else
    fail "Expected 'All milestones complete': $output"
fi

# ── Test 3: success + non-milestone → --status suggestion ────────────
echo "Test 3: success + non-milestone"
reset_state
_PIPELINE_EXIT_CODE=0
MILESTONE_MODE=false

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "tekhton --status"; then
    pass "Suggests --status for non-milestone"
else
    fail "Expected --status suggestion: $output"
fi

# ── Test 4: failure + build_gate → build fix command ─────────────────
echo "Test 4: failure + build_gate"
reset_state
_PIPELINE_EXIT_CODE=1
echo "Build failed" > "$BUILD_ERRORS_FILE"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "fix build errors"; then
    pass "Build gate → fix build errors"
else
    fail "Expected 'fix build errors': $output"
fi

# ── Test 5: failure + review_exhaustion → --diagnose ─────────────────
echo "Test 5: failure + review_exhaustion"
reset_state
_PIPELINE_EXIT_CODE=1
VERDICT="CHANGES_REQUIRED"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "tekhton --diagnose"; then
    pass "Review exhaustion → --diagnose"
else
    fail "Expected --diagnose for review exhaustion: $output"
fi

# ── Test 6: failure + api_error/transient → re-run message ──────────
echo "Test 6: failure + API error"
reset_state
_PIPELINE_EXIT_CODE=1
AGENT_ERROR_CATEGORY="UPSTREAM"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "re-run when API is available"; then
    pass "API error → re-run message"
else
    fail "Expected re-run message: $output"
fi

# ── Test 7: failure + stuck/timeout → --diagnose ────────────────────
echo "Test 7: failure + stuck/timeout"
reset_state
_PIPELINE_EXIT_CODE=1
AGENT_ERROR_SUBCATEGORY="activity_timeout"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "tekhton --diagnose.*root cause"; then
    pass "Timeout → --diagnose root cause"
else
    fail "Expected --diagnose for timeout: $output"
fi

# ── Test 7b: failure + null_activity_timeout → quota/auth advice ────
# Zero-turn activity timeout points at upstream (quota/auth/CLI hang),
# not stuck-agent retry loops, so the next-action message must steer
# the user away from a generic --diagnose loop.
echo "Test 7b: failure + null_activity_timeout"
reset_state
_PIPELINE_EXIT_CODE=1
AGENT_ERROR_SUBCATEGORY="null_activity_timeout"

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -qE "quota|claude auth"; then
    pass "null_activity_timeout → quota/auth advice"
else
    fail "Expected quota/auth advice for null_activity_timeout: $output"
fi

# ── Test 8: failure + other → generic --diagnose ────────────────────
echo "Test 8: failure + generic"
reset_state
_PIPELINE_EXIT_CODE=1

output=$(_compute_next_action 2>/dev/null)
if echo "$output" | grep -q "tekhton --diagnose"; then
    pass "Generic failure → --diagnose"
else
    fail "Expected --diagnose for generic failure: $output"
fi

# ── Results ──────────────────────────────────────────────────────────
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
