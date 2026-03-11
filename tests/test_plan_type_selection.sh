#!/usr/bin/env bash
# Test: Planning phase project type selection logic
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Helper: run select_project_type() with piped stdin, capture resulting vars
# Usage: run_selection <stdin_input>
# Writes PLAN_PROJECT_TYPE and PLAN_TEMPLATE_FILE to stdout as "TYPE|FILE"
run_selection() {
    local input="$1"
    local result
    result=$(printf '%s\n' "$input" | bash -c '
        TEKHTON_HOME="'"${TEKHTON_HOME}"'"
        export TEKHTON_HOME
        export TEKHTON_TEST_MODE=1
        source "${TEKHTON_HOME}/lib/common.sh"
        source "${TEKHTON_HOME}/lib/plan.sh"
        select_project_type >/dev/null 2>&1
        printf "%s|%s" "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"
    ')
    echo "$result"
}

echo "=== Valid Selection — Each Project Type ==="

# Expected: index → type slug
declare -a EXPECTED_TYPES=("web-app" "web-game" "cli-tool" "api-service" "mobile-app" "library" "custom")

for i in "${!EXPECTED_TYPES[@]}"; do
    menu_num=$((i + 1))
    expected_type="${EXPECTED_TYPES[$i]}"
    expected_file="${TEKHTON_HOME}/templates/plans/${expected_type}.md"

    result=$(run_selection "$menu_num")
    actual_type="${result%%|*}"
    actual_file="${result##*|}"

    if [ "$actual_type" = "$expected_type" ]; then
        pass "Choice ${menu_num} → PLAN_PROJECT_TYPE='${actual_type}'"
    else
        fail "Choice ${menu_num}: expected type '${expected_type}', got '${actual_type}'"
    fi

    if [ "$actual_file" = "$expected_file" ]; then
        pass "Choice ${menu_num} → PLAN_TEMPLATE_FILE resolved correctly"
    else
        fail "Choice ${menu_num}: expected file '${expected_file}', got '${actual_file}'"
    fi

    if [ -f "$actual_file" ]; then
        pass "Choice ${menu_num} → resolved file exists on disk"
    else
        fail "Choice ${menu_num}: resolved file does not exist: '${actual_file}'"
    fi
done

echo
echo "=== Invalid Then Valid Selection ==="

# Pipe "0" (out of range), then "3" (cli-tool) — should skip the invalid and use 3
result=$(run_selection $'0\n3')
actual_type="${result%%|*}"

if [ "$actual_type" = "cli-tool" ]; then
    pass "Invalid '0' followed by valid '3' → cli-tool selected"
else
    fail "Invalid then valid: expected 'cli-tool', got '${actual_type}'"
fi

# Pipe "8" (out of range for 7 options), then "7" (custom)
result=$(run_selection $'8\n7')
actual_type="${result%%|*}"

if [ "$actual_type" = "custom" ]; then
    pass "Invalid '8' followed by valid '7' → custom selected"
else
    fail "Invalid '8' then '7': expected 'custom', got '${actual_type}'"
fi

# Pipe non-numeric string then valid choice
result=$(run_selection $'abc\n1')
actual_type="${result%%|*}"

if [ "$actual_type" = "web-app" ]; then
    pass "Invalid 'abc' followed by valid '1' → web-app selected"
else
    fail "Invalid 'abc' then '1': expected 'web-app', got '${actual_type}'"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
