#!/usr/bin/env bash
set -euo pipefail

# Test: Verify that ARCHITECTURE.md properly documents all 5 tester sub-stages
# This test validates the second drift resolution from M65

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

pass() {
    echo -e "${GREEN}PASS${NC}: $*"
}

fail() {
    echo -e "${RED}FAIL${NC}: $*"
    exit 1
}

# Test 1: Verify each of the 5 tester sub-stages is documented in ARCHITECTURE.md
echo "Test 1: Checking that all 5 tester sub-stages are documented in ARCHITECTURE.md..."
declare -a expected_substages=("tester_tdd.sh" "tester_continuation.sh" "tester_fix.sh" "tester_timing.sh" "tester_validation.sh")

for substage in "${expected_substages[@]}"; do
    if grep -q "stages/${substage}" "${REPO_ROOT}/ARCHITECTURE.md"; then
        pass "Found documentation for $substage"
    else
        fail "Missing documentation for $substage in ARCHITECTURE.md"
    fi
done

# Test 2: Verify each sub-stage has the "Sourced by tester.sh" marker
echo ""
echo "Test 2: Checking that each sub-stage has proper sourcing documentation..."
for substage in "${expected_substages[@]}"; do
    # Create a pattern to check for the presence of both the filename and sourcing note
    if grep -A 1 "stages/${substage}" "${REPO_ROOT}/ARCHITECTURE.md" | grep -q "Sourced by.*tester\.sh"; then
        pass "Found sourcing documentation for $substage"
    else
        fail "Missing 'Sourced by tester.sh' marker for $substage"
    fi
done

# Test 3: Verify "do not run directly" warning is present for each sub-stage
echo ""
echo "Test 3: Checking that each sub-stage has 'do not run directly' warning..."
for substage in "${expected_substages[@]}"; do
    if grep -A 1 "stages/${substage}" "${REPO_ROOT}/ARCHITECTURE.md" | grep -q "do not run directly"; then
        pass "Found 'do not run directly' warning for $substage"
    else
        fail "Missing 'do not run directly' warning for $substage"
    fi
done

# Test 4: Verify the main tester.sh stage references these sub-stages
echo ""
echo "Test 4: Checking that main tester.sh documentation lists sub-stages..."
if grep -A 10 "stages/tester.sh" "${REPO_ROOT}/ARCHITECTURE.md" | grep -q "Sources sub-stages"; then
    pass "Found 'Sources sub-stages' reference in tester.sh documentation"
else
    fail "Missing 'Sources sub-stages' reference in tester.sh documentation"
fi

# Test 5: Verify all 5 sub-stages are listed in the tester.sh sub-stages reference
echo ""
echo "Test 5: Checking that tester.sh documentation lists all 5 sub-stages..."
# The tester.sh documentation includes all 5 sub-stages on one line (55)
tester_doc=$(grep -A 10 "stages/tester.sh" "${REPO_ROOT}/ARCHITECTURE.md")
for substage in "${expected_substages[@]}"; do
    if echo "$tester_doc" | grep -q "$substage"; then
        pass "Sub-stage $substage mentioned in tester.sh documentation"
    else
        fail "Sub-stage $substage not mentioned in tester.sh documentation"
    fi
done

# Test 6: Verify the order and presence of all sub-stages in one place
echo ""
echo "Test 6: Verifying complete list of tester sub-stages..."
complete_list=$(grep "Sources sub-stages:" "${REPO_ROOT}/ARCHITECTURE.md")
for substage in "${expected_substages[@]}"; do
    if echo "$complete_list" | grep -q "$substage"; then
        pass "Found $substage in complete sub-stages list"
    else
        fail "Missing $substage from complete sub-stages list"
    fi
done

echo ""
echo "All ARCHITECTURE.md documentation verification tests passed!"
exit 0
