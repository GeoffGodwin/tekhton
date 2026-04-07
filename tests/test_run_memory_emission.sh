#!/usr/bin/env bash
# Test: run_memory.sh — RUN_MEMORY.jsonl record structure and emission
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

# Required globals
_CURRENT_MILESTONE="m43"
_ORCH_ELAPSED=387
_ORCH_AGENT_CALLS=5
TASK="Make Scout identify affected test files"
TIMESTAMP="20260331_143022"

# Stub functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Mock git to return some changed files
git() { printf 'prompts/scout.prompt.md\nstages/coder.sh\n'; }

# Provide _json_escape from causality.sh
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Create a CODER_SUMMARY.md with decisions
cat > "${PROJECT_DIR}/CODER_SUMMARY.md" << 'EOF'
# Coder Summary
## Status: COMPLETE
## What Was Implemented
- Added Affected Test Files section to Scout report format
- Updated coder prompt to inject test baseline
## Files Modified
- prompts/scout.prompt.md
EOF

# Create a REVIEWER_REPORT.md with blockers
cat > "${PROJECT_DIR}/REVIEWER_REPORT.md" << 'EOF'
# Reviewer Report
## Verdict: CHANGES_REQUIRED
## Blockers
- Missing test baseline injection in coder prompt
## Non-Blocking Notes
- Consider adding debug logging
EOF

export LOG_DIR PROJECT_DIR TASK TIMESTAMP
export _CURRENT_MILESTONE _ORCH_ELAPSED _ORCH_AGENT_CALLS

# Source the module
# shellcheck source=../lib/run_memory.sh
source "${TEKHTON_HOME}/lib/run_memory.sh"

# =============================================================================
# Test 1: Record is appended to RUN_MEMORY.jsonl
# =============================================================================
echo "=== Test 1: record emission ==="

_hook_emit_run_memory 0
memory_file="${LOG_DIR}/RUN_MEMORY.jsonl"

if [[ -f "$memory_file" ]]; then
    pass "RUN_MEMORY.jsonl created"
else
    fail "RUN_MEMORY.jsonl not created"
fi

# =============================================================================
# Test 2: Record contains all required fields
# =============================================================================
echo "=== Test 2: required fields ==="

line=$(head -1 "$memory_file")
required_fields=("run_id" "milestone" "task" "files_touched" "decisions"
                 "rework_reasons" "test_outcomes" "duration_seconds"
                 "agent_calls" "verdict")

for field in "${required_fields[@]}"; do
    if echo "$line" | grep -q "\"${field}\""; then
        pass "Field present: $field"
    else
        fail "Field missing: $field"
    fi
done

# =============================================================================
# Test 3: Field values are correct
# =============================================================================
echo "=== Test 3: field values ==="

if echo "$line" | grep -q '"run_id":"run_20260331_143022"'; then
    pass "run_id correct"
else
    fail "run_id incorrect: $line"
fi

if echo "$line" | grep -q '"milestone":"m43"'; then
    pass "milestone correct"
else
    fail "milestone incorrect"
fi

if echo "$line" | grep -q '"verdict":"PASS"'; then
    pass "verdict PASS on exit_code=0"
else
    fail "verdict not PASS"
fi

if echo "$line" | grep -q '"duration_seconds":387'; then
    pass "duration correct"
else
    fail "duration incorrect"
fi

if echo "$line" | grep -q '"agent_calls":5'; then
    pass "agent_calls correct"
else
    fail "agent_calls incorrect"
fi

# =============================================================================
# Test 4: Files touched includes expected files
# =============================================================================
echo "=== Test 4: files touched ==="

if echo "$line" | grep -q 'prompts/scout.prompt.md'; then
    pass "files_touched includes scout prompt"
else
    fail "files_touched missing scout prompt"
fi

if echo "$line" | grep -q 'stages/coder.sh'; then
    pass "files_touched includes coder stage"
else
    fail "files_touched missing coder stage"
fi

# =============================================================================
# Test 5: Decisions extracted from CODER_SUMMARY.md
# =============================================================================
echo "=== Test 5: decisions extraction ==="

if echo "$line" | grep -q 'Affected Test Files'; then
    pass "decisions include coder summary items"
else
    fail "decisions missing coder summary content"
fi

# =============================================================================
# Test 6: Rework reasons extracted from REVIEWER_REPORT.md
# =============================================================================
echo "=== Test 6: rework reasons ==="

if echo "$line" | grep -q 'Missing test baseline'; then
    pass "rework_reasons include reviewer blocker"
else
    fail "rework_reasons missing reviewer content"
fi

# =============================================================================
# Test 7: Verdict is FAIL on non-zero exit
# =============================================================================
echo "=== Test 7: verdict FAIL ==="

rm -f "$memory_file"
_hook_emit_run_memory 1
line=$(head -1 "$memory_file")

if echo "$line" | grep -q '"verdict":"FAIL"'; then
    pass "verdict FAIL on exit_code=1"
else
    fail "verdict not FAIL on exit_code=1"
fi

# =============================================================================
# Test 8: Multiple records append (JSONL format)
# =============================================================================
echo "=== Test 8: append multiple ==="

_hook_emit_run_memory 0
count=$(wc -l < "$memory_file" | tr -d '[:space:]')
if [[ "$count" -eq 2 ]]; then
    pass "Second record appended (2 lines)"
else
    fail "Expected 2 lines, got $count"
fi

# =============================================================================
# Test 9: Empty CODER_SUMMARY and REVIEWER_REPORT produce empty arrays
# =============================================================================
echo "=== Test 9: missing reports produce empty arrays ==="

rm -f "${PROJECT_DIR}/CODER_SUMMARY.md" "${PROJECT_DIR}/REVIEWER_REPORT.md"
rm -f "$memory_file"
_hook_emit_run_memory 0
line=$(head -1 "$memory_file")

if echo "$line" | grep -q '"decisions":\[\]'; then
    pass "Empty decisions when no CODER_SUMMARY.md"
else
    fail "Expected empty decisions array"
fi

if echo "$line" | grep -q '"rework_reasons":\[\]'; then
    pass "Empty rework_reasons when no REVIEWER_REPORT.md"
else
    fail "Expected empty rework_reasons array"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
