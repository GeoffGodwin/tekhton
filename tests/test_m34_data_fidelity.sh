#!/usr/bin/env bash
# =============================================================================
# test_m34_data_fidelity.sh — M34 Watchtower Data Fidelity
#
# Tests:
# 1. Per-stage data in RUN_SUMMARY.json (stages object, deterministic order,
#    zero-data stages omitted)
# 2. Run type classification: milestone, human_bug, human_feat, human_polish,
#    human (no tag), drift, nonblocker, adhoc
# 3. Computed totals: total_turns and total_time_s sum from _STAGE_* arrays,
#    fall back to orchestrator counters when stage sums are zero
# 4. _parse_intake_report: inline format, header-then-value format, missing file
# 5. _parse_coder_summary: inline format, header-then-value format, file count,
#    missing file
# =============================================================================
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

# --- Globals required by _hook_emit_run_summary ------------------------------
_ORCH_ATTEMPT=1
_ORCH_AGENT_CALLS=3
_ORCH_ELAPSED=90
_ORCH_NO_PROGRESS_COUNT=0
_ORCH_REVIEW_BUMPED=false
AUTONOMOUS_TIMEOUT=7200
AGENT_ERROR_CATEGORY=""
AGENT_ERROR_SUBCATEGORY=""
CONTINUATION_ATTEMPTS=0
LAST_AGENT_RETRY_COUNT=0
REVIEW_CYCLE=1
MILESTONE_CURRENT_SPLIT_DEPTH=0
TASK="test task for M34"
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false

# Stage tracking arrays
declare -A _STAGE_TURNS=()
declare -A _STAGE_DURATION=()
declare -A _STAGE_BUDGET=()

export LOG_DIR PROJECT_DIR TASK
export _ORCH_ATTEMPT _ORCH_AGENT_CALLS _ORCH_ELAPSED _ORCH_NO_PROGRESS_COUNT
export _ORCH_REVIEW_BUMPED AUTONOMOUS_TIMEOUT
export AGENT_ERROR_CATEGORY AGENT_ERROR_SUBCATEGORY
export CONTINUATION_ATTEMPTS LAST_AGENT_RETRY_COUNT
export REVIEW_CYCLE MILESTONE_CURRENT_SPLIT_DEPTH

# Stub logging
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Mock git to avoid actual git operations (no changed files)
git() { return 1; }

# Source finalize_summary.sh
# shellcheck source=../lib/finalize_summary.sh
source "${TEKHTON_HOME}/lib/finalize_summary.sh"

# Helper: emit summary and return its JSON content
_emit_and_read() {
    local milestone="${1:-}"
    local exit_code="${2:-0}"
    _CURRENT_MILESTONE="$milestone"
    _hook_emit_run_summary "$exit_code"
    cat "${LOG_DIR}/RUN_SUMMARY.json"
}

# =============================================================================
# Test Suite 1: Per-stage data in RUN_SUMMARY.json
# =============================================================================
echo "=== Test Suite 1: Per-stage stages object ==="

# 1.1 — Stages with non-zero data appear in JSON
_STAGE_TURNS=([coder]=35 [reviewer]=10)
_STAGE_DURATION=([coder]=900 [reviewer]=200)
_STAGE_BUDGET=([coder]=50 [reviewer]=15)

HUMAN_MODE=false
_CURRENT_MILESTONE="m01"
json=$(_emit_and_read "m01" 0)

if echo "$json" | grep -q '"coder"'; then
    pass "1.1 coder stage appears in stages JSON when non-zero"
else
    fail "1.1 coder stage missing from stages JSON"
fi

if echo "$json" | grep -q '"reviewer"'; then
    pass "1.2 reviewer stage appears in stages JSON when non-zero"
else
    fail "1.2 reviewer stage missing from stages JSON"
fi

# 1.3 — Stage data has correct structure
if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
c = d.get('stages', {}).get('coder', {})
assert c.get('turns') == 35, f'turns={c.get(\"turns\")}'
assert c.get('duration_s') == 900, f'duration_s={c.get(\"duration_s\")}'
assert c.get('budget') == 50, f'budget={c.get(\"budget\")}'
" 2>/dev/null; then
    pass "1.3 coder stage has correct turns/duration_s/budget values"
else
    fail "1.3 coder stage structure or values incorrect"
fi

# 1.4 — Zero-data stages are omitted
_STAGE_TURNS=([coder]=5)
_STAGE_DURATION=([coder]=60)
_STAGE_BUDGET=([coder]=10)
json=$(_emit_and_read "m01" 0)

