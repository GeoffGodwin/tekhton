#!/usr/bin/env bash
# Test: _escalate_turn_budget pure-shell fallback (M91 Note 4)
set -euo pipefail

TEKHTON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$(mktemp -d)"
trap "rm -rf $PROJECT_DIR" EXIT

# Create a wrapper that removes awk from PATH for fallback testing
FAKE_BIN_DIR="$PROJECT_DIR/fake_bin"
mkdir -p "$FAKE_BIN_DIR"

# Create a fake 'command' that fails for awk but passes for everything else
cat > "$FAKE_BIN_DIR/awk" <<'EOF'
#!/bin/sh
echo "awk is disabled for this test" >&2
exit 127
EOF
chmod +x "$FAKE_BIN_DIR/awk"

# Source required libraries
source "$TEKHTON_DIR/lib/common.sh"
source "$TEKHTON_DIR/lib/orchestrate_aux.sh"

# Test helper: run _escalate_turn_budget with awk disabled
run_with_no_awk() {
    (
        # Remove standard awk from PATH, add our fake awk first
        export PATH="$FAKE_BIN_DIR:$(echo "$PATH" | sed 's|/usr/bin||g' | sed 's|/bin||g')"
        # Re-source the function in this subshell with the modified PATH
        source "$TEKHTON_DIR/lib/orchestrate_aux.sh"
        _escalate_turn_budget "$@"
    )
}

# Test 1: Pure-shell fallback parses 1.5 factor correctly
test_shell_fallback_decimal_factor() {
    # base=80, factor=1.5, count=1 should yield: 80 + (80 * 150 * 1) / 100 = 80 + 120 = 200
    local result=$(run_with_no_awk "80" "1.5" "1" "200")

    if [[ "$result" != "200" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=80, factor=1.5, count=1 (expected 200)"
        return 1
    fi

    return 0
}

# Test 2: Pure-shell fallback with count=2
test_shell_fallback_multiple_counts() {
    # base=80, factor=1.5, count=2 should yield: 80 + (80 * 150 * 2) / 100 = 80 + 240 = 320
    local result=$(run_with_no_awk "80" "1.5" "2" "500")

    if [[ "$result" != "320" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=80, factor=1.5, count=2 (expected 320)"
        return 1
    fi

    return 0
}

# Test 3: Pure-shell fallback respects cap
test_shell_fallback_respects_cap() {
    # Even with a high escalation, should not exceed cap
    # base=80, factor=2.0, count=5 would give 880, but cap is 200
    local result=$(run_with_no_awk "80" "2.0" "5" "200")

    if [[ "$result" != "200" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=80, factor=2.0, count=5, cap=200 (expected 200)"
        return 1
    fi

    return 0
}

# Test 4: Pure-shell fallback with single-decimal factor
test_shell_fallback_single_decimal() {
    # base=50, factor=1.2, count=1 should yield: 50 + (50 * 120 * 1) / 100 = 50 + 60 = 110
    local result=$(run_with_no_awk "50" "1.2" "1" "200")

    if [[ "$result" != "110" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=50, factor=1.2, count=1 (expected 110)"
        return 1
    fi

    return 0
}

# Test 5: Pure-shell fallback with two-decimal factor
test_shell_fallback_two_decimals() {
    # base=100, factor=1.75, count=1 should yield: 100 + (100 * 175 * 1) / 100 = 100 + 175 = 275
    local result=$(run_with_no_awk "100" "1.75" "1" "500")

    if [[ "$result" != "275" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=100, factor=1.75, count=1 (expected 275)"
        return 1
    fi

    return 0
}

# Test 6: Pure-shell fallback with integer factor (no decimals)
test_shell_fallback_integer_factor() {
    # base=60, factor=2, count=1 should yield: 60 + (60 * 200 * 1) / 100 = 60 + 120 = 180
    local result=$(run_with_no_awk "60" "2" "1" "500")

    if [[ "$result" != "180" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for base=60, factor=2, count=1 (expected 180)"
        return 1
    fi

    return 0
}

# Test 7: Unparseable factor should default to 1.5x
test_shell_fallback_unparseable_factor() {
    # An invalid factor should use the default 1.5 multiplier
    # base=80, factor="invalid", count=1 should use default: 80 + (80 * 150 * 1) / 100 = 200
    local result=$(run_with_no_awk "80" "invalid" "1" "500")

    if [[ "$result" != "200" ]]; then
        echo "FAIL: _escalate_turn_budget returned '$result' for invalid factor (expected 200)"
        return 1
    fi

    return 0
}

# Run all tests
if test_shell_fallback_decimal_factor && \
   test_shell_fallback_multiple_counts && \
   test_shell_fallback_respects_cap && \
   test_shell_fallback_single_decimal && \
   test_shell_fallback_two_decimals && \
   test_shell_fallback_integer_factor && \
   test_shell_fallback_unparseable_factor; then
    echo "PASS"
    exit 0
else
    echo "FAIL"
    exit 1
fi
