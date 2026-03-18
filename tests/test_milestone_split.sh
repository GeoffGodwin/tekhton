#!/usr/bin/env bash
# Test: Milestone pre-flight sizing, split depth, attempt tracking, and null-run auto-split
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
export MILESTONE_ARCHIVE_FILE

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_split.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# rc CMD ARGS... — runs CMD suppressing stdout/stderr, returns exit code
rc() {
    local _r=0
    "$@" > /dev/null 2>&1 || _r=$?
    return $_r
}

# ============================================================================
# check_milestone_size
# ============================================================================

echo "=== check_milestone_size ==="

MILESTONE_SPLIT_ENABLED=true
MILESTONE_SPLIT_THRESHOLD_PCT=120
ADJUSTED_CODER_TURNS=100

# threshold = 100 * 120 / 100 = 120
r=0; rc check_milestone_size "5" "80"    || r=$?; assert "Estimate 80 <= threshold 120: fits (0)"   "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
r=0; rc check_milestone_size "5" "120"   || r=$?; assert "Estimate 120 == threshold: fits (0)"       "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
r=0; rc check_milestone_size "5" "121"   || r=$?; assert "Estimate 121 > threshold 120: oversized (1)" "$([ "$r" -eq 1 ] && echo 0 || echo 1)"
r=0; rc check_milestone_size "3" "300"   || r=$?; assert "Estimate 300 >> threshold: oversized (1)"  "$([ "$r" -eq 1 ] && echo 0 || echo 1)"

# Feature disabled — always fits
MILESTONE_SPLIT_ENABLED=false
r=0; rc check_milestone_size "5" "999" || r=$?
assert "MILESTONE_SPLIT_ENABLED=false: always fits (0)" "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
MILESTONE_SPLIT_ENABLED=true

# 150% threshold
MILESTONE_SPLIT_THRESHOLD_PCT=150
r=0; rc check_milestone_size "1" "149" || r=$?; assert "150% threshold, 149 fits"     "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
r=0; rc check_milestone_size "1" "151" || r=$?; assert "150% threshold, 151 oversized" "$([ "$r" -eq 1 ] && echo 0 || echo 1)"

# CODER_MAX_TURNS_CAP fallback when ADJUSTED_CODER_TURNS unset
unset ADJUSTED_CODER_TURNS
CODER_MAX_TURNS_CAP=200
MILESTONE_SPLIT_THRESHOLD_PCT=120
# threshold = 200 * 120 / 100 = 240
r=0; rc check_milestone_size "2" "250" || r=$?; assert "Cap fallback: 250 > 240 oversized"     "$([ "$r" -eq 1 ] && echo 0 || echo 1)"
r=0; rc check_milestone_size "2" "200" || r=$?; assert "Cap fallback: 200 <= 240 fits"          "$([ "$r" -eq 0 ] && echo 0 || echo 1)"

# Restore
ADJUSTED_CODER_TURNS=100
MILESTONE_SPLIT_THRESHOLD_PCT=120

# ============================================================================
# get_split_depth
# ============================================================================

echo "=== get_split_depth ==="

assert "Milestone '5' has depth 0"       "$([ "$(get_split_depth '5')"       -eq 0 ] && echo 0 || echo 1)"
assert "Milestone '5.1' has depth 1"     "$([ "$(get_split_depth '5.1')"     -eq 1 ] && echo 0 || echo 1)"
assert "Milestone '5.1.2' has depth 2"   "$([ "$(get_split_depth '5.1.2')"   -eq 2 ] && echo 0 || echo 1)"
assert "Milestone '5.1.2.3' has depth 3" "$([ "$(get_split_depth '5.1.2.3')" -eq 3 ] && echo 0 || echo 1)"
assert "Milestone '0' has depth 0"       "$([ "$(get_split_depth '0')"       -eq 0 ] && echo 0 || echo 1)"
assert "Milestone '0.5' has depth 1"     "$([ "$(get_split_depth '0.5')"     -eq 1 ] && echo 0 || echo 1)"
assert "Milestone '11' has depth 0"      "$([ "$(get_split_depth '11')"      -eq 0 ] && echo 0 || echo 1)"
assert "Milestone '11.2' has depth 1"    "$([ "$(get_split_depth '11.2')"    -eq 1 ] && echo 0 || echo 1)"

