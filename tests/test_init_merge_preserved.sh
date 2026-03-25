#!/usr/bin/env bash
# Test: _merge_preserved_values() edge cases — Milestone 22
# Coverage gap identified by reviewer: values containing /, |, and & in sed s|...|...|
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source the library under test (also sources init_config_sections.sh)
# shellcheck source=../lib/init_config.sh
source "${TEKHTON_HOME}/lib/init_config.sh"

# =============================================================================
# Helper: create a minimal config file with known keys
# =============================================================================
make_base_conf() {
    local conf_file="$1"
    cat > "$conf_file" << 'EOF'
PROJECT_NAME="myproject"
TEST_CMD="true"
ANALYZE_CMD="echo ok"
BUILD_CHECK_CMD=""
LOG_DIR=".claude/logs"
EOF
}

# =============================================================================
# Baseline: simple value replacement works
# =============================================================================
echo "=== Baseline: simple value replacement ==="

BASE_CONF="${TEST_TMPDIR}/baseline.conf"
make_base_conf "$BASE_CONF"

_merge_preserved_values "$BASE_CONF" "TEST_CMD=\"npm test\""

result=$(grep "^TEST_CMD=" "$BASE_CONF" | cut -d= -f2- | tr -d '"')
if [[ "$result" == "npm test" ]]; then
    pass "baseline: simple value replaced correctly"
else
    fail "baseline: expected 'npm test', got '${result}'"
fi

# Key not in new config is silently ignored (no crash)
_merge_preserved_values "$BASE_CONF" "NONEXISTENT_KEY=\"value\""
pass "baseline: nonexistent key silently ignored (no crash)"

# =============================================================================
# Path value (contains /): |‑delimited sed must not break on forward slashes
# =============================================================================
echo "=== Path value with / ==="

PATH_CONF="${TEST_TMPDIR}/path.conf"
make_base_conf "$PATH_CONF"

_merge_preserved_values "$PATH_CONF" 'TEST_CMD="/usr/local/bin/pytest --tb=short"'

result=$(grep "^TEST_CMD=" "$PATH_CONF" | cut -d= -f2- | tr -d '"')
if [[ "$result" == "/usr/local/bin/pytest --tb=short" ]]; then
    pass "path value with /: preserved correctly (| delimiter handles / in value)"
else
    fail "path value with /: expected '/usr/local/bin/pytest --tb=short', got '${result}'"
fi

# Nested path
NESTED_CONF="${TEST_TMPDIR}/nested.conf"
make_base_conf "$NESTED_CONF"

_merge_preserved_values "$NESTED_CONF" 'LOG_DIR=".claude/logs/archive"'

result=$(grep "^LOG_DIR=" "$NESTED_CONF" | cut -d= -f2- | tr -d '"')
if [[ "$result" == ".claude/logs/archive" ]]; then
    pass "nested path value: preserved correctly"
else
    fail "nested path value: expected '.claude/logs/archive', got '${result}'"
fi

# =============================================================================
# Value containing | — the sed delimiter
# Reviewer note: "keys whose values contain | would break the sed -i s|...|...|"
# =============================================================================
echo "=== Value containing | (sed delimiter) ==="

PIPE_CONF="${TEST_TMPDIR}/pipe.conf"
make_base_conf "$PIPE_CONF"

# Capture exit code — sed will fail on extra | in value
pipe_exit=0
# Run in subshell so set -e doesn't abort this test process
(
    _merge_preserved_values "$PIPE_CONF" 'TEST_CMD="cmd1|cmd2"'
) 2>/dev/null || pipe_exit=$?

if [[ "$pipe_exit" -ne 0 ]]; then
    # sed errored — document as a known limitation
    fail "value with |: _merge_preserved_values fails (sed delimiter conflict) — see Bugs Found"
else
    # Check if the value was preserved correctly
    result=$(grep "^TEST_CMD=" "$PIPE_CONF" | cut -d= -f2- | tr -d '"')
    if [[ "$result" == "cmd1|cmd2" ]]; then
        pass "value with |: preserved correctly"
    else
        fail "value with |: got wrong value '${result}' (sed delimiter conflict silently corrupted)"
    fi
fi

# =============================================================================
# Value containing & — sed replacement backreference
# Reviewer note: "& would break the sed -i s|...|...| replacement"
# =============================================================================
echo "=== Value containing & (sed backreference) ==="

AMP_CONF="${TEST_TMPDIR}/amp.conf"
make_base_conf "$AMP_CONF"

# & in sed replacement means "the full match" — may silently produce wrong value
(
    _merge_preserved_values "$AMP_CONF" 'TEST_CMD="npm test && echo done"'
) 2>/dev/null || true

result=$(grep "^TEST_CMD=" "$AMP_CONF" | cut -d= -f2- | tr -d '"' || true)
if [[ "$result" == "npm test && echo done" ]]; then
    pass "value with &&: preserved correctly"
else
    fail "value with &&: got wrong value '${result}' (& interpreted as sed backreference) — see Bugs Found"
fi

# =============================================================================
# Empty inputs: no-op cases
# =============================================================================
echo "=== Empty inputs ==="

EMPTY_CONF="${TEST_TMPDIR}/empty.conf"
make_base_conf "$EMPTY_CONF"
orig_content=$(cat "$EMPTY_CONF")

_merge_preserved_values "$EMPTY_CONF" ""
new_content=$(cat "$EMPTY_CONF")
if [[ "$orig_content" == "$new_content" ]]; then
    pass "empty preserved: config file unchanged"
else
    fail "empty preserved: config file should be unchanged but was modified"
fi

# Nonexistent config file: function returns silently
_merge_preserved_values "/nonexistent/path/conf" "TEST_CMD=\"x\""
pass "nonexistent config file: returns silently without error"

# =============================================================================
# Multiple keys preserved in one call
# =============================================================================
echo "=== Multiple key preservation ==="

MULTI_CONF="${TEST_TMPDIR}/multi.conf"
make_base_conf "$MULTI_CONF"

preserved="$(printf 'TEST_CMD="pytest -v"\nANALYZE_CMD="ruff check ."')"
_merge_preserved_values "$MULTI_CONF" "$preserved"

test_result=$(grep "^TEST_CMD=" "$MULTI_CONF" | cut -d= -f2- | tr -d '"')
analyze_result=$(grep "^ANALYZE_CMD=" "$MULTI_CONF" | cut -d= -f2- | tr -d '"')

if [[ "$test_result" == "pytest -v" ]]; then
    pass "multiple keys: TEST_CMD preserved"
else
    fail "multiple keys: TEST_CMD expected 'pytest -v', got '${test_result}'"
fi

if [[ "$analyze_result" == "ruff check ." ]]; then
    pass "multiple keys: ANALYZE_CMD preserved"
else
    fail "multiple keys: ANALYZE_CMD expected 'ruff check .', got '${analyze_result}'"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
