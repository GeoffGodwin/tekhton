#!/usr/bin/env bash
# Test: gates.sh extraction to gates_ui.sh
# Verifies that UI test phase was correctly extracted while preserving behavior

set -euo pipefail

PASS=0
FAIL=0

# Test 1: gates.sh is under 300-line ceiling after extraction
echo "Test 1: Verify gates.sh is under 300-line ceiling..."
GATES_LINES=$(wc -l < lib/gates.sh)
if [[ $GATES_LINES -le 300 ]]; then
    echo "✓ PASS: gates.sh is $GATES_LINES lines (under 300-line ceiling)"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: gates.sh is $GATES_LINES lines (exceeds 300-line ceiling)"
    FAIL=$((FAIL+1))
fi

# Test 2: gates_ui.sh exists and is not empty
echo "Test 2: Verify gates_ui.sh exists with extracted code..."
if [[ -f lib/gates_ui.sh ]]; then
    UI_LINES=$(wc -l < lib/gates_ui.sh)
    if [[ $UI_LINES -gt 100 ]]; then
        echo "✓ PASS: gates_ui.sh exists with $UI_LINES lines"
        PASS=$((PASS+1))
    else
        echo "✗ FAIL: gates_ui.sh has only $UI_LINES lines (expected >100)"
        FAIL=$((FAIL+1))
    fi
else
    echo "✗ FAIL: gates_ui.sh file not found"
    FAIL=$((FAIL+1))
fi

# Test 3: _run_ui_test_phase function is in gates_ui.sh
echo "Test 3: Verify _run_ui_test_phase function exists in gates_ui.sh..."
if grep -q "^_run_ui_test_phase()" lib/gates_ui.sh; then
    echo "✓ PASS: _run_ui_test_phase function found in gates_ui.sh"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: _run_ui_test_phase function not found in gates_ui.sh"
    FAIL=$((FAIL+1))
fi

# Test 4: gates.sh calls _run_ui_test_phase
echo "Test 4: Verify gates.sh calls _run_ui_test_phase..."
if grep -q "_run_ui_test_phase" lib/gates.sh; then
    echo "✓ PASS: gates.sh calls _run_ui_test_phase"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: gates.sh does not call _run_ui_test_phase"
    FAIL=$((FAIL+1))
fi

# Test 5: tekhton.sh sources gates_ui.sh
echo "Test 5: Verify tekhton.sh sources gates_ui.sh..."
if grep -q 'source.*gates_ui.sh' tekhton.sh; then
    echo "✓ PASS: tekhton.sh sources gates_ui.sh"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: tekhton.sh does not source gates_ui.sh"
    FAIL=$((FAIL+1))
fi

# Test 6: Verify gates_ui.sh has proper header and sourcing directive
echo "Test 6: Verify gates_ui.sh has proper header..."
if grep -q "Sourced by tekhton.sh" lib/gates_ui.sh && grep -q "_run_ui_test_phase()" lib/gates_ui.sh; then
    echo "✓ PASS: gates_ui.sh has proper sourcing header and function"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: gates_ui.sh missing proper header or function definition"
    FAIL=$((FAIL+1))
fi

# Test 7: Verify Phase 4 code was removed from gates.sh
echo "Test 7: Verify Phase 4 code extraction from gates.sh..."
# The original Phase 4 was about 125 lines and contained UI test validation
# If gates.sh dropped from 413 to 294 lines, that's about 119 lines removed
# Check for the delegation comment that replaced the inline code
if grep -q "# Delegated to gates_ui.sh: _run_ui_test_phase()" lib/gates.sh; then
    echo "✓ PASS: gates.sh shows Phase 4 delegation comment"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: gates.sh missing delegation comment"
    FAIL=$((FAIL+1))
fi

# Test 8: Verify key UI test functions are in gates_ui.sh
echo "Test 8: Verify UI test functionality is in gates_ui.sh..."
KEY_PATTERNS=(
    "UI_TEST_CMD"
    "UI_VALIDATION_ENABLED"
    "UI_TEST_TIMEOUT"
)
FOUND_ALL=true
for pattern in "${KEY_PATTERNS[@]}"; do
    if ! grep -q "$pattern" lib/gates_ui.sh; then
        echo "  ✗ Pattern '$pattern' not found in gates_ui.sh"
        FOUND_ALL=false
    fi
done
if $FOUND_ALL; then
    echo "✓ PASS: All key UI test patterns found in gates_ui.sh"
    PASS=$((PASS+1))
else
    echo "✗ FAIL: Some key UI test patterns missing from gates_ui.sh"
    FAIL=$((FAIL+1))
fi

# Summary
echo ""
echo "Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi

exit 0
