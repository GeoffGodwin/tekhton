#!/usr/bin/env bash
# Test: Watchtower dashboard integration — file copy, verbosity filters, refresh_interval_ms
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

PASS=0
FAIL=0

assert() {
    local label="$1"
    shift
    if "$@" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        FAIL=$((FAIL + 1))
    fi
}

assert_not() {
    local label="$1"
    shift
    if ! "$@" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label}"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1"
    local file="$2"
    local pattern="$3"
    if grep -q "$pattern" "$file" 2>/dev/null; then
        PASS=$((PASS + 1))
    else
        echo "  FAIL: ${label} (pattern '${pattern}' not found in ${file})"
        FAIL=$((FAIL + 1))
    fi
}

# common.sh hosts _json_escape after m02; causality.sh delegates writer logic
# to the Go binary. dashboard.sh and dashboard_parsers.sh need _json_escape
# available, so common.sh must be sourced before dashboard.sh.

# Minimal stubs so sourcing doesn't fail
declare -A _STAGE_STATUS=()
declare -A _STAGE_TURNS=()
declare -A _STAGE_BUDGET=()
declare -A _STAGE_DURATION=()

# shellcheck source=lib/common.sh
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=lib/causality.sh
source "${TEKHTON_HOME}/lib/causality.sh"

# Source dashboard.sh (which auto-sources dashboard_parsers.sh)
# shellcheck source=lib/dashboard.sh
source "${TEKHTON_HOME}/lib/dashboard.sh"

# =============================================================================
# Test Group 1: init_dashboard() copies static files
# =============================================================================

PROJECT_DIR="${TMPDIR_BASE}/project1"
mkdir -p "$PROJECT_DIR"
export PROJECT_DIR
export TEKHTON_HOME
export DASHBOARD_ENABLED="true"
export DASHBOARD_DIR=".claude/dashboard"

init_dashboard "$PROJECT_DIR"

DASH_DIR="${PROJECT_DIR}/.claude/dashboard"

assert "init_dashboard creates dashboard dir" test -d "$DASH_DIR"
assert "init_dashboard creates data subdir" test -d "${DASH_DIR}/data"
assert "init_dashboard copies index.html" test -f "${DASH_DIR}/index.html"
assert "init_dashboard copies style.css" test -f "${DASH_DIR}/style.css"
assert "init_dashboard copies app.js" test -f "${DASH_DIR}/app.js"

# Verify copied files have non-zero content
assert "copied index.html is non-empty" test -s "${DASH_DIR}/index.html"
assert "copied style.css is non-empty" test -s "${DASH_DIR}/style.css"
assert "copied app.js is non-empty" test -s "${DASH_DIR}/app.js"

# Verify initial data files were also created
assert "run_state.js created by init" test -f "${DASH_DIR}/data/run_state.js"
assert "timeline.js created by init" test -f "${DASH_DIR}/data/timeline.js"
assert "milestones.js created by init" test -f "${DASH_DIR}/data/milestones.js"

# Verify init_dashboard skips copy when disabled
PROJECT_DIR2="${TMPDIR_BASE}/project2"
mkdir -p "$PROJECT_DIR2"
export PROJECT_DIR="$PROJECT_DIR2"
export DASHBOARD_ENABLED="false"
init_dashboard "$PROJECT_DIR2"
assert_not "disabled init_dashboard does not create dash dir" test -d "${PROJECT_DIR2}/.claude/dashboard"
export DASHBOARD_ENABLED="true"
export PROJECT_DIR="${TMPDIR_BASE}/project1"

# =============================================================================
# Test Group 1b: sync_dashboard_static_files() copies files into existing dir
# =============================================================================

PROJECT_DIR1b="${TMPDIR_BASE}/project1b"
mkdir -p "${PROJECT_DIR1b}/.claude/dashboard/data"
export PROJECT_DIR="$PROJECT_DIR1b"
export DASHBOARD_ENABLED="true"

# Dashboard dir exists but static files are missing (simulates M13→M14 upgrade)
assert_not "pre-sync: index.html absent" test -f "${PROJECT_DIR1b}/.claude/dashboard/index.html"

