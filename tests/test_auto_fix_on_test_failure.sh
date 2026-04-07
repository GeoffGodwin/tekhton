#!/usr/bin/env bash
# =============================================================================
# test_auto_fix_on_test_failure.sh — Auto-fix on test failure behavior (M64)
#
# Tests the inline tester fix agent feature:
#   1. Config defaults (TESTER_FIX_ENABLED, TESTER_FIX_MAX_DEPTH, TESTER_FIX_OUTPUT_LIMIT, TESTER_FIX_MAX_TURNS)
#   2. Attempt guard logic (stops fixing at max depth)
#   3. Failure output truncation to TESTER_FIX_OUTPUT_LIMIT
#   4. Feature is opt-in (disabled by default)
#   5. Test failure detection via grep patterns
#   6. Config clamping and validation
#   7. Inline fix condition checks (TESTER_FIX_ENABLED + TESTER_FIX_MAX_DEPTH > 0)
#   8. Smart test output truncation
#   9. TESTER_FIX_MAX_TURNS defaults and clamping
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"

# Create minimal pipeline.conf for config loading
mkdir -p "$PROJECT_DIR/.claude"
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
EOF

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local desc="$1" condition="$2"
    if eval "$condition"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — condition false: $condition"
        FAIL=$((FAIL + 1))
    fi
}

