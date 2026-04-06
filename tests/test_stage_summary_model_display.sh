#!/usr/bin/env bash
# =============================================================================
# test_stage_summary_model_display.sh — Verify model name in STAGE_SUMMARY
#
# Tests that the Run Summary console output includes the model used at each
# stage, enabling debugging of performance differences between models.
#
# Tests:
#   1. STAGE_SUMMARY includes model name in correct format
#   2. Multiple stages show their respective models
#   3. _extract_stage_turns parser works with new format
#   4. Model name handling for various Claude model versions
#   5. Metrics parsing with model suffix in STAGE_SUMMARY
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/metrics.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: STAGE_SUMMARY format includes model name
# =============================================================================

echo "=== Test 1: STAGE_SUMMARY format includes model name ==="

# Simulate what happens in run_agent() after calling _invoke_and_monitor
# Line 225 in lib/agent.sh: STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s${_retry_suffix}"

label="Coder"
model="claude-sonnet-4-6"
turns_display="30/50"
mins=3
secs=45
_retry_suffix=""

STAGE_SUMMARY=""
STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s${_retry_suffix}"

# Verify format is correct
if echo -e "$STAGE_SUMMARY" | grep -q "Coder (claude-sonnet-4-6): 30/50 turns, 3m45s"; then
    pass "STAGE_SUMMARY format includes model in parentheses"
else
    fail "STAGE_SUMMARY format incorrect. Got: $(echo -e "$STAGE_SUMMARY")"
fi

# =============================================================================
# Test 2: Multiple stages with different models
# =============================================================================

echo
echo "=== Test 2: Multiple stages with different models ==="

STAGE_SUMMARY=""

# Add Scout
label="Scout"
model="claude-haiku-4-5"
turns_display="5/20"
mins=0
secs=30
STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s"

# Add Coder
label="Coder"
model="claude-sonnet-4-6"
turns_display="30/50"
mins=3
secs=0
STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s"

# Add Reviewer
label="Reviewer"
model="claude-opus-4-6"
turns_display="7/10"
mins=1
secs=0
STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s"

# Verify all three stages are present with their models
if echo -e "$STAGE_SUMMARY" | grep -q "Scout (claude-haiku-4-5)"; then
    pass "Scout stage includes haiku model"
else
    fail "Scout stage missing or wrong model. Got: $(echo -e "$STAGE_SUMMARY")"
fi

if echo -e "$STAGE_SUMMARY" | grep -q "Coder (claude-sonnet-4-6)"; then
    pass "Coder stage includes sonnet model"
else
    fail "Coder stage missing or wrong model. Got: $(echo -e "$STAGE_SUMMARY")"
fi

if echo -e "$STAGE_SUMMARY" | grep -q "Reviewer (claude-opus-4-6)"; then
    pass "Reviewer stage includes opus model"
else
    fail "Reviewer stage missing or wrong model. Got: $(echo -e "$STAGE_SUMMARY")"
fi

# =============================================================================
# Test 3: _extract_stage_turns parser works with model suffix
# =============================================================================

echo
echo "=== Test 3: _extract_stage_turns parser with model suffix ==="

STAGE_SUMMARY=""
STAGE_SUMMARY=$'  Scout (claude-haiku-4-5): 5/20 turns, 0m30s\n  Coder (claude-sonnet-4-6): 30/50 turns, 3m0s\n  Reviewer (claude-opus-4-6): 7/10 turns, 1m0s'

# Test that the parser extracts the first number (turns used) correctly
coder_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Coder")
if [ "$coder_turns" = "30" ]; then
    pass "_extract_stage_turns finds Coder turns (30) with model suffix"
else
    fail "_extract_stage_turns returned '${coder_turns}', expected '30'"
fi

reviewer_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Reviewer")
if [ "$reviewer_turns" = "7" ]; then
    pass "_extract_stage_turns finds Reviewer turns (7) with model suffix"
else
    fail "_extract_stage_turns returned '${reviewer_turns}', expected '7'"
fi

scout_turns=$(_extract_stage_turns "$STAGE_SUMMARY" "Scout")
if [ "$scout_turns" = "5" ]; then
    pass "_extract_stage_turns finds Scout turns (5) with model suffix"
else
    fail "_extract_stage_turns returned '${scout_turns}', expected '5'"
fi

# =============================================================================
# Test 4: _extract_stage_turns backward compatibility (old format without model)
# =============================================================================

echo
echo "=== Test 4: _extract_stage_turns backward compatibility ==="

# Test that the parser still works with old format (without model suffix)
STAGE_SUMMARY_OLD=$'  Scout: 5/20 turns, 0m30s\n  Coder: 30/50 turns, 3m0s\n  Reviewer: 7/10 turns, 1m0s'

coder_turns_old=$(_extract_stage_turns "$STAGE_SUMMARY_OLD" "Coder")
if [ "$coder_turns_old" = "30" ]; then
    pass "_extract_stage_turns finds Coder turns (30) in old format (no model)"
else
    fail "_extract_stage_turns returned '${coder_turns_old}', expected '30' for old format"
fi

# =============================================================================
# Test 5: Model names with various Claude versions
# =============================================================================

echo
echo "=== Test 5: Model names with various Claude versions ==="

# Test different model name formats that might be used
models=("claude-opus-4-6" "claude-sonnet-4-6" "claude-haiku-4-5" "claude-3-5-sonnet-20241022" "claude-3-opus-20240229")

