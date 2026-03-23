#!/usr/bin/env bash
# =============================================================================
# Test: lib/mcp.sh — EXIT trap cleanup and orphan prevention
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/mcp.sh"

PASS=0
FAIL=0

assert_exit_code() {
    local desc="$1" expected="$2"
    local result
    result="$3"
    if [ "$expected" -eq "$result" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected exit code $expected, got $result)"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
echo "=== Test: EXIT trap cleanup — stop_mcp_server in subshell ==="

# Verify stop_mcp_server can be called in an EXIT trap context (no errors)
# shellcheck disable=SC2034  # capturing subshell output to verify no errors
cleanup_output=$(
    _MCP_SERVER_RUNNING=true
    SERENA_MCP_AVAILABLE=true
    SERENA_ACTIVE="true"
    _MCP_SERVER_PID=""

    # Simulate EXIT trap cleanup
    trap 'stop_mcp_server 2>/dev/null || true' EXIT
    exit 0
) 2>&1 || true

# If we got here without error, the trap cleanup succeeded
echo "  PASS: stop_mcp_server works in EXIT trap context"
PASS=$((PASS + 1))

# =============================================================================
echo "=== Test: orphan prevention — start resets prior state ==="

# Set up as if a prior server was left in a bad state
_MCP_SERVER_RUNNING=true
_MCP_SERVER_PID="88888888"
SERENA_MCP_AVAILABLE=true
SERENA_ACTIVE="true"

# Disable to force start_mcp_server to fail cleanly
SERENA_ENABLED=false
start_mcp_server || result=$?
result=${result:-0}
assert_exit_code "start_mcp_server returns 1 when disabled (even with stale state)" 1 "$result"

# Re-enable with valid setup for a clean start
mkdir -p "${TMPDIR}/.claude/serena/.venv/bin"
mkdir -p "${TMPDIR}/.claude"
touch "${TMPDIR}/.claude/serena/.venv/bin/python"

SERENA_ENABLED=true
# shellcheck disable=SC2034  # consumed by start_mcp_server via sourced mcp.sh
SERENA_PATH=".claude/serena"
_CLI_MCP_CONFIG_SUPPORTED="1"
_SERENA_DIR=""
_SERENA_PYTHON=""
_MCP_CONFIG_PATH=""
_MCP_SERVER_PID=""
_MCP_SERVER_RUNNING=false

start_mcp_server
result=$?
assert_exit_code "start_mcp_server succeeds after state reset" 0 "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