assert_false() {
    local desc="$1" condition="$2"
    if ! eval "$condition"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — condition true: $condition"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
# Phase 1: Verify config defaults are set correctly
# =============================================================================
echo "=== Phase 1: Config Defaults ==="

load_config

assert_eq "1.1 TESTER_FIX_ENABLED default is false" \
    "false" "${TESTER_FIX_ENABLED:-}"

assert_eq "1.2 TESTER_FIX_MAX_DEPTH default is 1" \
    "1" "${TESTER_FIX_MAX_DEPTH:-}"

assert_eq "1.3 TESTER_FIX_OUTPUT_LIMIT default is 4000" \
    "4000" "${TESTER_FIX_OUTPUT_LIMIT:-}"

# TESTER_FIX_MAX_TURNS defaults to CODER_MAX_TURNS / 3
local_expected_turns=$((CODER_MAX_TURNS / 3))
assert_eq "1.4 TESTER_FIX_MAX_TURNS defaults to CODER_MAX_TURNS/3" \
    "$local_expected_turns" "${TESTER_FIX_MAX_TURNS:-}"

# =============================================================================
# Phase 2: Attempt guard logic (inline fix loop)
# =============================================================================
echo
echo "=== Phase 2: Attempt Guard Logic ==="

# Test case: attempt 0 < max 1 — should allow fix
FIX_ATTEMPT=0
MAX_DEPTH=1
if [[ "$FIX_ATTEMPT" -lt "$MAX_DEPTH" ]]; then
    assert_true "2.1 Attempt 0 < max 1 allows fix" "true"
else
    assert_false "2.1 Attempt 0 < max 1 allows fix" "true"
fi

# Test case: attempt 1 == max 1 — should NOT allow fix
FIX_ATTEMPT=1
MAX_DEPTH=1
if [[ "$FIX_ATTEMPT" -lt "$MAX_DEPTH" ]]; then
    assert_false "2.2 Attempt 1 == max 1 blocks fix" "true"
else
    assert_true "2.2 Attempt 1 == max 1 blocks fix" "true"
fi

# Test case: attempt 2 > max 1 — should NOT allow fix
FIX_ATTEMPT=2
MAX_DEPTH=1
if [[ "$FIX_ATTEMPT" -lt "$MAX_DEPTH" ]]; then
    assert_false "2.3 Attempt 2 > max 1 blocks fix" "true"
else
    assert_true "2.3 Attempt 2 > max 1 blocks fix" "true"
fi

# Test case: attempt 0 < max 3 — should allow fix
FIX_ATTEMPT=0
MAX_DEPTH=3
if [[ "$FIX_ATTEMPT" -lt "$MAX_DEPTH" ]]; then
    assert_true "2.4 Attempt 0 < max 3 allows fix" "true"
else
    assert_false "2.4 Attempt 0 < max 3 allows fix" "true"
fi

# =============================================================================
# Phase 3: Test failure detection patterns
# =============================================================================
echo
echo "=== Phase 3: Test Failure Detection Patterns ==="

# Create mock log files with different patterns
LOG_WITH_FAILURES="$TMPDIR/log_with_failures.txt"
cat > "$LOG_WITH_FAILURES" << 'LOGEOF'
Running test suite...
[PASS] test_one.sh
[FAIL] test_two.sh: assertion failed
  -12: expected 0, got 1
Error in test_three.sh
Tests run: 3, Passed: 1, Failed: 2
LOGEOF

# Test failure detection via grep pattern "^\s+-[0-9]+:" or " -[1-9][0-9]*:"
if grep -qE "^\s+-[0-9]+:" "$LOG_WITH_FAILURES" || grep -q " -[1-9][0-9]*:" "$LOG_WITH_FAILURES"; then
    assert_true "3.1 Detects '-12:' failure pattern" "true"
else
    assert_false "3.1 Detects '-12:' failure pattern" "true"
fi

# Test with log that has no failures
LOG_NO_FAILURES="$TMPDIR/log_no_failures.txt"
cat > "$LOG_NO_FAILURES" << 'LOGEOF'
Running test suite...
[PASS] test_one.sh
[PASS] test_two.sh
Tests run: 2, Passed: 2, Failed: 0
LOGEOF

if grep -qE "^\s+-[0-9]+:" "$LOG_NO_FAILURES" || grep -q " -[1-9][0-9]*:" "$LOG_NO_FAILURES"; then
    assert_false "3.2 Does not detect failure in clean log" "true"
else
    assert_true "3.2 Does not detect failure in clean log" "true"
fi

# =============================================================================
# Phase 4: Failure output truncation
# =============================================================================
echo
echo "=== Phase 4: Failure Output Truncation ==="

# Create a log with long failure output
LONG_LOG="$TMPDIR/long_failure.txt"
python3 << 'PYEOF' > "$LONG_LOG"
# Create a log with repeated lines to exceed output limit
lines = []
for i in range(100):
    lines.append(f"Test failure output line {i}: This is a long error message with details")
lines.append("  -23: Something failed here")
lines.append("Additional context lines...")
print("\n".join(lines))
PYEOF

OUTPUT_LIMIT=500

# Extract failure lines and truncate to limit (simulating the auto-fix logic)
FAILURE_OUTPUT=$(grep -E '(FAIL|ERROR|error|failure|assert)' "$LONG_LOG" | tail -c "$OUTPUT_LIMIT" || true)
if [[ -z "$FAILURE_OUTPUT" ]]; then
    FAILURE_OUTPUT=$(tail -100 "$LONG_LOG" | tail -c "$OUTPUT_LIMIT")
fi

ACTUAL_CHARS=${#FAILURE_OUTPUT}
assert_true "4.1 Truncated output fits within limit (${ACTUAL_CHARS} <= ${OUTPUT_LIMIT})" \
    "[[ $ACTUAL_CHARS -le $OUTPUT_LIMIT ]]"

# Verify we got some output
assert_true "4.2 Truncated output is non-empty" \
    "[[ -n \"$FAILURE_OUTPUT\" ]]"

# =============================================================================
# Phase 5: Feature is opt-in (disabled by default)
# =============================================================================
echo
echo "=== Phase 5: Feature is Opt-In ==="

# Reload config to check defaults again
load_config

# Verify TESTER_FIX_ENABLED is false by default
if [[ "${TESTER_FIX_ENABLED:-false}" != "true" ]]; then
    assert_true "5.1 Auto-fix is disabled by default" "true"
else
    assert_false "5.1 Auto-fix is disabled by default" "true"
fi

# Create config with TESTER_FIX_ENABLED=true
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
TESTER_FIX_ENABLED=true
TESTER_FIX_MAX_DEPTH=2
TESTER_FIX_OUTPUT_LIMIT=2000
EOF

load_config

assert_eq "5.2 Auto-fix can be enabled via config" \
    "true" "${TESTER_FIX_ENABLED:-}"

assert_eq "5.3 Max depth can be configured" \
    "2" "${TESTER_FIX_MAX_DEPTH:-}"

assert_eq "5.4 Output limit can be configured" \
    "2000" "${TESTER_FIX_OUTPUT_LIMIT:-}"

# =============================================================================
# Phase 6: Config clamping and validation
# =============================================================================
echo
echo "=== Phase 6: Config Validation ==="

# Create config with extreme values (should be clamped)
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
TESTER_FIX_MAX_DEPTH=999
TESTER_FIX_OUTPUT_LIMIT=999999
TESTER_FIX_MAX_TURNS=999
EOF

load_config

# MAX_DEPTH should be clamped to 5
assert_eq "6.1 TESTER_FIX_MAX_DEPTH clamped to 5" \
    "5" "${TESTER_FIX_MAX_DEPTH:-}"

# OUTPUT_LIMIT should be clamped to 16000
assert_eq "6.2 TESTER_FIX_OUTPUT_LIMIT clamped to 16000" \
    "16000" "${TESTER_FIX_OUTPUT_LIMIT:-}"

# MAX_TURNS should be clamped to 100
assert_eq "6.3 TESTER_FIX_MAX_TURNS clamped to 100" \
    "100" "${TESTER_FIX_MAX_TURNS:-}"

# =============================================================================
# Phase 7: Inline fix condition checks (M64 — replaces recursive TEKHTON_FIX_DEPTH)
# =============================================================================
echo
echo "=== Phase 7: Inline Fix Condition Checks ==="

# Load config with auto-fix enabled
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
TESTER_FIX_ENABLED=true
TESTER_FIX_MAX_DEPTH=2
EOF

load_config

# Inline fix triggers when TESTER_FIX_ENABLED=true AND TESTER_FIX_MAX_DEPTH > 0
if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] \
   && [[ "${TESTER_FIX_MAX_DEPTH:-1}" -gt 0 ]]; then
    assert_true "7.1 Inline fix enabled with TESTER_FIX_ENABLED=true, MAX_DEPTH=2" "true"
else
    assert_false "7.1 Inline fix enabled with TESTER_FIX_ENABLED=true, MAX_DEPTH=2" "true"
fi

# Disable feature
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
TESTER_FIX_ENABLED=false
EOF

load_config

if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] \
   && [[ "${TESTER_FIX_MAX_DEPTH:-1}" -gt 0 ]]; then
    assert_false "7.2 Inline fix disabled when TESTER_FIX_ENABLED=false" "true"
