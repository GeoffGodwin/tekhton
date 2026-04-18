#!/usr/bin/env bash
# =============================================================================
# test_rule_max_turns_consistency.sh — Note 4: Verify duplication is consistent
#
# Tests that _rule_max_turns reads the Exit Reason consistently with
# _read_diagnostic_context. Both use the same awk pattern but in different
# places. This test verifies the duplication is harmless and both methods
# produce the same result.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/diagnose.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/diagnose_rules.sh"

FAIL=0

# Shared setup
PROJECT_DIR="${TMPDIR}"
PIPELINE_STATE_FILE="${TMPDIR}/PIPELINE_STATE.md"
CAUSAL_LOG_FILE=""
export PROJECT_DIR PIPELINE_STATE_FILE CAUSAL_LOG_FILE

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" != "$actual" ]]; then
        echo "FAIL: $name — expected '${expected}', got '${actual}'"
        FAIL=1
    else
        echo "ok: $name"
    fi
}

# =============================================================================
# Test 1: Both methods read the same Exit Reason from PIPELINE_STATE.md
# =============================================================================
cat > "$PIPELINE_STATE_FILE" << 'EOF'
## Task
Test task

## Exit Stage
coder

## Exit Reason
AGENT_SCOPE: max_turns exceeded on attempt 1

## Notes
Attempt exhausted.
EOF

# Read via _read_diagnostic_context
_read_diagnostic_context
diag_exit_reason="$_DIAG_EXIT_REASON"

# Extract directly via awk (the way _rule_max_turns does it)
direct_exit_reason=$(awk '/^## Exit Reason$/{getline; print; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || true)

assert_eq "Test 1: Both methods read same Exit Reason" \
    "$diag_exit_reason" "$direct_exit_reason"

# =============================================================================
# Test 2: Verify the exact content matches expected format
# =============================================================================
expected_reason="AGENT_SCOPE: max_turns exceeded on attempt 1"
assert_eq "Test 2: Exit reason has expected content" \
    "$expected_reason" "$diag_exit_reason"

# =============================================================================
# Test 3: Missing section returns empty string (consistent fallback)
# =============================================================================
cat > "$PIPELINE_STATE_FILE" << 'EOF'
## Task
Test task

## Notes
Some notes here.
EOF

_read_diagnostic_context
diag_exit_reason="$_DIAG_EXIT_REASON"
direct_exit_reason=$(awk '/^## Exit Reason$/{getline; print; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || true)

assert_eq "Test 3: Missing section returns empty string (consistent)" \
    "$diag_exit_reason" "$direct_exit_reason"

assert_eq "Test 3b: Both methods return empty when section missing" \
    "" "$diag_exit_reason"

# =============================================================================
# Test 4: Multi-line exit reason only captures first line (both methods)
# =============================================================================
cat > "$PIPELINE_STATE_FILE" << 'EOF'
## Task
Test task

## Exit Reason
AGENT_SCOPE: max_turns exceeded
This is a second line
And a third line

## Notes
Notes here.
EOF

_read_diagnostic_context
diag_exit_reason="$_DIAG_EXIT_REASON"
direct_exit_reason=$(awk '/^## Exit Reason$/{getline; print; exit}' "$PIPELINE_STATE_FILE" 2>/dev/null || true)

assert_eq "Test 4: Both methods capture first line only" \
    "$diag_exit_reason" "$direct_exit_reason"

expected_first_line="AGENT_SCOPE: max_turns exceeded"
assert_eq "Test 4b: First line matches expected" \
    "$expected_first_line" "$diag_exit_reason"

# Verify no extra lines captured
if [[ "$diag_exit_reason" == *$'\n'* ]]; then
    echo "FAIL: Test 4c: Exit reason contains newline (should not)"
    FAIL=1
else
    echo "ok: Test 4c: Exit reason contains no newlines"
fi

# =============================================================================
echo
if [ "$FAIL" -ne 0 ]; then
    echo "test_rule_max_turns_consistency: FAILED"
    exit 1
fi
echo "test_rule_max_turns_consistency: PASSED"
