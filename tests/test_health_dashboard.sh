#!/usr/bin/env bash
# Test: emit_dashboard_health() paths (Milestone 15)
#
# Covers: no baseline file → {"available":false}, baseline exists → {"available":true},
#         get_health_belt guard, dashboard disabled no-op, no data dir no-op.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stubs for common.sh functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
RED='' GREEN='' YELLOW='' BOLD='' NC=''

export TEKHTON_HOME

# _json_escape is provided by causality.sh at runtime; define a stub here
# so dashboard.sh functions can call it without sourcing the full pipeline.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# Source health.sh for get_health_belt and _read_json_int
source "${TEKHTON_HOME}/lib/health.sh"

# Source dashboard.sh (it sources dashboard_parsers.sh internally)
source "${TEKHTON_HOME}/lib/dashboard.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Test 1: No baseline file → writes {"available":false}
# ============================================================================

PROJ1="$TMPDIR/proj1"
mkdir -p "$PROJ1/.claude/dashboard/data"
# Deliberately do NOT create HEALTH_BASELINE.json

PROJECT_DIR="$PROJ1"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=true
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"

emit_dashboard_health

health_js="${PROJ1}/.claude/dashboard/data/health.js"
if [[ -f "$health_js" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js not created for no-baseline path" >&2
    FAIL=$((FAIL + 1))
fi

if grep -q '"available":false' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should contain available:false when no baseline" >&2
    FAIL=$((FAIL + 1))
fi

# Should NOT contain available:true
if grep -q '"available":true' "$health_js" 2>/dev/null; then
    echo "FAIL: health.js should not contain available:true when no baseline" >&2
    FAIL=$((FAIL + 1))
else
    PASS=$((PASS + 1))
fi

# ============================================================================
# Test 2: Baseline file exists → writes {"available":true,...} with belt
# ============================================================================

PROJ2="$TMPDIR/proj2"
mkdir -p "$PROJ2/.claude/dashboard/data"
cat > "$PROJ2/.claude/HEALTH_BASELINE.json" << 'BASELINE'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "composite": 72,
  "belt": "Blue Belt",
  "dimensions": {
    "test_health": {"score": 80, "weight": 30, "details": {}},
    "code_quality": {"score": 70, "weight": 25, "details": {}},
    "dependency_health": {"score": 60, "weight": 15, "details": {}},
    "doc_quality": {"score": 75, "weight": 15, "details": {}},
    "project_hygiene": {"score": 65, "weight": 15, "details": {}}
  }
}
BASELINE

PROJECT_DIR="$PROJ2"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=true
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"

emit_dashboard_health

health_js="${PROJ2}/.claude/dashboard/data/health.js"
if [[ -f "$health_js" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js not created when baseline exists" >&2
    FAIL=$((FAIL + 1))
fi

if grep -q '"available":true' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should contain available:true when baseline exists" >&2
    FAIL=$((FAIL + 1))
fi

# get_health_belt(72) = "Blue Belt"
if grep -q 'Blue Belt' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should contain 'Blue Belt' for composite score 72" >&2
    FAIL=$((FAIL + 1))
fi

# Belt field must be present
if grep -q '"belt"' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js missing 'belt' field" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: get_health_belt guard — different score boundaries reflected in belt
# ============================================================================

PROJ3="$TMPDIR/proj3"
mkdir -p "$PROJ3/.claude/dashboard/data"
cat > "$PROJ3/.claude/HEALTH_BASELINE.json" << 'BASELINE'
{
  "timestamp": "2026-01-01T00:00:00Z",
  "composite": 92,
  "dimensions": {}
}
BASELINE

PROJECT_DIR="$PROJ3"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=true
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"

emit_dashboard_health

health_js="${PROJ3}/.claude/dashboard/data/health.js"
# get_health_belt(92) = "Black Belt"
if grep -q 'Black Belt' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should contain 'Black Belt' for composite score 92" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 4: Dashboard disabled → emit_dashboard_health is a no-op
# ============================================================================

PROJ4="$TMPDIR/proj4"
mkdir -p "$PROJ4/.claude/dashboard/data"
cat > "$PROJ4/.claude/HEALTH_BASELINE.json" << 'BASELINE'
{"composite": 50, "dimensions": {}}
BASELINE

PROJECT_DIR="$PROJ4"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=false
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"

# Remove health.js if it exists to confirm no-op
rm -f "${PROJ4}/.claude/dashboard/data/health.js"

emit_dashboard_health

if [[ ! -f "${PROJ4}/.claude/dashboard/data/health.js" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should NOT be written when dashboard is disabled" >&2
    FAIL=$((FAIL + 1))
fi

DASHBOARD_ENABLED=true

# ============================================================================
# Test 5: No data directory → emit_dashboard_health is a no-op (no crash)
# ============================================================================

PROJ5="$TMPDIR/proj5"
mkdir -p "$PROJ5/.claude"
cat > "$PROJ5/.claude/HEALTH_BASELINE.json" << 'BASELINE'
{"composite": 50, "dimensions": {}}
BASELINE
# Intentionally do NOT create .claude/dashboard/data

PROJECT_DIR="$PROJ5"
DASHBOARD_DIR=".claude/dashboard"
DASHBOARD_ENABLED=true
HEALTH_BASELINE_FILE=".claude/HEALTH_BASELINE.json"

# Must not crash
emit_dashboard_health
PASS=$((PASS + 1))  # Survived without error

# health.js must not be created (no data dir)
if [[ ! -f "${PROJ5}/.claude/dashboard/data/health.js" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should not be created when data dir is absent" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 6: Written file is a valid JS window assignment
# ============================================================================

# Use PROJ2 which was written in Test 2
health_js="${PROJ2}/.claude/dashboard/data/health.js"
if grep -q 'window.TK_HEALTH' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should contain window.TK_HEALTH assignment" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 7: Baseline data is embedded in the health.js output
# ============================================================================

# PROJ2 has composite=72 in the baseline JSON; it should appear in health.js
if grep -q '"composite"' "$health_js" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: health.js should embed baseline data (composite field)" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Results
# ============================================================================

echo
echo "Dashboard health tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