sync_dashboard_static_files "$PROJECT_DIR1b"

assert "sync copies index.html into existing dir" test -f "${PROJECT_DIR1b}/.claude/dashboard/index.html"
assert "sync copies style.css into existing dir" test -f "${PROJECT_DIR1b}/.claude/dashboard/style.css"
assert "sync copies app.js into existing dir" test -f "${PROJECT_DIR1b}/.claude/dashboard/app.js"

# Verify sync updates stale files (write dummy content, then sync should overwrite)
echo "stale" > "${PROJECT_DIR1b}/.claude/dashboard/index.html"
sync_dashboard_static_files "$PROJECT_DIR1b"
assert_not "sync overwrites stale index.html" grep -q "^stale$" "${PROJECT_DIR1b}/.claude/dashboard/index.html"

# Verify sync is skipped when disabled
export DASHBOARD_ENABLED="false"
rm -f "${PROJECT_DIR1b}/.claude/dashboard/app.js"
sync_dashboard_static_files "$PROJECT_DIR1b"
assert_not "disabled sync does not copy app.js" test -f "${PROJECT_DIR1b}/.claude/dashboard/app.js"
export DASHBOARD_ENABLED="true"
export PROJECT_DIR="${TMPDIR_BASE}/project1"

# =============================================================================
# Test Group 2: _regenerate_timeline_js() verbosity filter paths
# =============================================================================

PROJECT_DIR3="${TMPDIR_BASE}/project3"
mkdir -p "${PROJECT_DIR3}/.claude/dashboard/data"
export PROJECT_DIR="$PROJECT_DIR3"

# Build a synthetic causal log with multiple event types
CAUSAL_LOG="${TMPDIR_BASE}/causal.jsonl"
export CAUSAL_LOG_FILE="$CAUSAL_LOG"

# Write events of various types
cat > "$CAUSAL_LOG" << 'CAUSALEOF'
{"type":"stage_end","id":"e1","stage":"coder","detail":"done"}
{"type":"stage_end","id":"e2","stage":"reviewer","detail":"done"}
{"type":"verdict","id":"e3","stage":"reviewer","detail":"APPROVED"}
{"type":"verdict","id":"e4","stage":"reviewer","detail":"CHANGES_REQUIRED"}
{"type":"stage_start","id":"e5","stage":"tester","detail":"start"}
{"type":"stage_start","id":"e6","stage":"coder","detail":"start"}
{"type":"finding","id":"e7","stage":"security","detail":"XSS found"}
{"type":"finding","id":"e8","stage":"security","detail":"SQL injection"}
{"type":"build_gate","id":"e9","stage":"coder","detail":"passed"}
{"type":"milestone_start","id":"e10","stage":"","detail":"m01"}
{"type":"agent_turn","id":"e11","stage":"coder","detail":"turn 1"}
{"type":"agent_turn","id":"e12","stage":"coder","detail":"turn 2"}
{"type":"pipeline_start","id":"e13","stage":"","detail":"run begins"}
CAUSALEOF

DASH3="${PROJECT_DIR3}/.claude/dashboard"

# Test minimal verbosity
export DASHBOARD_VERBOSITY="minimal"
export DASHBOARD_MAX_TIMELINE_EVENTS=500
_regenerate_timeline_js
MINIMAL_SIZE=$(wc -c < "${DASH3}/data/timeline.js")

# Test normal verbosity
export DASHBOARD_VERBOSITY="normal"
_regenerate_timeline_js
NORMAL_SIZE=$(wc -c < "${DASH3}/data/timeline.js")

# Test verbose verbosity
export DASHBOARD_VERBOSITY="verbose"
_regenerate_timeline_js
VERBOSE_SIZE=$(wc -c < "${DASH3}/data/timeline.js")

assert "minimal verbosity output is smaller than normal" test "$MINIMAL_SIZE" -lt "$NORMAL_SIZE"
assert "normal verbosity output is smaller than verbose" test "$NORMAL_SIZE" -lt "$VERBOSE_SIZE"
assert "minimal verbosity timeline.js exists" test -f "${DASH3}/data/timeline.js"