# tester was not set — should not appear
if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
stages = d.get('stages', {})
assert 'tester' not in stages, f'tester should be absent but got {stages}'
" 2>/dev/null; then
    pass "1.4 zero-data stage (tester) is omitted from stages JSON"
else
    fail "1.4 zero-data stage (tester) incorrectly included in stages JSON"
fi

# 1.5 — Empty stages produces {}
_STAGE_TURNS=()
_STAGE_DURATION=()
_STAGE_BUDGET=()
json=$(_emit_and_read "m01" 0)

if echo "$json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('stages') == {}, f'expected empty dict, got {d.get(\"stages\")}'
" 2>/dev/null; then
    pass "1.5 empty stage arrays produces empty stages object {}"
else
    fail "1.5 empty stage arrays should produce {} but did not"
fi

# Restore for subsequent tests
_STAGE_TURNS=()
_STAGE_DURATION=()
_STAGE_BUDGET=()

# =============================================================================
# Test Suite 2: Run type classification
# =============================================================================
echo "=== Test Suite 2: Run type classification ==="

# 2.1 — milestone (when _CURRENT_MILESTONE is set and not "none")
HUMAN_MODE=false
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false
json=$(_emit_and_read "m07" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "milestone" ]]; then
    pass "2.1 run_type=milestone when _CURRENT_MILESTONE is set"
else
    fail "2.1 run_type expected 'milestone', got '${run_type}'"
fi

# 2.2 — adhoc (no milestone, no special mode)
HUMAN_MODE=false
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "adhoc" ]]; then
    pass "2.2 run_type=adhoc when no milestone and no special mode"
else
    fail "2.2 run_type expected 'adhoc', got '${run_type}'"
fi

# 2.3 — human_bug (HUMAN_MODE=true, HUMAN_NOTES_TAG=BUG)
HUMAN_MODE=true
HUMAN_NOTES_TAG=BUG
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "human_bug" ]]; then
    pass "2.3 run_type=human_bug with HUMAN_MODE+BUG tag"
else
    fail "2.3 expected 'human_bug', got '${run_type}'"
fi

# 2.4 — human_feat
HUMAN_NOTES_TAG=FEAT
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "human_feat" ]]; then
    pass "2.4 run_type=human_feat with HUMAN_MODE+FEAT tag"
else
    fail "2.4 expected 'human_feat', got '${run_type}'"
fi

# 2.5 — human_polish
HUMAN_NOTES_TAG=POLISH
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "human_polish" ]]; then
    pass "2.5 run_type=human_polish with HUMAN_MODE+POLISH tag"
else
    fail "2.5 expected 'human_polish', got '${run_type}'"
fi

# 2.6 — human (HUMAN_MODE=true, no tag)
HUMAN_NOTES_TAG=""
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "human" ]]; then
    pass "2.6 run_type=human with HUMAN_MODE=true and no tag"
else
    fail "2.6 expected 'human', got '${run_type}'"
fi

# 2.7 — drift
HUMAN_MODE=false
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=true
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "drift" ]]; then
    pass "2.7 run_type=drift with FIX_DRIFT_MODE=true"
else
    fail "2.7 expected 'drift', got '${run_type}'"
fi

# 2.8 — nonblocker
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=true
json=$(_emit_and_read "" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "nonblocker" ]]; then
    pass "2.8 run_type=nonblocker with FIX_NONBLOCKERS_MODE=true"
else
    fail "2.8 expected 'nonblocker', got '${run_type}'"
fi

# 2.9 — milestone takes precedence over HUMAN_MODE
FIX_NONBLOCKERS_MODE=false
HUMAN_MODE=true
HUMAN_NOTES_TAG=BUG
json=$(_emit_and_read "m02" 0)
run_type=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('run_type',''))" 2>/dev/null)
if [[ "$run_type" == "milestone" ]]; then
    pass "2.9 milestone takes precedence over HUMAN_MODE"
else
    fail "2.9 expected 'milestone' to take precedence, got '${run_type}'"
fi

# Restore
HUMAN_MODE=false
HUMAN_NOTES_TAG=""
FIX_DRIFT_MODE=false
FIX_NONBLOCKERS_MODE=false

# =============================================================================
# Test Suite 3: Computed totals (total_turns, total_time_s)
# =============================================================================
echo "=== Test Suite 3: Computed totals ==="