# ============================================================================
# record_milestone_attempt / get_milestone_attempts
# ============================================================================

echo "=== record_milestone_attempt / get_milestone_attempts ==="

rm -f "${TMPDIR}/.claude/milestone_attempts.log"

result=$(get_milestone_attempts "5")
assert "No log file: get_milestone_attempts returns empty" "$([ -z "$result" ] && echo 0 || echo 1)"

record_milestone_attempt "5" "null_run" "0"
result=$(get_milestone_attempts "5")
assert "After recording: non-empty result"         "$([ -n "$result" ] && echo 0 || echo 1)"
assert "Record contains milestone separator"        "$(echo "$result" | grep -q '|5|' && echo 0 || echo 1)"
assert "Record contains outcome (null_run)"         "$(echo "$result" | grep -q 'null_run' && echo 0 || echo 1)"

record_milestone_attempt "5" "max_turns" "45"
count=$(get_milestone_attempts "5" | wc -l | tr -d '[:space:]')
assert "Two attempts for milestone 5" "$([ "$count" -eq 2 ] && echo 0 || echo 1)"

record_milestone_attempt "6" "null_run" "0"
count=$(get_milestone_attempts "5" | wc -l | tr -d '[:space:]')
assert "Milestone 6 attempt does not bleed into milestone 5 query" "$([ "$count" -eq 2 ] && echo 0 || echo 1)"

result6=$(get_milestone_attempts "6")
assert "Milestone 6 attempt retrieves correctly" "$([ -n "$result6" ] && echo 0 || echo 1)"

# Decimal milestones
record_milestone_attempt "5.1" "null_run" "0"
result=$(get_milestone_attempts "5.1")
assert "Decimal milestone 5.1 recorded and retrieved" "$([ -n "$result" ] && echo 0 || echo 1)"

# Turns field
record_milestone_attempt "7" "max_turns" "99"
result7=$(get_milestone_attempts "7")
assert "Turns field (99) in attempt record" "$(echo "$result7" | grep -q '|99$' && echo 0 || echo 1)"

# Attempt is append-only: get_milestone_attempts returns all prior entries
record_milestone_attempt "7" "max_turns" "0"
count7=$(get_milestone_attempts "7" | wc -l | tr -d '[:space:]')
assert "Attempts are append-only (two entries for milestone 7)" "$([ "$count7" -eq 2 ] && echo 0 || echo 1)"

# ============================================================================
# handle_null_run_split — feature-disabled paths
# ============================================================================

echo "=== handle_null_run_split — disabled paths ==="

MILESTONE_AUTO_RETRY=false
r=0; rc handle_null_run_split "5" "/nonexistent/CLAUDE.md" || r=$?
assert "MILESTONE_AUTO_RETRY=false returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"
MILESTONE_AUTO_RETRY=true

MILESTONE_SPLIT_ENABLED=false
r=0; rc handle_null_run_split "5" "/nonexistent/CLAUDE.md" || r=$?
assert "MILESTONE_SPLIT_ENABLED=false returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"
MILESTONE_SPLIT_ENABLED=true

# ============================================================================
# handle_null_run_split — depth enforcement
# ============================================================================

echo "=== handle_null_run_split — depth enforcement ==="

MILESTONE_MAX_SPLIT_DEPTH=3
MILESTONE_AUTO_RETRY=true
MILESTONE_SPLIT_ENABLED=true

# depth 3 == max: rejected
r=0; rc handle_null_run_split "5.1.2.3" "/nonexistent/CLAUDE.md" || r=$?
assert "Milestone at depth 3 (== max): returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# depth 4 > max: also rejected
r=0; rc handle_null_run_split "5.1.2.3.4" "/nonexistent/CLAUDE.md" || r=$?
assert "Milestone at depth 4 (> max): returns 1"  "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# ============================================================================
# split_milestone — depth limit
# ============================================================================