# Verify minimal only includes stage_end and verdict events
export DASHBOARD_VERBOSITY="minimal"
_regenerate_timeline_js
assert "minimal includes stage_end events" assert_contains "minimal has stage_end" "${DASH3}/data/timeline.js" 'stage_end'
assert_contains "minimal has verdict events" "${DASH3}/data/timeline.js" 'verdict'

# Verify minimal excludes verbose-only events
assert_not "minimal excludes agent_turn events" grep -q 'agent_turn' "${DASH3}/data/timeline.js"
assert_not "minimal excludes stage_start events" grep -q '"type":"stage_start"' "${DASH3}/data/timeline.js"

# Verify verbose includes all event types
export DASHBOARD_VERBOSITY="verbose"
_regenerate_timeline_js
assert_contains "verbose includes agent_turn events" "${DASH3}/data/timeline.js" 'agent_turn'
assert_contains "verbose includes stage_start events" "${DASH3}/data/timeline.js" 'stage_start'
assert_contains "verbose includes stage_end events" "${DASH3}/data/timeline.js" 'stage_end'

# Verify max events cap is respected
export DASHBOARD_VERBOSITY="verbose"
export DASHBOARD_MAX_TIMELINE_EVENTS=3
_regenerate_timeline_js
EVENT_COUNT=$(grep -c '"type"' "${DASH3}/data/timeline.js" 2>/dev/null || true)
assert "max timeline events cap is respected" test "$EVENT_COUNT" -le 3
export DASHBOARD_MAX_TIMELINE_EVENTS=500

# =============================================================================
# Test Group 3: emit_dashboard_run_state() refresh_interval_ms injection
# =============================================================================

PROJECT_DIR4="${TMPDIR_BASE}/project4"
mkdir -p "${PROJECT_DIR4}/.claude/dashboard/data"
export PROJECT_DIR="$PROJECT_DIR4"
DASH4="${PROJECT_DIR4}/.claude/dashboard"

# Test with explicit DASHBOARD_REFRESH_INTERVAL=7 -> expect 7000ms
export DASHBOARD_REFRESH_INTERVAL=7
export PIPELINE_STATUS="running"
export CURRENT_STAGE="coder"
unset WAITING_FOR 2>/dev/null || true
export START_AT_TS="2026-01-01T00:00:00Z"

emit_dashboard_run_state

assert "run_state.js exists after emit" test -f "${DASH4}/data/run_state.js"
assert_contains "refresh_interval_ms is 7000 for interval=7" "${DASH4}/data/run_state.js" '"refresh_interval_ms":7000'

# Test with DASHBOARD_REFRESH_INTERVAL=30 -> expect 30000ms
export DASHBOARD_REFRESH_INTERVAL=30
emit_dashboard_run_state
assert_contains "refresh_interval_ms is 30000 for interval=30" "${DASH4}/data/run_state.js" '"refresh_interval_ms":30000'

# Test default (DASHBOARD_REFRESH_INTERVAL unset) -> expect 5000ms
unset DASHBOARD_REFRESH_INTERVAL
emit_dashboard_run_state
assert_contains "refresh_interval_ms defaults to 5000" "${DASH4}/data/run_state.js" '"refresh_interval_ms":5000'

# Test that pipeline_status is correct in emitted JS
export DASHBOARD_REFRESH_INTERVAL=5
export PIPELINE_STATUS="complete"
emit_dashboard_run_state
assert_contains "pipeline_status is correct in run_state.js" "${DASH4}/data/run_state.js" '"pipeline_status":"complete"'

# Test that run_state.js has TK_RUN_STATE assignment
assert_contains "run_state.js has TK_RUN_STATE global" "${DASH4}/data/run_state.js" 'window.TK_RUN_STATE'

# Verify emit is skipped when disabled
export DASHBOARD_ENABLED="false"
rm -f "${DASH4}/data/run_state.js"
mkdir -p "${DASH4}/data"
emit_dashboard_run_state
assert_not "disabled emit_dashboard_run_state does not write file" test -f "${DASH4}/data/run_state.js"
export DASHBOARD_ENABLED="true"

# =============================================================================
# Summary
# =============================================================================
echo "watchtower_dashboard: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
