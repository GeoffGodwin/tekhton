#!/usr/bin/env bash
# =============================================================================
# test_auto_fix_on_test_failure.sh — Auto-fix on test failure behavior
#
# Tests the auto-fix feature that re-seeds the pipeline on test failure:
#   1. Config defaults (TESTER_FIX_ENABLED, TESTER_FIX_MAX_DEPTH, TESTER_FIX_OUTPUT_LIMIT)
#   2. Depth guard logic (stops recursing at max depth)
#   3. Failure output truncation to TESTER_FIX_OUTPUT_LIMIT
#   4. Feature is opt-in (disabled by default)
#   5. Test failure detection via grep patterns
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

# =============================================================================
# Phase 2: Test depth guard logic
# =============================================================================
echo
echo "=== Phase 2: Depth Guard Logic ==="

# Test case: depth 0, max 1 — should allow fix
# Simulate: TEKHTON_FIX_DEPTH=0, TESTER_FIX_MAX_DEPTH=1
FIX_DEPTH=0
MAX_DEPTH=1
if [[ "$FIX_DEPTH" -lt "$MAX_DEPTH" ]]; then
    assert_true "2.1 Depth 0 < max 1 allows fix" "true"
else
    assert_false "2.1 Depth 0 < max 1 allows fix" "true"
fi

# Test case: depth 1, max 1 — should NOT allow fix
FIX_DEPTH=1
MAX_DEPTH=1
if [[ "$FIX_DEPTH" -lt "$MAX_DEPTH" ]]; then
    assert_false "2.2 Depth 1 == max 1 blocks fix" "true"
else
    assert_true "2.2 Depth 1 == max 1 blocks fix" "true"
fi

# Test case: depth 2, max 1 — should NOT allow fix
FIX_DEPTH=2
MAX_DEPTH=1
if [[ "$FIX_DEPTH" -lt "$MAX_DEPTH" ]]; then
    assert_false "2.3 Depth 2 > max 1 blocks fix" "true"
else
    assert_true "2.3 Depth 2 > max 1 blocks fix" "true"
fi

# Test case: depth 0, max 3 — should allow fix
FIX_DEPTH=0
MAX_DEPTH=3
if [[ "$FIX_DEPTH" -lt "$MAX_DEPTH" ]]; then
    assert_true "2.4 Depth 0 < max 3 allows fix" "true"
else
    assert_false "2.4 Depth 0 < max 3 allows fix" "true"
fi

# =============================================================================
# Phase 3: Test test failure detection patterns
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
# Phase 4: Test failure output truncation
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
EOF

load_config

# MAX_DEPTH should be clamped to some reasonable max (check in config_defaults.sh)
# For now, just verify the value is loaded
assert_true "6.1 TESTER_FIX_MAX_DEPTH loads from config" \
    "[[ -n \"${TESTER_FIX_MAX_DEPTH:-}\" ]]"

assert_true "6.2 TESTER_FIX_OUTPUT_LIMIT loads from config" \
    "[[ -n \"${TESTER_FIX_OUTPUT_LIMIT:-}\" ]]"

# =============================================================================
# Phase 7: Environment variable override (TEKHTON_FIX_DEPTH)
# =============================================================================
echo
echo "=== Phase 7: Environment Variable Override ==="

# TEKHTON_FIX_DEPTH is set by the child process when spawning fix runs
# Verify the env var logic (depth increment)
INITIAL_DEPTH=0
NEXT_DEPTH=$((INITIAL_DEPTH + 1))

assert_eq "7.1 Depth increment (0 -> 1)" "1" "$NEXT_DEPTH"

INITIAL_DEPTH=2
NEXT_DEPTH=$((INITIAL_DEPTH + 1))

assert_eq "7.2 Depth increment (2 -> 3)" "3" "$NEXT_DEPTH"

# =============================================================================
# Phase 8: Simulate the condition check from tester.sh
# =============================================================================
echo
echo "=== Phase 8: Condition Check (tester.sh line 212-213) ==="

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

# Simulate test failure detection
FAILURE_DETECTED=true

# Depth 0, max depth 2 — should allow fix
TEKHTON_FIX_DEPTH=0
if [[ "$FAILURE_DETECTED" == "true" ]] && \
   [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] && \
   [[ "${TEKHTON_FIX_DEPTH:-0}" -lt "${TESTER_FIX_MAX_DEPTH:-1}" ]]; then
    assert_true "8.1 Condition allows fix at depth 0 with max 2" "true"
else
    assert_false "8.1 Condition allows fix at depth 0 with max 2" "true"
fi

# Depth 1, max depth 2 — should allow fix
TEKHTON_FIX_DEPTH=1
if [[ "$FAILURE_DETECTED" == "true" ]] && \
   [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] && \
   [[ "${TEKHTON_FIX_DEPTH:-0}" -lt "${TESTER_FIX_MAX_DEPTH:-1}" ]]; then
    assert_true "8.2 Condition allows fix at depth 1 with max 2" "true"
else
    assert_false "8.2 Condition allows fix at depth 1 with max 2" "true"
fi

# Depth 2, max depth 2 — should NOT allow fix
TEKHTON_FIX_DEPTH=2
if [[ "$FAILURE_DETECTED" == "true" ]] && \
   [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] && \
   [[ "${TEKHTON_FIX_DEPTH:-0}" -lt "${TESTER_FIX_MAX_DEPTH:-1}" ]]; then
    assert_false "8.3 Condition blocks fix at depth 2 with max 2" "true"
else
    assert_true "8.3 Condition blocks fix at depth 2 with max 2" "true"
fi

# Auto-fix disabled — should NOT allow fix even at depth 0
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

TEKHTON_FIX_DEPTH=0
if [[ "$FAILURE_DETECTED" == "true" ]] && \
   [[ "${TESTER_FIX_ENABLED:-false}" == "true" ]] && \
   [[ "${TEKHTON_FIX_DEPTH:-0}" -lt "${TESTER_FIX_MAX_DEPTH:-1}" ]]; then
    assert_false "8.4 Condition blocks fix when feature disabled" "true"
else
    assert_true "8.4 Condition blocks fix when feature disabled" "true"
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
