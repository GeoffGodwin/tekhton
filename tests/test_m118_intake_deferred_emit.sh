#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m118_intake_deferred_emit.sh — M118 deferred emit pattern for intake
#
# Verifies that run_stage_intake() sets _INTAKE_PASS_EMIT="true" (not calls
# success()) on the actual PASS verdict path, and leaves _INTAKE_PASS_EMIT
# unset on the early-exit paths (disabled, HUMAN_MODE, empty content).
#
# Milestone 118: Preflight / Intake Success-Line Timing Fix
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export TEKHTON_SESSION_DIR="${TMPDIR_TEST}/session"
mkdir -p "$TEKHTON_SESSION_DIR"

export PROJECT_DIR="${TMPDIR_TEST}/project"
mkdir -p "$PROJECT_DIR/.tekhton"

# --- Minimal stubs for functions called by run_stage_intake ---
log()     { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
emit_event() { :; }
_safe_read_file() { :; }
read_index_summary() { :; }
emit_dashboard_run_state() { :; }

# Stub run_agent as a no-op — the INTAKE_REPORT_FILE fixture is pre-created.
run_agent() { :; }

# render_prompt returns a minimal non-empty prompt string.
render_prompt() { echo "fake prompt for: ${1:-}"; }

# --- Required pipeline globals ---
export MILESTONE_MODE=false
export _CURRENT_MILESTONE=""
export MILESTONE_DAG_ENABLED=false
export TASK="Implement feature X with thorough acceptance criteria"
export CAUSAL_LOG_ENABLED=false
export HEALTH_ENABLED=false
export INTAKE_AGENT_ENABLED=true
export HUMAN_MODE=false
export INTAKE_CACHED=false
export CLAUDE_INTAKE_MODEL="claude-test-model"
export INTAKE_MAX_TURNS=5
export INTAKE_CLARITY_THRESHOLD=40
export LOG_FILE=/dev/null
export HUMAN_NOTES_FILE="${TMPDIR_TEST}/nonexistent_notes.md"
export PROJECT_INDEX_FILE=".tekhton/PROJECT_INDEX.md"
export INTAKE_ROLE_FILE=".claude/agents/intake.md"
export TEKHTON_DIR=".tekhton"
export UI_PROJECT_DETECTED=false
export UI_FRAMEWORK=""

# Source intake helpers (provides _intake_content_hash, _intake_parse_verdict, etc.)
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/intake_helpers.sh"

# Source the stage under test
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/intake.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a fixture INTAKE_REPORT_FILE with the given verdict.
_make_intake_report() {
    local verdict="$1"
    local confidence="${2:-95}"
    local report_file="${TMPDIR_TEST}/intake_report.md"
    cat > "$report_file" <<EOF
# Intake Report

## Verdict
${verdict}

## Confidence
${confidence}

## Reasoning
Test fixture verdict.
EOF
    echo "$report_file"
}

# Reset the intake content hash so _intake_should_skip returns false.
_reset_intake_hash() {
    rm -f "${TEKHTON_SESSION_DIR}/intake_content_hash"
}

# =============================================================================
# Test 1: PASS verdict sets _INTAKE_PASS_EMIT="true"
# =============================================================================

echo "=== PASS verdict: _INTAKE_PASS_EMIT is set to 'true' ==="

_reset_intake_hash
export INTAKE_REPORT_FILE
INTAKE_REPORT_FILE=$(_make_intake_report PASS)
unset _INTAKE_PASS_EMIT 2>/dev/null || true

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" == "true" ]]; then
    pass
else
    fail "PASS verdict should set _INTAKE_PASS_EMIT='true' (got: '${_INTAKE_PASS_EMIT:-}')"
fi

# =============================================================================
# Test 2: PASS verdict does NOT call success() directly
# =============================================================================

echo "=== PASS verdict: success() not called inside run_stage_intake ==="

_reset_intake_hash
export INTAKE_REPORT_FILE
INTAKE_REPORT_FILE=$(_make_intake_report PASS)
unset _INTAKE_PASS_EMIT 2>/dev/null || true

_M118_SUCCESS_CALLED=""
success() { _M118_SUCCESS_CALLED="true"; }

run_stage_intake

if [[ "${_M118_SUCCESS_CALLED:-}" != "true" ]]; then
    pass
else
    fail "run_stage_intake should NOT call success() on PASS verdict (M118: caller emits after tui_stage_end)"
fi

# Restore success stub
success() { :; }
unset _M118_SUCCESS_CALLED

# =============================================================================
# Test 3: INTAKE_AGENT_ENABLED=false leaves _INTAKE_PASS_EMIT unset
# =============================================================================

echo "=== INTAKE_AGENT_ENABLED=false: _INTAKE_PASS_EMIT stays unset ==="

export INTAKE_AGENT_ENABLED=false
unset _INTAKE_PASS_EMIT 2>/dev/null || true

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" != "true" ]]; then
    pass
else
    fail "Disabled intake should NOT set _INTAKE_PASS_EMIT (got: '${_INTAKE_PASS_EMIT:-}')"
fi

export INTAKE_AGENT_ENABLED=true

# =============================================================================
# Test 4: HUMAN_MODE=true leaves _INTAKE_PASS_EMIT unset
# =============================================================================

echo "=== HUMAN_MODE=true: _INTAKE_PASS_EMIT stays unset ==="

export HUMAN_MODE=true
unset _INTAKE_PASS_EMIT 2>/dev/null || true

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" != "true" ]]; then
    pass
else
    fail "HUMAN_MODE path should NOT set _INTAKE_PASS_EMIT (got: '${_INTAKE_PASS_EMIT:-}')"
fi

export HUMAN_MODE=false

# =============================================================================
# Test 5: Empty content leaves _INTAKE_PASS_EMIT unset
# =============================================================================

echo "=== Empty content: _INTAKE_PASS_EMIT stays unset ==="

# Override _intake_get_milestone_content to return empty
_intake_get_milestone_content() { echo ""; }

_reset_intake_hash
unset _INTAKE_PASS_EMIT 2>/dev/null || true

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" != "true" ]]; then
    pass
else
    fail "Empty-content path should NOT set _INTAKE_PASS_EMIT (got: '${_INTAKE_PASS_EMIT:-}')"
fi

# Restore the real _intake_get_milestone_content from intake_helpers.sh
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/intake_helpers.sh"

# =============================================================================
# Test 6: INTAKE_CACHED=true with a report present uses cached results and
#         does NOT set _INTAKE_PASS_EMIT (cached PASS was silent pre-M118,
#         and the cached path does not set the flag).
# =============================================================================

echo "=== INTAKE_CACHED=true: _INTAKE_PASS_EMIT stays unset (silent cached path) ==="

export INTAKE_CACHED=true
export INTAKE_REPORT_FILE
INTAKE_REPORT_FILE=$(_make_intake_report PASS)
unset _INTAKE_PASS_EMIT 2>/dev/null || true

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" != "true" ]]; then
    pass
else
    fail "Cached PASS path should NOT set _INTAKE_PASS_EMIT (cached was silent pre-M118; got: '${_INTAKE_PASS_EMIT:-}')"
fi

export INTAKE_CACHED=false

# =============================================================================
# Test 7: Non-PASS verdict (NEEDS_CLARITY stub) does NOT set _INTAKE_PASS_EMIT
# =============================================================================

echo "=== Non-PASS verdict: _INTAKE_PASS_EMIT stays unset ==="

_reset_intake_hash
export INTAKE_REPORT_FILE
INTAKE_REPORT_FILE=$(_make_intake_report NEEDS_CLARITY)
unset _INTAKE_PASS_EMIT 2>/dev/null || true

# Stub _intake_handle_needs_clarity to avoid interactive/exit behavior.
_intake_handle_needs_clarity() { :; }

run_stage_intake

if [[ "${_INTAKE_PASS_EMIT:-}" != "true" ]]; then
    pass
else
    fail "NEEDS_CLARITY verdict should NOT set _INTAKE_PASS_EMIT (got: '${_INTAKE_PASS_EMIT:-}')"
fi

# =============================================================================
# Results
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
