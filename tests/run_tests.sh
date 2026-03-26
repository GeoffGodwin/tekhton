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

# Disable commit signing for all test subprocesses — tests create temporary
# git repos that inherit the global signing config, causing failures in
# environments with broken or unavailable signing keys.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="commit.gpgsign"
export GIT_CONFIG_VALUE_0="false"

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

    if bash "$test_file" < /dev/null > /dev/null 2>&1; then
        echo -e "${GREEN}PASS${NC} ${test_name}"
        PASS=$((PASS + 1))
    else
        echo -e "${RED}FAIL${NC} ${test_name}"
        # Re-run with output for debugging
        echo "  --- output ---"
        bash "$test_file" < /dev/null 2>&1 | sed 's/^/  /' || true
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
echo -e "  Shell:  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
echo "────────────────────────────────────────"

# --- Python tests (conditional) -----------------------------------------------
PYTHON_PASS=0
PYTHON_FAIL=0
PYTHON_TESTS_DIR="${TEKHTON_HOME}/tools/tests"

if [ -d "$PYTHON_TESTS_DIR" ]; then
    if command -v python3 &>/dev/null && python3 -c "import pytest" &>/dev/null; then
        echo
        echo "════════════════════════════════════════"
        echo "  Python Tool Tests"
        echo "════════════════════════════════════════"
        echo

        if python3 -m pytest "$PYTHON_TESTS_DIR" --tb=short -q 2>&1; then
            echo -e "  ${GREEN}Python tests passed${NC}"
            PYTHON_PASS=1
        else
            echo -e "  ${RED}Python tests failed${NC}"
            PYTHON_FAIL=1
            FAIL=$((FAIL + 1))
        fi
    elif command -v python3 &>/dev/null; then
        echo
        echo -e "  ${YELLOW}SKIP${NC} Python tests (pytest not installed)"
    else
        echo
        echo -e "  ${YELLOW}SKIP${NC} Python tests (python3 not found)"
    fi
else
    echo
    echo -e "  ${YELLOW}SKIP${NC} Python tests (tools/tests/ not found)"
fi

echo
echo "════════════════════════════════════════"
echo "  Final Summary"
echo "════════════════════════════════════════"
echo -e "  Shell:  Passed: ${GREEN}${PASS}${NC}  Failed: ${RED}${FAIL}${NC}"
if [ "$PYTHON_PASS" -gt 0 ] || [ "$PYTHON_FAIL" -gt 0 ]; then
    if [ "$PYTHON_FAIL" -gt 0 ]; then
        echo -e "  Python: ${RED}FAILED${NC}"
    else
        echo -e "  Python: ${GREEN}PASSED${NC}"
    fi
fi

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
