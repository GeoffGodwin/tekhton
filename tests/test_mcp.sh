#!/usr/bin/env bash
# Test: lib/mcp.sh — MCP server lifecycle management (Serena integration)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs required by mcp.sh before sourcing
warn()  { :; }
log()   { :; }
error() { :; }

# Isolated temp directory
TMPDIR_BASE="$(mktemp -d)"
PROJECT_DIR="${TMPDIR_BASE}/project"
mkdir -p "${PROJECT_DIR}/.claude"
export PROJECT_DIR
export TEKHTON_HOME

trap 'rm -rf "$TMPDIR_BASE"' EXIT

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/mcp.sh"

# Helper: reset module state between tests
_reset_mcp_state() {
    _MCP_SERVER_RUNNING=false
    _MCP_SERVER_PID=""
    _MCP_CONFIG_PATH=""
    SERENA_MCP_AVAILABLE=false
    SERENA_ACTIVE=""
    SERENA_CONFIG_PATH=""
}

# Pre-create a dummy default config so _resolve_mcp_config succeeds in
# state-transition tests (exercises the "existing file" branch, not generation).
DUMMY_CONFIG="${PROJECT_DIR}/.claude/serena_mcp_config.json"
echo '{"mcpServers":{}}' > "$DUMMY_CONFIG"

# =============================================================================
# Initial state
# =============================================================================

echo "=== Initial state ==="

if ! is_mcp_running; then
    pass "is_mcp_running returns false initially"
else
    fail "is_mcp_running should return false initially"
fi

if ! check_mcp_health 2>/dev/null; then
    pass "check_mcp_health returns 1 when not running"
else
    fail "check_mcp_health should return 1 when not running"
fi

path=$(get_mcp_config_path)
if [[ -z "$path" ]]; then
    pass "get_mcp_config_path returns empty before start"
else
    fail "get_mcp_config_path should return empty before start, got: '${path}'"
fi

# =============================================================================
# start_mcp_server — SERENA_ENABLED=false (disabled)
# =============================================================================

echo "=== start_mcp_server: SERENA_ENABLED=false ==="

_reset_mcp_state
SERENA_ENABLED="false"
if start_mcp_server 2>/dev/null; then
    fail "start_mcp_server should return 1 when SERENA_ENABLED=false"
else
    pass "start_mcp_server returns 1 when SERENA_ENABLED=false"
fi

if ! is_mcp_running; then
    pass "state unchanged after failed start (SERENA_ENABLED=false)"
else
    fail "_MCP_SERVER_RUNNING should remain false when SERENA_ENABLED=false"
fi

if [[ "$SERENA_MCP_AVAILABLE" != "true" ]]; then
    pass "SERENA_MCP_AVAILABLE not set when SERENA_ENABLED=false"
else
    fail "SERENA_MCP_AVAILABLE should not be set when SERENA_ENABLED=false"
fi

# =============================================================================
# stop_mcp_server — idempotent when already stopped
# =============================================================================

echo "=== stop_mcp_server: idempotent ==="

_reset_mcp_state
if stop_mcp_server 2>/dev/null; then
    pass "stop_mcp_server returns 0 when already stopped"
else
    fail "stop_mcp_server should return 0 when already stopped"
fi

if stop_mcp_server 2>/dev/null; then
    pass "stop_mcp_server returns 0 on second call (idempotent)"
else
    fail "stop_mcp_server should return 0 on repeated calls"
fi

# =============================================================================
# Full state transitions (mocked CLI + path resolution; real config resolution)
# =============================================================================

echo "=== state transitions: start → is_mcp_running → check_mcp_health → stop ==="

# Mock only the external dependencies (claude CLI, filesystem paths for serena).
# _resolve_mcp_config is NOT mocked — it will find the DUMMY_CONFIG via the
# "existing file" branch, so no filesystem writes occur.
_cli_supports_mcp_config() { return 0; }
_resolve_serena_paths() {
    _SERENA_DIR="${TMPDIR_BASE}/serena"
    _SERENA_PYTHON="${TMPDIR_BASE}/serena/.venv/bin/python"
    return 0
}

_reset_mcp_state
SERENA_ENABLED="true"

if start_mcp_server 2>/dev/null; then
    pass "start_mcp_server returns 0 with mocked CLI and paths"
else
    fail "start_mcp_server should return 0 with mocked CLI and paths"
fi

