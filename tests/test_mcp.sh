#!/usr/bin/env bash
# =============================================================================
# Test: lib/mcp.sh — MCP server lifecycle and health check functions
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
echo "=== Test: check_mcp_health with server not running ==="

_MCP_SERVER_RUNNING=false
check_mcp_health || result=$?
result=${result:-0}
assert_exit_code "check_mcp_health returns 1 when not running" 1 "$result"

# =============================================================================
echo "=== Test: check_mcp_health with server running ==="

_MCP_SERVER_RUNNING=true
_MCP_SERVER_PID=""
check_mcp_health
result=$?
assert_exit_code "check_mcp_health returns 0 when running (no PID)" 0 "$result"

# =============================================================================
echo "=== Test: is_mcp_running when true ==="

_MCP_SERVER_RUNNING=true
is_mcp_running
result=$?
assert_exit_code "is_mcp_running returns 0 when true" 0 "$result"

# =============================================================================
echo "=== Test: is_mcp_running when false ==="

_MCP_SERVER_RUNNING=false
is_mcp_running || result=$?
result=${result:-0}
assert_exit_code "is_mcp_running returns 1 when false" 1 "$result"

# =============================================================================
echo "=== Test: start_mcp_server with SERENA_ENABLED=false ==="

SERENA_ENABLED=false
_MCP_SERVER_RUNNING=false
start_mcp_server || result=$?
result=${result:-0}
assert_exit_code "start_mcp_server returns 1 when SERENA_ENABLED=false" 1 "$result"

# =============================================================================
echo "=== Test: start_mcp_server when Serena path not found ==="

SERENA_ENABLED=true
SERENA_PATH="/nonexistent/serena"
_MCP_SERVER_RUNNING=false
_CLI_MCP_CONFIG_SUPPORTED="1"
start_mcp_server || result=$?
result=${result:-0}
assert_exit_code "start_mcp_server returns 1 when Serena path missing" 1 "$result"

# =============================================================================
echo "=== Test: start_mcp_server with everything set up ==="

mkdir -p "${TMPDIR}/.claude/serena/.venv/bin"
mkdir -p "${TMPDIR}/.claude"
touch "${TMPDIR}/.claude/serena/.venv/bin/python"

SERENA_ENABLED=true
SERENA_PATH=".claude/serena"
_MCP_SERVER_RUNNING=false
_CLI_MCP_CONFIG_SUPPORTED="1"
_SERENA_DIR=""
_SERENA_PYTHON=""
_MCP_CONFIG_PATH=""

start_mcp_server
result=$?
assert_exit_code "start_mcp_server succeeds with valid setup" 0 "$result"

# Verify state was set
if [ "$_MCP_SERVER_RUNNING" = "true" ]; then
    echo "  PASS: start_mcp_server sets _MCP_SERVER_RUNNING"
    PASS=$((PASS + 1))
else
    echo "  FAIL: start_mcp_server did not set _MCP_SERVER_RUNNING"
    FAIL=$((FAIL + 1))
fi

if [ "$SERENA_MCP_AVAILABLE" = "true" ]; then
    echo "  PASS: start_mcp_server sets SERENA_MCP_AVAILABLE"
    PASS=$((PASS + 1))
else
    echo "  FAIL: start_mcp_server did not set SERENA_MCP_AVAILABLE"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
echo "=== Test: stop_mcp_server ==="

_MCP_SERVER_RUNNING=true
SERENA_MCP_AVAILABLE=true
SERENA_ACTIVE="true"

stop_mcp_server
result=$?
assert_exit_code "stop_mcp_server returns 0" 0 "$result"

if [ "$_MCP_SERVER_RUNNING" = "false" ]; then
    echo "  PASS: stop_mcp_server sets _MCP_SERVER_RUNNING=false"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stop_mcp_server did not set _MCP_SERVER_RUNNING=false"
    FAIL=$((FAIL + 1))
fi

if [ "$SERENA_MCP_AVAILABLE" = "false" ]; then
    echo "  PASS: stop_mcp_server sets SERENA_MCP_AVAILABLE=false"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stop_mcp_server did not set SERENA_MCP_AVAILABLE=false"
    FAIL=$((FAIL + 1))
fi

if [ "$SERENA_ACTIVE" = "" ]; then
    echo "  PASS: stop_mcp_server clears SERENA_ACTIVE"
    PASS=$((PASS + 1))
else
    echo "  FAIL: stop_mcp_server did not clear SERENA_ACTIVE (got: '$SERENA_ACTIVE')"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
echo "=== Test: get_mcp_config_path ==="

_MCP_CONFIG_PATH="/path/to/config.json"
path=$(get_mcp_config_path)
if [ "$path" = "/path/to/config.json" ]; then
    echo "  PASS: get_mcp_config_path returns config path"
    PASS=$((PASS + 1))
else
    echo "  FAIL: get_mcp_config_path returned '$path', expected '/path/to/config.json'"
    FAIL=$((FAIL + 1))
fi

_MCP_CONFIG_PATH=""
path=$(get_mcp_config_path)
if [ "$path" = "" ]; then
    echo "  PASS: get_mcp_config_path returns empty when not set"
    PASS=$((PASS + 1))
else
    echo "  FAIL: get_mcp_config_path returned '$path', expected empty"
    FAIL=$((FAIL + 1))
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
