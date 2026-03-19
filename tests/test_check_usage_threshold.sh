#!/usr/bin/env bash
# =============================================================================
# test_check_usage_threshold.sh — Tests for check_usage_threshold() in common.sh
#
# Tests:
#   1. USAGE_THRESHOLD_PCT=0 returns 0 (disabled)
#   2. USAGE_THRESHOLD_PCT unset returns 0 (disabled)
#   3. USAGE_THRESHOLD_PCT non-numeric returns 0 (disabled)
#   4. claude usage returns empty → warns, returns 0
#   5. claude usage returns output with no percentage → warns, returns 0
#   6. Usage below threshold → logs, returns 0
#   7. Usage at threshold → warns, returns 1
#   8. Usage above threshold → warns, returns 1
#   9. Fractional percentage below threshold → returns 0
#  10. Fractional percentage at/above threshold → returns 1
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

source "${TEKHTON_HOME}/lib/common.sh"

FAIL=0

# Helper: run check_usage_threshold with a mocked `claude` command.
# $1 = USAGE_THRESHOLD_PCT value (or "__unset__" to unset)
# $2 = output that mock `claude` should print (or "__empty__" for empty)
# Returns the exit code of check_usage_threshold.
run_with_mock() {
    local threshold="$1"
    local mock_output="$2"

    # Write a mock `claude` script
    local mock_bin="${TMPDIR}/bin"
    mkdir -p "$mock_bin"
    if [[ "$mock_output" == "__empty__" ]]; then
        cat > "${mock_bin}/claude" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
    else
        cat > "${mock_bin}/claude" <<MOCK
#!/usr/bin/env bash
echo "${mock_output}"
MOCK
    fi
    chmod +x "${mock_bin}/claude"

    # Run in a subshell so PATH and variable changes don't leak
    (
        export PATH="${mock_bin}:${PATH}"
        if [[ "$threshold" == "__unset__" ]]; then
            unset USAGE_THRESHOLD_PCT
        else
            export USAGE_THRESHOLD_PCT="$threshold"
        fi
        check_usage_threshold
    )
}

# =============================================================================
# Test 1: USAGE_THRESHOLD_PCT=0 — disabled, always returns 0
# =============================================================================

if run_with_mock "0" "Usage: 95%" 2>/dev/null; then
    echo "✓ Test 1: USAGE_THRESHOLD_PCT=0 returns 0 (disabled)"
else
    echo "FAIL: Test 1 — USAGE_THRESHOLD_PCT=0 should return 0 (disabled)"
    FAIL=1
fi

# =============================================================================
# Test 2: USAGE_THRESHOLD_PCT unset — disabled, always returns 0
# =============================================================================

if run_with_mock "__unset__" "Usage: 95%" 2>/dev/null; then
    echo "✓ Test 2: USAGE_THRESHOLD_PCT unset returns 0 (disabled)"
else
    echo "FAIL: Test 2 — USAGE_THRESHOLD_PCT unset should return 0 (disabled)"
    FAIL=1
fi

# =============================================================================
# Test 3: USAGE_THRESHOLD_PCT non-numeric — disabled, returns 0
# =============================================================================

if run_with_mock "abc" "Usage: 95%" 2>/dev/null; then
    echo "✓ Test 3: USAGE_THRESHOLD_PCT=abc returns 0 (disabled)"
else
    echo "FAIL: Test 3 — non-numeric threshold should return 0 (disabled)"
    FAIL=1
fi

# =============================================================================
# Test 4: claude usage returns empty — warns, returns 0 (safe to continue)
# =============================================================================

if run_with_mock "80" "__empty__" 2>/dev/null; then
    echo "✓ Test 4: empty claude output returns 0 (safe skip)"
else
    echo "FAIL: Test 4 — empty claude output should return 0 (safe skip)"
    FAIL=1
fi

# Verify a warning is emitted
warn_output=$(run_with_mock "80" "__empty__" 2>&1 || true)
if echo "$warn_output" | grep -q "Could not read"; then
    echo "✓ Test 4b: warning emitted for empty claude output"
else
    echo "FAIL: Test 4b — expected 'Could not read' warning, got: $warn_output"
    FAIL=1
fi

# =============================================================================
# Test 5: claude usage output has no percentage — warns, returns 0
# =============================================================================

if run_with_mock "80" "Session usage information unavailable" 2>/dev/null; then
    echo "✓ Test 5: no percentage in output returns 0 (safe skip)"
else
    echo "FAIL: Test 5 — unparseable output should return 0 (safe skip)"
    FAIL=1
fi

warn_output=$(run_with_mock "80" "Session usage information unavailable" 2>&1 || true)
if echo "$warn_output" | grep -q "Could not parse"; then
    echo "✓ Test 5b: warning emitted for unparseable output"
else
    echo "FAIL: Test 5b — expected 'Could not parse' warning, got: $warn_output"
    FAIL=1
fi

# =============================================================================
# Test 6: Usage below threshold — logs, returns 0
# =============================================================================

if run_with_mock "80" "Token usage: 50%" 2>/dev/null; then
    echo "✓ Test 6: usage below threshold returns 0"
else
    echo "FAIL: Test 6 — usage below threshold (50% < 80%) should return 0"
    FAIL=1
fi

# =============================================================================
# Test 7: Usage exactly at threshold — warns, returns 1
# =============================================================================

if ! run_with_mock "80" "Token usage: 80%" 2>/dev/null; then
    echo "✓ Test 7: usage at threshold returns 1"
else
    echo "FAIL: Test 7 — usage at threshold (80% >= 80%) should return 1"
    FAIL=1
fi

warn_output=$(run_with_mock "80" "Token usage: 80%" 2>&1 || true)
if echo "$warn_output" | grep -q "exceeds threshold"; then
    echo "✓ Test 7b: warning emitted when threshold exceeded"
else
    echo "FAIL: Test 7b — expected 'exceeds threshold' warning, got: $warn_output"
    FAIL=1
fi

# =============================================================================
# Test 8: Usage above threshold — warns, returns 1
# =============================================================================

if ! run_with_mock "80" "Current session: 95%" 2>/dev/null; then
    echo "✓ Test 8: usage above threshold returns 1"
else
    echo "FAIL: Test 8 — usage above threshold (95% >= 80%) should return 1"
    FAIL=1
fi

# =============================================================================
# Test 9: Fractional percentage below threshold — returns 0
# =============================================================================

if run_with_mock "80" "Usage: 79.9%" 2>/dev/null; then
    echo "✓ Test 9: fractional percentage below threshold returns 0"
else
    echo "FAIL: Test 9 — fractional usage 79.9% < 80% should return 0"
    FAIL=1
fi

# =============================================================================
# Test 10: Fractional percentage at/above threshold — returns 1
# =============================================================================

if ! run_with_mock "80" "Usage: 80.1%" 2>/dev/null; then
    echo "✓ Test 10: fractional percentage above threshold returns 1"
else
    echo "FAIL: Test 10 — fractional usage 80.1% >= 80% should return 1"
    FAIL=1
fi

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    exit 1
fi

echo "PASS"