echo "=== split_milestone — depth limit ==="

MILESTONE_MAX_SPLIT_DEPTH=3

r=0; rc split_milestone "5.1.2.3"   "/nonexistent/CLAUDE.md" || r=$?
assert "split_milestone at depth 3 (== max): returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

r=0; rc split_milestone "5.1.2.3.4" "/nonexistent/CLAUDE.md" || r=$?
assert "split_milestone at depth 4 (> max): returns 1"  "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# ============================================================================
# split_milestone — missing CLAUDE.md
# ============================================================================

echo "=== split_milestone — missing CLAUDE.md ==="

r=0; rc split_milestone "5" "/nonexistent/path/CLAUDE.md" || r=$?
assert "Missing CLAUDE.md: returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# ============================================================================
# split_milestone — agent failure / CANNOT_SPLIT
# ============================================================================

echo "=== split_milestone — agent failure / CANNOT_SPLIT ==="

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project

#### Milestone 5: Big Task
Lots of work.

Acceptance criteria:
- Everything works

#### Milestone 6: Next Task
More work.

Acceptance criteria:
- Also works
CLAUDE_EOF

ADJUSTED_CODER_TURNS=100
TEKHTON_SESSION_DIR="$TMPDIR"

# Agent returns CANNOT_SPLIT signal
_call_planning_batch() { echo "[CANNOT_SPLIT] Irreducible"; return 0; }
render_prompt() { echo "mock prompt"; }

r=0; rc split_milestone "5" "${TMPDIR}/CLAUDE.md" || r=$?
assert "CANNOT_SPLIT signal: returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# Agent exits non-zero (produces no output)
_call_planning_batch() { return 1; }

r=0; rc split_milestone "5" "${TMPDIR}/CLAUDE.md" || r=$?
assert "Agent non-zero exit (empty output): returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# ============================================================================
# split_milestone — sub-milestone count validation
# ============================================================================

echo "=== split_milestone — sub-milestone count validation ==="

# Reset CLAUDE.md
cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project

#### Milestone 5: Big Task
Lots of work.

Acceptance criteria:
- Everything works

#### Milestone 6: Next Task
More work.

Acceptance criteria:
- Also works
CLAUDE_EOF

# Only 1 sub-milestone → fails validation
_call_planning_batch() {
    echo "#### Milestone 5.1: Only Sub-task"
    echo "Just one."
    echo ""
    echo "Acceptance criteria:"
    echo "- Done"
    return 0
}

r=0; rc split_milestone "5" "${TMPDIR}/CLAUDE.md" || r=$?
assert "Only 1 sub-milestone: returns 1" "$([ "$r" -ne 0 ] && echo 0 || echo 1)"

# 2 sub-milestones → succeeds and updates CLAUDE.md
_call_planning_batch() {
    cat << 'SPLIT_EOF'
#### Milestone 5.1: First Sub-task
Part 1.

Acceptance criteria:
- Part 1 done

#### Milestone 5.2: Second Sub-task
Part 2.

Acceptance criteria:
- Part 2 done
SPLIT_EOF
    return 0
}
render_prompt() { echo "mock prompt"; }

# Fresh CLAUDE.md
cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project

#### Milestone 5: Big Task
Lots of work.

Acceptance criteria:
- Everything works

#### Milestone 6: Next Task
More work.

Acceptance criteria:
- Also works
CLAUDE_EOF

r=0; rc split_milestone "5" "${TMPDIR}/CLAUDE.md" || r=$?
assert "2 sub-milestones: split_milestone returns 0"      "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
assert "CLAUDE.md contains Milestone 5.1 after split"     "$(grep -q 'Milestone 5.1' "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"
assert "CLAUDE.md contains Milestone 5.2 after split"     "$(grep -q 'Milestone 5.2' "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"
assert "Original Milestone 6 preserved"                    "$(grep -q 'Milestone 6' "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"