if is_mcp_running; then
    pass "is_mcp_running returns true after start"
else
    fail "is_mcp_running should return true after start"
fi

if check_mcp_health 2>/dev/null; then
    pass "check_mcp_health returns 0 after start (no PID to kill-check)"
else
    fail "check_mcp_health should return 0 after start"
fi

path=$(get_mcp_config_path)
if [[ -n "$path" ]]; then
    pass "get_mcp_config_path returns non-empty path after start"
else
    fail "get_mcp_config_path should return a non-empty path after start"
fi

if [[ "$SERENA_MCP_AVAILABLE" == "true" ]]; then
    pass "SERENA_MCP_AVAILABLE=true after start"
else
    fail "SERENA_MCP_AVAILABLE should be 'true' after start, got: '${SERENA_MCP_AVAILABLE}'"
fi

if [[ "$SERENA_ACTIVE" == "true" ]]; then
    pass "SERENA_ACTIVE='true' after start"
else
    fail "SERENA_ACTIVE should be 'true' after start, got: '${SERENA_ACTIVE}'"
fi

# Stop and verify state is cleared
if stop_mcp_server 2>/dev/null; then
    pass "stop_mcp_server returns 0 after successful start"
else
    fail "stop_mcp_server should return 0"
fi

if ! is_mcp_running; then
    pass "is_mcp_running returns false after stop"
else
    fail "is_mcp_running should return false after stop"
fi

if [[ "$SERENA_MCP_AVAILABLE" == "false" ]]; then
    pass "SERENA_MCP_AVAILABLE=false after stop"
else
    fail "SERENA_MCP_AVAILABLE should be 'false' after stop, got: '${SERENA_MCP_AVAILABLE}'"
fi

if [[ -z "$SERENA_ACTIVE" ]]; then
    pass "SERENA_ACTIVE empty after stop"
else
    fail "SERENA_ACTIVE should be empty after stop, got: '${SERENA_ACTIVE}'"
fi

if ! check_mcp_health 2>/dev/null; then
    pass "check_mcp_health returns 1 after stop"
else
    fail "check_mcp_health should return 1 after stop"
fi

# =============================================================================
# start_mcp_server — CLI does not support --mcp-config
# =============================================================================

echo "=== start_mcp_server: CLI lacks --mcp-config support ==="

_cli_supports_mcp_config() { return 1; }

_reset_mcp_state
SERENA_ENABLED="true"
if start_mcp_server 2>/dev/null; then
    fail "start_mcp_server should return 1 when CLI lacks --mcp-config"
else
    pass "start_mcp_server returns 1 when CLI lacks --mcp-config"
fi

if ! is_mcp_running; then
    pass "state not changed when CLI lacks --mcp-config"
else
    fail "_MCP_SERVER_RUNNING should be false when CLI check fails"
fi

# =============================================================================
# start_mcp_server — Serena not installed
# =============================================================================

echo "=== start_mcp_server: Serena not installed ==="

_cli_supports_mcp_config() { return 0; }
_resolve_serena_paths() { return 1; }  # Simulates missing serena directory

_reset_mcp_state
SERENA_ENABLED="true"
if start_mcp_server 2>/dev/null; then
    fail "start_mcp_server should return 1 when Serena not installed"
else
    pass "start_mcp_server returns 1 when Serena not installed"
fi

if ! is_mcp_running; then
    pass "state not changed when Serena not installed"
else
    fail "_MCP_SERVER_RUNNING should be false when Serena not installed"
fi

# =============================================================================
# _resolve_mcp_config — explicit SERENA_CONFIG_PATH
# =============================================================================

echo "=== _resolve_mcp_config: explicit SERENA_CONFIG_PATH ==="

EXPLICIT_CONFIG="${TMPDIR_BASE}/explicit_mcp.json"
echo '{"mcpServers":{}}' > "$EXPLICIT_CONFIG"

_reset_mcp_state
SERENA_CONFIG_PATH="$EXPLICIT_CONFIG"

if _resolve_mcp_config 2>/dev/null; then
    pass "_resolve_mcp_config returns 0 with explicit SERENA_CONFIG_PATH"
else
    fail "_resolve_mcp_config should return 0 with explicit SERENA_CONFIG_PATH"
fi

if [[ "$_MCP_CONFIG_PATH" == "$EXPLICIT_CONFIG" ]]; then
    pass "_MCP_CONFIG_PATH set to explicit SERENA_CONFIG_PATH"
