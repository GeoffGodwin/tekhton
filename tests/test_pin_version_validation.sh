#!/usr/bin/env bash
# Test: TEKHTON_PIN_VERSION semver validation in config.sh
# Invalid value → warning printed + variable reset to empty
set -u

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

# Helper: run load_config with a given TEKHTON_PIN_VERSION in pipeline.conf
# Outputs the resulting TEKHTON_PIN_VERSION value and any warnings to stdout
run_with_pin_version() {
    local pin_value="$1"

    local tmpdir
    tmpdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tmpdir'" RETURN

    local proj_dir="$tmpdir"
    mkdir -p "${proj_dir}/.claude/agents"
    mkdir -p "${proj_dir}/.claude/logs"

    cat > "${proj_dir}/.claude/pipeline.conf" << EOF
PROJECT_NAME="Test Project"
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
ANALYZE_CMD="echo ok"
TEKHTON_PIN_VERSION=${pin_value}
EOF

    for role in coder reviewer tester jr-coder; do
        echo "# ${role}" > "${proj_dir}/.claude/agents/${role}.md"
    done
    echo "# Rules" > "${proj_dir}/CLAUDE.md"

    (
        set -euo pipefail
        export TEKHTON_HOME
        export PROJECT_DIR="$proj_dir"
        source "${TEKHTON_HOME}/lib/common.sh"
        NOTES_FILTER=""
        MILESTONE_MODE=false
        source "${TEKHTON_HOME}/lib/config.sh"
        cd "$proj_dir"
        load_config 2>&1
        echo "PIN_RESULT:${TEKHTON_PIN_VERSION}"
    )
}

# --- Test 1: valid semver X.Y.Z is accepted ---
output=$(run_with_pin_version "3.19.0")
pin_result=$(echo "$output" | grep "^PIN_RESULT:" | sed 's/^PIN_RESULT://')

if [ "$pin_result" = "3.19.0" ]; then
    echo "PASS: valid semver 3.19.0 accepted as-is"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: valid semver 3.19.0 not accepted — got: '$pin_result'"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 2: invalid value (non-semver string) is reset to empty ---
output=$(run_with_pin_version "latest")
pin_result=$(echo "$output" | grep "^PIN_RESULT:" | sed 's/^PIN_RESULT://')

if [ -z "$pin_result" ]; then
    echo "PASS: invalid pin 'latest' reset to empty"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: invalid pin 'latest' not reset — got: '$pin_result'"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 3: invalid value triggers a warning message ---
output=$(run_with_pin_version "latest")
if echo "$output" | grep -qi "TEKHTON_PIN_VERSION"; then
    echo "PASS: warning printed for invalid TEKHTON_PIN_VERSION"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: no warning printed for invalid TEKHTON_PIN_VERSION"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 4: partial semver (X.Y only) is rejected ---
output=$(run_with_pin_version "3.19")
pin_result=$(echo "$output" | grep "^PIN_RESULT:" | sed 's/^PIN_RESULT://')

if [ -z "$pin_result" ]; then
    echo "PASS: partial semver '3.19' (X.Y) reset to empty"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
else
    echo "FAIL: partial semver '3.19' not rejected — got: '$pin_result'"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
fi

# --- Test 5: empty pin value stays empty (no spurious warning) ---
output=$(run_with_pin_version "")
pin_result=$(echo "$output" | grep "^PIN_RESULT:" | sed 's/^PIN_RESULT://')
# Should not contain a warning about TEKHTON_PIN_VERSION
if echo "$output" | grep -qi "TEKHTON_PIN_VERSION must be valid"; then
    echo "FAIL: spurious warning for empty TEKHTON_PIN_VERSION"
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
else
    echo "PASS: no warning for empty TEKHTON_PIN_VERSION"
    PASS_COUNT=$(( PASS_COUNT + 1 ))
fi

# --- Summary ---
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All TEKHTON_PIN_VERSION validation tests passed ($PASS_COUNT)"
    exit 0
else
    echo "FAIL: $FAIL_COUNT tests failed ($PASS_COUNT passed)"
    exit 1
fi
