#!/usr/bin/env bash
# =============================================================================
# tests/run_tests.sh — Self-test runner for Tekhton
#
# Run from the tekhton repo root:
#   bash tests/run_tests.sh
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_DIR="${TEKHTON_HOME}/tests"
PASS=0
FAIL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

run_test() {
    local test_name="$1"
    local test_file="${TESTS_DIR}/${test_name}"

    if [ ! -f "$test_file" ]; then
        echo -e "${RED}MISSING${NC} ${test_name}"
        FAIL=$((FAIL + 1))
        return
    fi

    if bash "$test_file" > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC} ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} ${test_name}"
        # Re-run with output for debugging
        echo "  --- output ---"
        bash "$test_file" 2>&1 | sed 's/^/  /' || true
        echo "  --- end ---"
        FAIL=$((FAIL + 1))
    fi
}

echo "════════════════════════════════════════"
echo "  Tekhton Self-Tests"
echo "════════════════════════════════════════"
echo

# Discover and run all test files
for test_file in "${TESTS_DIR}"/test_*.sh; do
    [ -f "$test_file" ] || continue
    run_test "$(basename "$test_file")"
done

echo
echo "────────────────────────────────────────"
echo -e "  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