else
    fail "_MCP_CONFIG_PATH should equal SERENA_CONFIG_PATH, got: '${_MCP_CONFIG_PATH}'"
fi

# =============================================================================
# _resolve_mcp_config — existing default config (no generation)
# =============================================================================

echo "=== _resolve_mcp_config: existing default config ==="

_reset_mcp_state
# SERENA_CONFIG_PATH is empty, DUMMY_CONFIG exists at default location
SERENA_CONFIG_PATH=""

if _resolve_mcp_config 2>/dev/null; then
    pass "_resolve_mcp_config returns 0 with existing default config"
else
    fail "_resolve_mcp_config should return 0 when default config exists"
fi

if [[ "$_MCP_CONFIG_PATH" == "$DUMMY_CONFIG" ]]; then
    pass "_MCP_CONFIG_PATH set to default config location"
else
    fail "_MCP_CONFIG_PATH should be ${DUMMY_CONFIG}, got: '${_MCP_CONFIG_PATH}'"
fi

# =============================================================================
# Config generation roundtrip (template substitution)
# =============================================================================

echo "=== config generation roundtrip ==="

# Create fake serena installation
SERENA_INSTALL_DIR="${TMPDIR_BASE}/serena"
mkdir -p "${SERENA_INSTALL_DIR}/.venv/bin"
touch "${SERENA_INSTALL_DIR}/.venv/bin/python"

# Remove existing default config to force generation
rm -f "$DUMMY_CONFIG"

_reset_mcp_state
SERENA_CONFIG_PATH=""
SERENA_PATH="${SERENA_INSTALL_DIR}"
SERENA_LANGUAGE_SERVERS="python,javascript"
_SERENA_DIR="${SERENA_INSTALL_DIR}"
_SERENA_PYTHON="${SERENA_INSTALL_DIR}/.venv/bin/python"

if _resolve_mcp_config 2>/dev/null; then
    pass "_resolve_mcp_config returns 0 generating from template"
else
    fail "_resolve_mcp_config should return 0 generating from template"
fi

if [[ -f "$DUMMY_CONFIG" ]]; then
    pass "generated MCP config file created at default location"
else
    fail "generated MCP config file should exist at ${DUMMY_CONFIG}"
fi

if grep -q "${SERENA_INSTALL_DIR}/.venv/bin/python" "$DUMMY_CONFIG" 2>/dev/null; then
    pass "config contains SERENA_PYTHON substitution"
else
    fail "config should contain SERENA_PYTHON value"
fi

if grep -q "${PROJECT_DIR}" "$DUMMY_CONFIG" 2>/dev/null; then
    pass "config contains PROJECT_DIR substitution"
else
    fail "config should contain PROJECT_DIR value"
fi

if grep -q "python,javascript" "$DUMMY_CONFIG" 2>/dev/null; then
    pass "config contains LANGUAGE_SERVERS substitution"
else
    fail "config should contain LANGUAGE_SERVERS value"
fi

if [[ "$_MCP_CONFIG_PATH" == "$DUMMY_CONFIG" ]]; then
    pass "_MCP_CONFIG_PATH set to generated config path"
else
    fail "_MCP_CONFIG_PATH should be ${DUMMY_CONFIG}, got: '${_MCP_CONFIG_PATH}'"
fi

# Second call uses the existing generated file (no re-generation)
old_mcp_path="$_MCP_CONFIG_PATH"
_MCP_CONFIG_PATH=""
if _resolve_mcp_config 2>/dev/null; then
    pass "_resolve_mcp_config returns 0 on second call (uses existing file)"
else
    fail "_resolve_mcp_config should return 0 when generated file already exists"
fi

if [[ "$_MCP_CONFIG_PATH" == "$old_mcp_path" ]]; then
    pass "_resolve_mcp_config reuses existing generated file on second call"
else
    fail "_MCP_CONFIG_PATH should match first call result, got: '${_MCP_CONFIG_PATH}'"
fi

# =============================================================================
# check_serena_available — SERENA_ENABLED=false
# =============================================================================

echo "=== check_serena_available: SERENA_ENABLED=false ==="

SERENA_ENABLED="false"
if check_serena_available 2>/dev/null; then
    fail "check_serena_available should return 1 when SERENA_ENABLED=false"
else
    pass "check_serena_available returns 1 when SERENA_ENABLED=false"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
