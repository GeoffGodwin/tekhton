#!/usr/bin/env bash
# Test: finalize_summary.sh — JSON escaping for backslashes and quotes in milestone IDs
# Verifies the fix that ensures backslashes are escaped before double-quotes in safe_milestone.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

LOG_DIR="$TEST_TMPDIR/logs"
PROJECT_DIR="$TEST_TMPDIR"
mkdir -p "$LOG_DIR"

# Globals expected by _hook_emit_run_summary
_ORCH_ATTEMPT=1
_ORCH_AGENT_CALLS=2
_ORCH_ELAPSED=60
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_REVIEW_BUMPED=false
AUTONOMOUS_TIMEOUT=7200
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
REVIEW_CYCLE=1
MILESTONE_CURRENT_SPLIT_DEPTH=0

HUMAN_MODE=false
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false
TASK="test task"

# Stage tracking arrays (M34)
declare -A _STAGE_TURNS=()
declare -A _STAGE_DURATION=()
declare -A _STAGE_BUDGET=()

export LOG_DIR PROJECT_DIR
export _ORCH_ATTEMPT _ORCH_AGENT_CALLS _ORCH_ELAPSED _ORCH_NO_PROGRESS_COUNT
export _ORCH_REVIEW_BUMPED AUTONOMOUS_TIMEOUT AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY
export CONTINUATION_ATTEMPTS LAST_AGENT_RETRY_COUNT REVIEW_CYCLE MILESTONE_CURRENT_SPLIT_DEPTH

# Stub logging
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Mock git to avoid actual git operations — returns non-zero so changed_files stays empty
git() { return 1; }

# Source finalize_summary.sh
# shellcheck source=../lib/finalize_summary.sh
source "${TEKHTON_HOME}/lib/finalize_summary.sh"

# =============================================================================
# Helper: run _hook_emit_run_summary and read the output JSON
# =============================================================================
run_and_read_json() {
    local milestone="$1"
    local exit_code="${2:-0}"
    _CURRENT_MILESTONE="$milestone"
    _hook_emit_run_summary "$exit_code"
    cat "${LOG_DIR}/RUN_SUMMARY.json"
}

# =============================================================================
# Test 1: Milestone ID with no special characters (baseline)
# =============================================================================
echo "=== Test 1: plain milestone ID ==="

json=$(run_and_read_json "Milestone 18")

if echo "$json" | grep -q '"milestone": "Milestone 18"'; then
    pass "Plain milestone ID appears unmodified in JSON"
else
    fail "Plain milestone ID malformed: $(echo "$json" | grep milestone)"
fi

# =============================================================================
# Test 2: Milestone ID with a double quote
# =============================================================================
echo "=== Test 2: milestone ID with double quote ==="

json=$(run_and_read_json 'Fix "the" bug')

# The JSON should contain: "milestone": "Fix \"the\" bug"
if echo "$json" | grep -q '"milestone": "Fix \\"the\\" bug"'; then
    pass "Double quotes in milestone ID are escaped to \\\" in JSON"
else
    fail "Double quote escaping failed: $(echo "$json" | grep milestone)"
fi

# =============================================================================
# Test 3: Milestone ID with a backslash
# =============================================================================
echo "=== Test 3: milestone ID with backslash ==="

# Set milestone containing a literal backslash
_CURRENT_MILESTONE='foo\bar'
_hook_emit_run_summary 0
json=$(cat "${LOG_DIR}/RUN_SUMMARY.json")

# The JSON should contain: "milestone": "foo\\bar"
if echo "$json" | grep -q '"milestone": "foo\\\\bar"'; then
    pass "Backslash in milestone ID is escaped to \\\\ in JSON"
else
    fail "Backslash escaping failed: $(echo "$json" | grep milestone)"
fi

# =============================================================================
# Test 4: Milestone ID with backslash followed by a double quote
# The backslash must be escaped BEFORE the double quote to produce valid JSON.
# Without the fix, "foo\\"bar" would yield "foo\"bar" (invalid JSON — the
# backslash would escape the quote, not be escaped itself).
# With the fix (backslash-first), "foo\\"bar" yields "foo\\\"bar" (valid).
# =============================================================================
echo "=== Test 4: milestone ID with backslash followed by double quote ==="