else
    assert_true "7.2 Inline fix disabled when TESTER_FIX_ENABLED=false" "true"
fi

# MAX_DEPTH=0 disables fix
cat > "$PROJECT_DIR/.claude/pipeline.conf" << 'EOF'
PROJECT_NAME=test-project
CLAUDE_STANDARD_MODEL=claude-sonnet
CODER_MAX_TURNS=50
REVIEWER_MAX_TURNS=10
TESTER_MAX_TURNS=20
JR_CODER_MAX_TURNS=15
ANALYZE_CMD=echo "mock"
TEST_CMD=bash tests/mock_test.sh
TESTER_FIX_ENABLED=true
TESTER_FIX_MAX_DEPTH=0
EOF

load_config

if [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] \
   && [[ "${TESTER_FIX_MAX_DEPTH:-1}" -gt 0 ]]; then
    assert_false "7.3 Inline fix disabled when TESTER_FIX_MAX_DEPTH=0" "true"
else
    assert_true "7.3 Inline fix disabled when TESTER_FIX_MAX_DEPTH=0" "true"
fi

# =============================================================================
# Phase 8: Smart test output truncation
# =============================================================================
echo
echo "=== Phase 8: Smart Test Output Truncation ==="

# Source the tester fix helper
source "${TEKHTON_HOME}/stages/tester_fix.sh"

# Test with multi-block failure output
MULTI_BLOCK="FAIL: test_auth.ts
  Expected: 200
  Actual: 401
  at Context.<anonymous> (test_auth.ts:45:12)
  at processTicksAndRejections (internal/process/task_queues.js:97:5)
  at async Context.<anonymous> (test_auth.ts:44:22)
  at more stack trace line 1
  at more stack trace line 2
  at more stack trace line 3
  at more stack trace line 4
  at more stack trace line 5
  at more stack trace line 6
  at more stack trace line 7
  at more stack trace line 8 (last)
ERROR: test_db.ts
  Connection refused at port 5432
  Timeout after 30000ms"

truncated=$(_smart_truncate_test_output "$MULTI_BLOCK" 4000)
assert_true "8.1 Smart truncation produces output" "[[ -n \"$truncated\" ]]"

# The FAIL block has >10 lines, so middle should be omitted
if echo "$truncated" | grep -q "lines omitted"; then
    assert_true "8.2 Long failure block is truncated with omission marker" "true"
else
    assert_false "8.2 Long failure block is truncated with omission marker" "true"
fi

