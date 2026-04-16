#!/usr/bin/env bash
# Test: Config validation gate (Milestone 83)
# Tests validate_config() checks: placeholder detection, no-op commands,
# missing files, model names, config version, manifest validation.
# shellcheck disable=SC2034
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging/color functions
RED="" GREEN="" YELLOW="" CYAN="" BOLD="" NC=""
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }
_is_utf8_terminal() { return 1; }

# Stub milestone DAG functions (avoid sourcing the full DAG)
_DAG_LOADED=false
has_milestone_manifest() { return 1; }
load_manifest() { return 1; }
validate_manifest() { return 0; }

# Source validate_config
# shellcheck source=../lib/validate_config.sh
source "${TEKHTON_HOME}/lib/validate_config.sh"

echo "=== validate_config: healthy config returns 0 ==="

# Set up a valid config environment
PROJECT_NAME="test-project"
PROJECT_DESCRIPTION="A real project description"
TEST_CMD="npm test"
ANALYZE_CMD="npx eslint ."
ARCHITECTURE_FILE=""
DESIGN_FILE=""
TEKHTON_CONFIG_VERSION="3.83"
PIPELINE_STATE_FILE="${TEST_TMPDIR}/.claude/PIPELINE_STATE.md"

# Create agent role files
mkdir -p "${TEST_TMPDIR}/.claude/agents"
for f in coder.md reviewer.md tester.md jr-coder.md; do
    echo "# Role" > "${TEST_TMPDIR}/.claude/agents/$f"
done
CODER_ROLE_FILE=".claude/agents/coder.md"
REVIEWER_ROLE_FILE=".claude/agents/reviewer.md"
TESTER_ROLE_FILE=".claude/agents/tester.md"
JR_CODER_ROLE_FILE=".claude/agents/jr-coder.md"

# Set model names
CLAUDE_STANDARD_MODEL="claude-sonnet-4-6"
CLAUDE_CODER_MODEL="claude-opus-4-6"
CLAUDE_JR_CODER_MODEL="claude-haiku-4-5"
CLAUDE_REVIEWER_MODEL="claude-sonnet-4-6"
CLAUDE_TESTER_MODEL="claude-haiku-4-5"
CLAUDE_SCOUT_MODEL="claude-haiku-4-5"

rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Healthy config returns exit code 0"
else
    fail "Healthy config returned exit code $rc (expected 0)"
fi
if echo "$output" | grep -q "0 errors"; then
    pass "Output reports 0 errors"
else
    fail "Output did not report 0 errors: $(echo "$output" | tail -1)"
fi

echo ""
echo "=== validate_config: missing PROJECT_NAME returns 1 ==="

PROJECT_NAME=""
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "Empty PROJECT_NAME returns exit code 1"
else
    fail "Empty PROJECT_NAME returned exit code $rc (expected 1)"
fi
PROJECT_NAME="test-project"

echo ""
echo "=== validate_config: placeholder PROJECT_DESCRIPTION is a warning ==="

PROJECT_DESCRIPTION="(fill in a one-line description)"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Placeholder description is only a warning (exit 0)"
else
    fail "Placeholder description caused error (exit $rc, expected 0)"
fi
if echo "$output" | grep -qE "[0-9]+ warnings" && ! echo "$output" | grep -q "0 warnings"; then
    pass "Placeholder description counted as warning"
else
    fail "Placeholder description not counted as warning"
fi
PROJECT_DESCRIPTION="A real description"

echo ""
echo "=== validate_config: no-op TEST_CMD is a warning ==="

TEST_CMD="true"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "No-op TEST_CMD is only a warning (exit 0)"
else
    fail "No-op TEST_CMD caused error (exit $rc)"
fi
if echo "$output" | grep -q "TEST_CMD is no-op"; then
    pass "No-op TEST_CMD warning message present"
else
    fail "No-op TEST_CMD warning message missing"
fi
TEST_CMD="npm test"

echo ""
echo "=== validate_config: bare colon TEST_CMD is a warning ==="

TEST_CMD=":"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Bare colon TEST_CMD is only a warning (exit 0)"
else
    fail "Bare colon TEST_CMD caused error (exit $rc)"
fi
if echo "$output" | grep -q "TEST_CMD is no-op"; then
    pass "Bare colon TEST_CMD warning message present"
else
    fail "Bare colon TEST_CMD warning message missing"
fi
TEST_CMD="npm test"

echo ""
echo "=== validate_config: missing role files is an error ==="

CODER_ROLE_FILE=".claude/agents/nonexistent.md"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 1 ]]; then
    pass "Missing role file returns exit code 1"
else
    fail "Missing role file returned exit code $rc (expected 1)"
fi
CODER_ROLE_FILE=".claude/agents/coder.md"

echo ""
echo "=== validate_config: missing TEKHTON_CONFIG_VERSION is a warning ==="

TEKHTON_CONFIG_VERSION=""
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Missing config version is only a warning (exit 0)"
else
    fail "Missing config version caused error (exit $rc)"
fi
if echo "$output" | grep -q "TEKHTON_CONFIG_VERSION absent"; then
    pass "Config version warning message present"
else
    fail "Config version warning message missing"
fi
TEKHTON_CONFIG_VERSION="3.83"

echo ""
echo "=== validate_config: unrecognized model name is a warning ==="

CLAUDE_CODER_MODEL="gpt-4o"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Unrecognized model is only a warning (exit 0)"
else
    fail "Unrecognized model caused error (exit $rc)"
fi
if echo "$output" | grep -q "unrecognized model"; then
    pass "Unrecognized model warning present"
else
    fail "Unrecognized model warning missing"
fi
CLAUDE_CODER_MODEL="claude-opus-4-6"

echo ""
echo "=== validate_config: stale PIPELINE_STATE.md is a warning ==="

mkdir -p "$(dirname "$PIPELINE_STATE_FILE")"
echo "## Stage: coder" > "$PIPELINE_STATE_FILE"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Stale pipeline state is only a warning (exit 0)"
else
    fail "Stale pipeline state caused error (exit $rc)"
fi
rm -f "$PIPELINE_STATE_FILE"

echo ""
echo "=== validate_config: ARCHITECTURE_FILE pointing to missing file ==="

ARCHITECTURE_FILE="ARCHITECTURE.md"
rc=0
output=$(validate_config 2>/dev/null) || rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "Missing architecture file is only a warning (exit 0)"
else
    fail "Missing architecture file caused error (exit $rc)"
fi
if echo "$output" | grep -q "file not found on disk"; then
    pass "Missing file warning present"
else
    fail "Missing file warning missing"
fi
ARCHITECTURE_FILE=""

echo ""
echo "=== validate_config_summary: sets _VC totals ==="

_VC_PASSES=0; _VC_WARNINGS=0; _VC_ERRORS=0
validate_config_summary 2>/dev/null
if [[ "${_VC_PASSES:-0}" -gt 0 ]]; then
    pass "validate_config_summary sets _VC_PASSES (${_VC_PASSES})"
else
    fail "validate_config_summary did not set _VC_PASSES"
fi

echo ""
echo "════════════════════════════════════════"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
exit "$FAIL"