_CURRENT_MILESTONE='path\"quoted'
_hook_emit_run_summary 0
json=$(cat "${LOG_DIR}/RUN_SUMMARY.json")

# Expected: "milestone": "path\\\"quoted" — valid JSON with escaped backslash + escaped quote
# Use python3 to validate JSON and extract the milestone value reliably
if command -v python3 &>/dev/null; then
    milestone_val=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d['milestone'])" "${LOG_DIR}/RUN_SUMMARY.json" 2>/dev/null || echo "PARSE_ERROR")
    if [[ "$milestone_val" == 'path\"quoted' ]]; then
        pass "Backslash+quote combination correctly escaped in JSON (python3 validation)"
    else
        fail "Backslash+quote escaping failed — milestone value: ${milestone_val}"
    fi
else
    # Fallback: grep for the expected escaped form
    if echo "$json" | grep -q '"milestone": "path\\\\"quoted"' || \
       echo "$json" | grep -q '"milestone": "path\\\\\"quoted"'; then
        pass "Backslash+quote combination correctly escaped in JSON"
    else
        fail "Backslash+quote escaping failed: $(echo "$json" | grep '"milestone"')"
    fi
fi

# =============================================================================
# Test 5: Empty milestone ID defaults to "none"
# =============================================================================
echo "=== Test 5: empty milestone defaults to 'none' ==="

json=$(run_and_read_json "")

if echo "$json" | grep -q '"milestone": "none"'; then
    pass "Empty milestone ID defaults to 'none' in JSON"
else
    fail "Empty milestone default failed: $(echo "$json" | grep milestone)"
fi

# =============================================================================
# Test 6: Outcome field — success on exit_code=0
# =============================================================================
echo "=== Test 6: outcome is 'success' on exit_code=0 ==="

json=$(run_and_read_json "M1" 0)

if echo "$json" | grep -q '"outcome": "success"'; then
    pass "outcome=success when exit_code=0"
else
    fail "outcome not success on exit_code=0: $(echo "$json" | grep outcome)"
fi

# =============================================================================
# Test 7: Outcome field — failure on exit_code=1 (non-timeout, non-stuck)
# =============================================================================
echo "=== Test 7: outcome is 'failure' on exit_code=1 ==="

_ORCH_ELAPSED=0
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_ATTEMPT=""
json=$(run_and_read_json "M1" 1)

if echo "$json" | grep -q '"outcome": "failure"'; then
    pass "outcome=failure when exit_code=1 and no timeout/stuck"
else
    fail "outcome not failure: $(echo "$json" | grep outcome)"
fi

# Restore
_ORCH_ATTEMPT=1
_ORCH_ELAPSED=60
_ORCH_NO_PROGRESS_COUNT=0

# =============================================================================
# Test 8: JSON output file is created at LOG_DIR/RUN_SUMMARY.json
# =============================================================================
echo "=== Test 8: output file location ==="

rm -f "${LOG_DIR}/RUN_SUMMARY.json"
run_and_read_json "M1" 0 > /dev/null

if [[ -f "${LOG_DIR}/RUN_SUMMARY.json" ]]; then
    pass "RUN_SUMMARY.json written to LOG_DIR"
else
    fail "RUN_SUMMARY.json not found at ${LOG_DIR}/RUN_SUMMARY.json"
fi

# =============================================================================
# Test 9: JSON structure has all required top-level keys
# =============================================================================
echo "=== Test 9: JSON structure has required keys ==="

json=$(run_and_read_json "M1" 0)

required_keys=("milestone" "outcome" "attempts" "total_agent_calls" "wall_clock_seconds"
               "total_turns" "total_time_s" "run_type" "task_label" "stages"
               "files_changed" "error_classes_encountered" "recovery_actions_taken"
               "rework_cycles" "split_depth" "timestamp")

all_ok=true
for key in "${required_keys[@]}"; do
    if echo "$json" | grep -q "\"${key}\""; then
        pass "JSON contains key: $key"
    else
        fail "JSON missing key: $key"
        all_ok=false
    fi
done

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