for test_model in "${models[@]}"; do
    STAGE_SUMMARY=""
    label="Coder"
    turns_display="25/50"
    mins=2
    secs=30
    STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${test_model}): ${turns_display} turns, ${mins}m${secs}s"

    if echo -e "$STAGE_SUMMARY" | grep -q "${test_model}"; then
        pass "Model name preserved: ${test_model}"
    else
        fail "Model name not preserved: ${test_model}"
    fi
done

# =============================================================================
# Test 6: Retry suffix handling with model name
# =============================================================================

echo
echo "=== Test 6: Retry suffix handling with model name ==="

label="Coder"
model="claude-sonnet-4-6"
turns_display="25/50"
mins=2
secs=30
_retry_suffix=" (after 2 retries)"

STAGE_SUMMARY=""
STAGE_SUMMARY="${STAGE_SUMMARY}\n  ${label} (${model}): ${turns_display} turns, ${mins}m${secs}s${_retry_suffix}"

# Verify the full format with retry suffix
if echo -e "$STAGE_SUMMARY" | grep -q "Coder (claude-sonnet-4-6): 25/50 turns, 2m30s (after 2 retries)"; then
    pass "Retry suffix correctly placed after model name"
else
    fail "Format with retry suffix incorrect. Got: $(echo -e "$STAGE_SUMMARY")"
fi

# Parser should still extract turns correctly even with retry suffix
turns_with_retry=$(_extract_stage_turns "$STAGE_SUMMARY" "Coder")
if [ "$turns_with_retry" = "25" ]; then
    pass "_extract_stage_turns handles turns with retry suffix (got 25)"
else
    fail "_extract_stage_turns with retry suffix returned '${turns_with_retry}', expected '25'"
fi

# =============================================================================
# Test 7: Case-insensitive stage label matching in parser
# =============================================================================

echo
echo "=== Test 7: Case-insensitive stage label matching ==="

STAGE_SUMMARY=$'  coder (claude-sonnet-4-6): 30/50 turns, 3m0s\n  REVIEWER (claude-opus-4-6): 7/10 turns, 1m0s'

coder_ci=$(_extract_stage_turns "$STAGE_SUMMARY" "Coder")
if [ "$coder_ci" = "30" ]; then
    pass "_extract_stage_turns handles lowercase 'coder' label"
else
    fail "_extract_stage_turns case-insensitive matching failed for 'coder', got '${coder_ci}'"
fi

reviewer_ci=$(_extract_stage_turns "$STAGE_SUMMARY" "Reviewer")
if [ "$reviewer_ci" = "7" ]; then
    pass "_extract_stage_turns handles uppercase 'REVIEWER' label"
else
    fail "_extract_stage_turns case-insensitive matching failed for 'REVIEWER', got '${reviewer_ci}'"
fi

# =============================================================================
# Test 8: Edge case - model name with spaces/special characters properly contained
# =============================================================================

echo
echo "=== Test 8: Model name containment in parentheses ==="

# Verify that the model name is properly isolated in parentheses
STAGE_SUMMARY=$'  Coder (claude-sonnet-4-6): 30/50 turns, 3m0s'

# The format should be "Label (model):" - verify the closing paren is followed by colon
if echo -e "$STAGE_SUMMARY" | grep -qE "\(claude-sonnet-4-6\):[[:space:]]"; then
    pass "Model name properly enclosed in parentheses with colon after"
else
    fail "Model name not properly formatted. Format should be 'Label (model): ...'"
fi

# =============================================================================
# Test 9: print_run_summary() integration test
# =============================================================================

echo
echo "=== Test 9: print_run_summary() displays model information ==="

# Source print_run_summary function
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_helpers.sh"

# Set up globals that print_run_summary expects
TOTAL_TURNS=42
TOTAL_TIME=300
STAGE_SUMMARY=$'  Scout (claude-haiku-4-5): 5/20 turns, 0m30s\n  Coder (claude-sonnet-4-6): 30/50 turns, 3m0s\n  Reviewer (claude-opus-4-6): 7/10 turns, 1m0s'
LAST_CONTEXT_TOKENS=5000
LAST_CONTEXT_PCT=45

# Capture output from print_run_summary
output=$(print_run_summary 2>&1)

# Verify the output contains all expected information
if echo "$output" | grep -q "Scout (claude-haiku-4-5)"; then
    pass "print_run_summary shows Scout with haiku model"
else
    fail "print_run_summary output missing Scout model. Output: $output"
fi

if echo "$output" | grep -q "Coder (claude-sonnet-4-6)"; then
    pass "print_run_summary shows Coder with sonnet model"
else
    fail "print_run_summary output missing Coder model. Output: $output"
fi

if echo "$output" | grep -q "Reviewer (claude-opus-4-6)"; then
    pass "print_run_summary shows Reviewer with opus model"
else
    fail "print_run_summary output missing Reviewer model. Output: $output"
fi

if echo "$output" | grep -q "Total turns: 42"; then
    pass "print_run_summary shows total turns"
else
    fail "print_run_summary output missing total turns"
fi

if echo "$output" | grep -q "Total time:  5m"; then
    pass "print_run_summary shows total time correctly"
else
    fail "print_run_summary output missing or incorrect total time"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

echo "stage_summary_model_display tests passed"