# 3 sub-milestones → also succeeds
_call_planning_batch() {
    cat << 'SPLIT_EOF'
#### Milestone 5.1: Sub 1
Part 1.

Acceptance criteria:
- Done 1

#### Milestone 5.2: Sub 2
Part 2.

Acceptance criteria:
- Done 2

#### Milestone 5.3: Sub 3
Part 3.

Acceptance criteria:
- Done 3
SPLIT_EOF
    return 0
}

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project

#### Milestone 5: Big Task
Lots of work.

Acceptance criteria:
- Everything works

#### Milestone 6: Next Task
More work.
CLAUDE_EOF

r=0; rc split_milestone "5" "${TMPDIR}/CLAUDE.md" || r=$?
assert "3 sub-milestones: split_milestone returns 0"      "$([ "$r" -eq 0 ] && echo 0 || echo 1)"
assert "CLAUDE.md contains Milestone 5.3 after 3-way split" "$(grep -q 'Milestone 5.3' "${TMPDIR}/CLAUDE.md" && echo 0 || echo 1)"

# ============================================================================
# Config defaults — MILESTONE_SPLIT_* values
# ============================================================================

echo "=== config defaults ==="

CONF_TMPDIR=$(mktemp -d)
trap 'rm -rf "$CONF_TMPDIR"' EXIT
mkdir -p "${CONF_TMPDIR}/.claude/agents"
cat > "${CONF_TMPDIR}/.claude/pipeline.conf" << 'CONF_EOF'
PROJECT_NAME=TestProject
CLAUDE_STANDARD_MODEL=claude-sonnet-test
CLAUDE_CODER_MODEL=claude-opus-test
ANALYZE_CMD=true
TEST_CMD=true
CODER_ROLE_FILE=.claude/agents/coder.md
REVIEWER_ROLE_FILE=.claude/agents/reviewer.md
TESTER_ROLE_FILE=.claude/agents/tester.md
CONF_EOF

for f in coder reviewer tester; do
    echo "# ${f} agent" > "${CONF_TMPDIR}/.claude/agents/${f}.md"
done

(
    export PROJECT_DIR="$CONF_TMPDIR"
    export TEKHTON_HOME
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/config.sh"
    load_config
    echo "MILESTONE_SPLIT_ENABLED=${MILESTONE_SPLIT_ENABLED}"
    echo "MILESTONE_SPLIT_THRESHOLD_PCT=${MILESTONE_SPLIT_THRESHOLD_PCT}"
    echo "MILESTONE_SPLIT_MAX_TURNS=${MILESTONE_SPLIT_MAX_TURNS}"
    echo "MILESTONE_AUTO_RETRY=${MILESTONE_AUTO_RETRY}"
    echo "MILESTONE_MAX_SPLIT_DEPTH=${MILESTONE_MAX_SPLIT_DEPTH}"
) > "${CONF_TMPDIR}/defaults.txt" 2>/dev/null

assert "MILESTONE_SPLIT_ENABLED defaults to true"      "$(grep -q 'MILESTONE_SPLIT_ENABLED=true'      "${CONF_TMPDIR}/defaults.txt" && echo 0 || echo 1)"
assert "MILESTONE_SPLIT_THRESHOLD_PCT defaults to 120" "$(grep -q 'MILESTONE_SPLIT_THRESHOLD_PCT=120' "${CONF_TMPDIR}/defaults.txt" && echo 0 || echo 1)"
assert "MILESTONE_SPLIT_MAX_TURNS defaults to 15"      "$(grep -q 'MILESTONE_SPLIT_MAX_TURNS=15'      "${CONF_TMPDIR}/defaults.txt" && echo 0 || echo 1)"
assert "MILESTONE_AUTO_RETRY defaults to true"         "$(grep -q 'MILESTONE_AUTO_RETRY=true'         "${CONF_TMPDIR}/defaults.txt" && echo 0 || echo 1)"
assert "MILESTONE_MAX_SPLIT_DEPTH defaults to 3"       "$(grep -q 'MILESTONE_MAX_SPLIT_DEPTH=3'       "${CONF_TMPDIR}/defaults.txt" && echo 0 || echo 1)"