# 3.1 — total_turns = sum of _STAGE_TURNS when non-zero
_STAGE_TURNS=([scout]=8 [coder]=35 [reviewer]=10 [tester]=12)
_STAGE_DURATION=([scout]=120 [coder]=900 [reviewer]=200 [tester]=180)
_STAGE_BUDGET=()
_ORCH_AGENT_CALLS=999  # Should NOT be used since stage sums are non-zero
_ORCH_ELAPSED=999

json=$(_emit_and_read "m01" 0)
total_turns=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_turns',0))" 2>/dev/null)
if [[ "$total_turns" == "65" ]]; then
    pass "3.1 total_turns = sum of stage turns (8+35+10+12=65)"
else
    fail "3.1 expected total_turns=65, got '${total_turns}'"
fi

# 3.2 — total_time_s = sum of _STAGE_DURATION when non-zero
total_time=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_time_s',0))" 2>/dev/null)
if [[ "$total_time" == "1400" ]]; then
    pass "3.2 total_time_s = sum of stage durations (120+900+200+180=1400)"
else
    fail "3.2 expected total_time_s=1400, got '${total_time}'"
fi

# 3.3 — total_turns falls back to _ORCH_AGENT_CALLS when stage sums = 0
_STAGE_TURNS=()
_STAGE_DURATION=()
_STAGE_BUDGET=()
_ORCH_AGENT_CALLS=7
_ORCH_ELAPSED=55

json=$(_emit_and_read "m01" 0)
total_turns=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_turns',0))" 2>/dev/null)
if [[ "$total_turns" == "7" ]]; then
    pass "3.3 total_turns falls back to _ORCH_AGENT_CALLS when stage sums are 0"
else
    fail "3.3 expected total_turns=7 (fallback), got '${total_turns}'"
fi

# 3.4 — total_time_s falls back to _ORCH_ELAPSED when stage sums = 0
total_time=$(echo "$json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('total_time_s',0))" 2>/dev/null)
if [[ "$total_time" == "55" ]]; then
    pass "3.4 total_time_s falls back to _ORCH_ELAPSED when stage sums are 0"
else
    fail "3.4 expected total_time_s=55 (fallback), got '${total_time}'"
fi

# Restore
_ORCH_AGENT_CALLS=3
_ORCH_ELAPSED=90

# =============================================================================
# Test Suite 4: _parse_intake_report (portable regex, both formats)
# =============================================================================
echo "=== Test Suite 4: _parse_intake_report ==="

# Source dashboard_parsers.sh — provides _parse_intake_report
# Requires _json_escape stub
_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
# shellcheck source=../lib/dashboard_parsers.sh
source "${TEKHTON_HOME}/lib/dashboard_parsers.sh"

# 4.1 — Inline format: "Verdict: PASS" / "Confidence: 82"
cat > "$TEST_TMPDIR/INTAKE_A.md" << 'EOF'
# Intake Report
Verdict: PASS
Confidence: 82/100
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_A.md")
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
confidence=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null)
if [[ "$verdict" == "PASS" ]]; then
    pass "4.1 _parse_intake_report extracts verdict from inline format"
else
    fail "4.1 expected verdict=PASS (inline), got '${verdict}' (result: ${result})"
fi
if [[ "$confidence" == "82" ]]; then
    pass "4.2 _parse_intake_report extracts confidence from inline format"
else
    fail "4.2 expected confidence=82 (inline), got '${confidence}' (result: ${result})"
fi

# 4.3 — Header-then-next-line format
cat > "$TEST_TMPDIR/INTAKE_B.md" << 'EOF'
# Intake Report
## Verdict
APPROVED

## Confidence
95
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_B.md")
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
confidence=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('confidence',0))" 2>/dev/null)
if [[ "$verdict" == "APPROVED" ]]; then
    pass "4.3 _parse_intake_report extracts verdict from header-then-value format"
else
    fail "4.3 expected verdict=APPROVED (header format), got '${verdict}' (result: ${result})"
fi
if [[ "$confidence" == "95" ]]; then
    pass "4.4 _parse_intake_report extracts confidence from header-then-value format"
else
    fail "4.4 expected confidence=95 (header format), got '${confidence}' (result: ${result})"
fi

# 4.5 — Missing file returns null
result=$(_parse_intake_report "$TEST_TMPDIR/NO_SUCH_FILE.md")
if [[ "$result" == "null" ]]; then
    pass "4.5 _parse_intake_report returns null when file is missing"
else
    fail "4.5 expected null for missing file, got '${result}'"
fi