# Both failure blocks should be present
if echo "$truncated" | grep -q "FAIL: test_auth.ts" && echo "$truncated" | grep -q "ERROR: test_db.ts"; then
    assert_true "8.3 Both failure blocks preserved" "true"
else
    assert_false "8.3 Both failure blocks preserved" "true"
fi

# Test with empty input
empty_result=$(_smart_truncate_test_output "" 4000)
assert_eq "8.4 Empty input returns empty output" "" "$empty_result"

# Test character limit enforcement
huge_input=""
for i in $(seq 1 200); do
    huge_input+="FAIL: test line $i with lots of error details and context and more stuff
"
done
capped=$(_smart_truncate_test_output "$huge_input" 500)
assert_true "8.5 Output capped at char limit" "[[ ${#capped} -le 600 ]]"  # allow for truncation message

# =============================================================================
# Phase 9: No recursive pipeline references remain
# =============================================================================
echo
echo "=== Phase 9: No Recursive Pipeline References ==="

# Verify tester.sh no longer references recursive pipeline spawn
if grep -q 'bash.*tekhton\.sh' "${TEKHTON_HOME}/stages/tester.sh"; then
    assert_false "9.1 No recursive tekhton.sh invocation in tester.sh" "true"
else
    assert_true "9.1 No recursive tekhton.sh invocation in tester.sh" "true"
fi

if grep -q 'TEKHTON_FIX_DEPTH' "${TEKHTON_HOME}/stages/tester.sh"; then
    assert_false "9.2 No TEKHTON_FIX_DEPTH reference in tester.sh" "true"
else
    assert_true "9.2 No TEKHTON_FIX_DEPTH reference in tester.sh" "true"
fi

# Verify tester_fix.sh doesn't reference recursive spawn either
if grep -q 'bash.*tekhton\.sh' "${TEKHTON_HOME}/stages/tester_fix.sh"; then
    assert_false "9.3 No recursive tekhton.sh invocation in tester_fix.sh" "true"
else
    assert_true "9.3 No recursive tekhton.sh invocation in tester_fix.sh" "true"
fi

# =============================================================================
# Phase 10: Prompt template exists with correct variables
# =============================================================================
echo
echo "=== Phase 10: Prompt Template ==="

PROMPT_FILE="${TEKHTON_HOME}/prompts/tester_fix.prompt.md"
assert_true "10.1 tester_fix.prompt.md exists" "[[ -f \"$PROMPT_FILE\" ]]"

if grep -q '{{TESTER_FIX_OUTPUT}}' "$PROMPT_FILE"; then
    assert_true "10.2 Prompt has TESTER_FIX_OUTPUT variable" "true"
else
    assert_false "10.2 Prompt has TESTER_FIX_OUTPUT variable" "true"
fi

if grep -q '{{TESTER_FIX_TEST_FILES}}' "$PROMPT_FILE"; then
    assert_true "10.3 Prompt has TESTER_FIX_TEST_FILES variable" "true"
else
    assert_false "10.3 Prompt has TESTER_FIX_TEST_FILES variable" "true"
fi

if grep -q '{{IF:TEST_BASELINE_SUMMARY}}' "$PROMPT_FILE"; then
    assert_true "10.4 Prompt has TEST_BASELINE_SUMMARY conditional" "true"
else
    assert_false "10.4 Prompt has TEST_BASELINE_SUMMARY conditional" "true"
fi

if grep -q '{{IF:SERENA_ACTIVE}}' "$PROMPT_FILE"; then
    assert_true "10.5 Prompt has SERENA_ACTIVE conditional" "true"
else
    assert_false "10.5 Prompt has SERENA_ACTIVE conditional" "true"
fi

if grep -q '{{TEST_CMD}}' "$PROMPT_FILE"; then
    assert_true "10.6 Prompt has TEST_CMD variable" "true"
else
    assert_false "10.6 Prompt has TEST_CMD variable" "true"
fi

# Verify prompt instructs fix agent not to modify implementation
if grep -qi 'fix the test code.*not the implementation\|do not.*fix the implementation' "$PROMPT_FILE"; then
    assert_true "10.7 Prompt instructs fix agent not to modify implementation" "true"
else
    assert_false "10.7 Prompt instructs fix agent not to modify implementation" "true"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
    echo "All tests passed! (${PASS} passed)"
    exit 0
else
    echo "FAILED: ${FAIL} test(s) failed, ${PASS} passed"
    exit 1
fi