# Hard cap: MILESTONE_SPLIT_MAX_TURNS clamped to 50
(
    export PROJECT_DIR="$CONF_TMPDIR"
    export TEKHTON_HOME
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/config.sh"
    MILESTONE_SPLIT_MAX_TURNS=9999
    load_config
    echo "MILESTONE_SPLIT_MAX_TURNS=${MILESTONE_SPLIT_MAX_TURNS}"
) > "${CONF_TMPDIR}/clamped.txt" 2>/dev/null

assert "MILESTONE_SPLIT_MAX_TURNS clamped to 50" \
    "$(grep -q 'MILESTONE_SPLIT_MAX_TURNS=50' "${CONF_TMPDIR}/clamped.txt" && echo 0 || echo 1)"

# Hard cap: MILESTONE_MAX_SPLIT_DEPTH clamped to 5
(
    export PROJECT_DIR="$CONF_TMPDIR"
    export TEKHTON_HOME
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/config.sh"
    MILESTONE_MAX_SPLIT_DEPTH=999
    load_config
    echo "MILESTONE_MAX_SPLIT_DEPTH=${MILESTONE_MAX_SPLIT_DEPTH}"
) > "${CONF_TMPDIR}/clamped2.txt" 2>/dev/null

assert "MILESTONE_MAX_SPLIT_DEPTH clamped to 5" \
    "$(grep -q 'MILESTONE_MAX_SPLIT_DEPTH=5' "${CONF_TMPDIR}/clamped2.txt" && echo 0 || echo 1)"

# Hard cap: MILESTONE_SPLIT_THRESHOLD_PCT clamped to 500
(
    export PROJECT_DIR="$CONF_TMPDIR"
    export TEKHTON_HOME
    source "${TEKHTON_HOME}/lib/common.sh"
    source "${TEKHTON_HOME}/lib/config.sh"
    MILESTONE_SPLIT_THRESHOLD_PCT=9999
    load_config
    echo "MILESTONE_SPLIT_THRESHOLD_PCT=${MILESTONE_SPLIT_THRESHOLD_PCT}"
) > "${CONF_TMPDIR}/clamped3.txt" 2>/dev/null

assert "MILESTONE_SPLIT_THRESHOLD_PCT clamped to 500" \
    "$(grep -q 'MILESTONE_SPLIT_THRESHOLD_PCT=500' "${CONF_TMPDIR}/clamped3.txt" && echo 0 || echo 1)"

# ============================================================================
# Prompt template exists
# ============================================================================

echo "=== prompt template ==="

assert "milestone_split.prompt.md exists" \
    "$([ -f "${TEKHTON_HOME}/prompts/milestone_split.prompt.md" ] && echo 0 || echo 1)"

assert "milestone_split.prompt.md contains {{MILESTONE_DEFINITION}}" \
    "$(grep -q '{{MILESTONE_DEFINITION}}' "${TEKHTON_HOME}/prompts/milestone_split.prompt.md" && echo 0 || echo 1)"

assert "milestone_split.prompt.md contains {{SCOUT_ESTIMATE}}" \
    "$(grep -q '{{SCOUT_ESTIMATE}}' "${TEKHTON_HOME}/prompts/milestone_split.prompt.md" && echo 0 || echo 1)"

assert "milestone_split.prompt.md contains {{TURN_CAP}}" \
    "$(grep -q '{{TURN_CAP}}' "${TEKHTON_HOME}/prompts/milestone_split.prompt.md" && echo 0 || echo 1)"

assert "milestone_split.prompt.md contains {{PRIOR_RUN_HISTORY}}" \
    "$(grep -q '{{PRIOR_RUN_HISTORY}}' "${TEKHTON_HOME}/prompts/milestone_split.prompt.md" && echo 0 || echo 1)"

# ============================================================================
# tekhton.sh sources milestone_split.sh
# ============================================================================

echo "=== tekhton.sh integration ==="

assert "tekhton.sh sources lib/milestone_split.sh" \
    "$(grep -q 'milestone_split.sh' "${TEKHTON_HOME}/tekhton.sh" && echo 0 || echo 1)"

# ============================================================================
# Summary
# ============================================================================

echo
echo "════════════════════════════════════════"
echo "  milestone_split tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All milestone_split tests passed"