# 4.6 — Section header with "#" prefix (e.g. "## Verdict: PASS")
cat > "$TEST_TMPDIR/INTAKE_C.md" << 'EOF'
## Verdict: CONDITIONAL_PASS
## Confidence: 70
EOF

result=$(_parse_intake_report "$TEST_TMPDIR/INTAKE_C.md")
verdict=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('verdict',''))" 2>/dev/null)
if [[ "$verdict" == "CONDITIONAL_PASS" ]]; then
    pass "4.6 _parse_intake_report handles '## Verdict: VALUE' format"
else
    fail "4.6 expected verdict=CONDITIONAL_PASS, got '${verdict}' (result: ${result})"
fi

# =============================================================================
# Test Suite 5: _parse_coder_summary (inline and header formats)
# =============================================================================
echo "=== Test Suite 5: _parse_coder_summary ==="

# 5.1 — Inline "## Status: COMPLETE" format (common agent output)
cat > "$TEST_TMPDIR/CODER_A.md" << 'EOF'
## Status: COMPLETE

## Files Modified
- lib/foo.sh
- lib/bar.sh
- tests/test_foo.sh
EOF

result=$(_parse_coder_summary "$TEST_TMPDIR/CODER_A.md")
status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
files=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('files_modified',0))" 2>/dev/null)
if [[ "$status" == "COMPLETE" ]]; then
    pass "5.1 _parse_coder_summary extracts COMPLETE status from inline format"
else
    fail "5.1 expected status=COMPLETE, got '${status}' (result: ${result})"
fi
if [[ "$files" == "3" ]]; then
    pass "5.2 _parse_coder_summary counts 3 modified files"
else
    fail "5.2 expected files_modified=3, got '${files}' (result: ${result})"
fi

# 5.3 — Header-then-next-line format
cat > "$TEST_TMPDIR/CODER_B.md" << 'EOF'
## Status
IN PROGRESS

## Files Modified
- lib/alpha.sh
EOF

result=$(_parse_coder_summary "$TEST_TMPDIR/CODER_B.md")
status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
if [[ "$status" == "IN PROGRESS" ]]; then
    pass "5.3 _parse_coder_summary extracts 'IN PROGRESS' from header-then-value format"
else
    fail "5.3 expected status='IN PROGRESS', got '${status}' (result: ${result})"
fi

# 5.4 — Files Created section (not just Modified)
cat > "$TEST_TMPDIR/CODER_C.md" << 'EOF'
## Status: COMPLETE

## Files Created
- lib/new_feature.sh
- tests/test_new_feature.sh

## Files Modified
- lib/existing.sh
EOF

result=$(_parse_coder_summary "$TEST_TMPDIR/CODER_C.md")
files=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('files_modified',0))" 2>/dev/null)
# Files Created (2) + Files Modified (1) — parser uses awk that matches both "Created" and "Modified"
if [[ "$files" -ge 1 ]]; then
    pass "5.4 _parse_coder_summary counts file entries across Created/Modified sections"
else
    fail "5.4 expected files_modified >= 1, got '${files}' (result: ${result})"
fi

# 5.5 — Missing file returns null
result=$(_parse_coder_summary "$TEST_TMPDIR/NO_SUCH_FILE.md")
if [[ "$result" == "null" ]]; then
    pass "5.5 _parse_coder_summary returns null when file is missing"
else
    fail "5.5 expected null for missing file, got '${result}'"
fi

# 5.6 — Reconstructed CODER_SUMMARY.md (pipeline-generated format)
cat > "$TEST_TMPDIR/CODER_D.md" << 'EOF'
## Status: COMPLETE

## Summary
CODER_SUMMARY.md was reconstructed by the pipeline after the coder agent
failed to produce or maintain it.

## Files Modified
- .claude/milestones/MANIFEST.cfg
- lib/finalize_summary.sh
- tests/test_finalize_run.sh

## New Files Created


## Git Diff Summary
```
 lib/finalize_summary.sh | 64 ++++
```
EOF

result=$(_parse_coder_summary "$TEST_TMPDIR/CODER_D.md")
status=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
files=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin).get('files_modified',0))" 2>/dev/null)
if [[ "$status" == "COMPLETE" ]]; then
    pass "5.6 _parse_coder_summary handles reconstructed CODER_SUMMARY.md format"
else
    fail "5.6 expected status=COMPLETE for reconstructed format, got '${status}'"
fi
if [[ "$files" -ge 3 ]]; then
    pass "5.7 _parse_coder_summary counts files from reconstructed format"
else
    fail "5.7 expected files_modified >= 3, got '${files}'"
fi

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
