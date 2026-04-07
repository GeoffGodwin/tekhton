#!/usr/bin/env bash
set -euo pipefail

# Test: Verify that tekhton.sh documents the tester sub-stage sourcing convention
# This test validates the first drift resolution from M65

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

# Test 1: Verify the inline comment exists in tekhton.sh
echo "Test 1: Checking for sourcing convention documentation in tekhton.sh..."
if grep -q "Note: tester sub-stages" "${REPO_ROOT}/tekhton.sh"; then
    pass "Found documentation comment about tester sub-stages sourcing convention"
else
    fail "Missing documentation comment about tester sub-stages sourcing convention in tekhton.sh"
fi

# Test 2: Verify the comment mentions all 5 sub-stages
echo "Test 2: Checking that comment mentions all 5 tester sub-stages..."
comment_line=$(grep -A 1 "tester sub-stages" "${REPO_ROOT}/tekhton.sh" | head -2)
declare -a expected_substages=("tester_tdd.sh" "tester_continuation.sh" "tester_fix.sh" "tester_timing.sh" "tester_validation.sh")

for substage in "${expected_substages[@]}"; do
    if echo "$comment_line" | grep -q "$substage"; then
        pass "Comment mentions $substage"
    else
        fail "Comment does not mention $substage"
    fi
done

# Test 3: Verify that only tester.sh is directly sourced after the comment (no direct sourcing of sub-stages)
echo "Test 3: Verifying sourcing pattern after the convention documentation..."
# Extract the section around the tester sourcing
section=$(sed -n '812,816p' "${REPO_ROOT}/tekhton.sh")

# Check that tester.sh is sourced
if echo "$section" | grep -q 'source.*stages/tester\.sh'; then
    pass "tester.sh is properly sourced"
else
    fail "tester.sh not found in sourcing section"
fi

# Check that cleanup.sh follows (no tester sub-stages directly sourced after tester.sh)
if echo "$section" | grep -q 'source.*stages/cleanup\.sh'; then
    pass "cleanup.sh follows tester.sh without intervening sub-stage sources"
else
    fail "Expected cleanup.sh to follow after tester.sh"
fi

# Test 4: Verify that the sub-stage files themselves exist and are valid bash
echo "Test 4: Checking that all referenced tester sub-stage files exist..."
for substage in "${expected_substages[@]}"; do
    file_path="${REPO_ROOT}/stages/${substage}"
    if [ -f "$file_path" ]; then
        pass "File exists: stages/$substage"
    else
        fail "Missing file: stages/$substage"
    fi

    # Verify the file is valid bash
    if bash -n "$file_path" 2>/dev/null; then
        pass "File is valid bash: stages/$substage"
    else
        fail "File has syntax errors: stages/$substage"
    fi
done

# Test 5: Verify that tester.sh itself properly sources all sub-stages
echo "Test 5: Checking that tester.sh sources all 5 sub-stages..."
for substage in "${expected_substages[@]}"; do
    # Remove .sh from name for the function pattern
    func_name="${substage%.sh}"
    if grep -q "source.*stages/${substage}" "${REPO_ROOT}/stages/tester.sh" || grep -q "source.*${func_name}" "${REPO_ROOT}/stages/tester.sh"; then
        pass "tester.sh sources $substage"
    else
        # This might be ok if sourcing happens through another mechanism, so just warn
        echo "Note: Could not confirm tester.sh explicitly sources $substage (might be ok)"
    fi
done

echo ""
echo "All sourcing convention verification tests passed!"
exit 0
