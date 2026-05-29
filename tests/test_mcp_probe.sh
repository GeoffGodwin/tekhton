#!/usr/bin/env bash
# =============================================================================
# Test: m28.2 Serena startup probe — AC coverage
#
# AC2  — _probe_serena_startup returns 1 when _SERENA_BIN is empty
# AC4  — start_mcp_server returns 1 and SERENA_ACTIVE="" on probe failure;
#         SERENA_MCP_AVAILABLE=false; _MCP_SERVER_RUNNING unchanged (false)
# AC8  — VERSION is 4.27.x (x >= 6, m28.2 floor)
# AC9  — CHANGELOG has m28.2 ### Changed entry under [Unreleased]
#
# Note: direct _probe_serena_startup tests against /usr/bin/false,
# /usr/bin/echo, and a hanging script are intentionally deferred to m28.3
# (Seeds Forward in the milestone spec). This file covers the ACs reachable
# without those stubs: empty-bin guard and the full probe-failure path
# through start_mcp_server.
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
_pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
_fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected '${expected}', got '${actual}')"
        FAIL=$((FAIL + 1))
    fi
}

# =============================================================================
echo "=== AC2: _probe_serena_startup returns 1 when _SERENA_BIN is empty ==="

_SERENA_BIN=""
result=0
_probe_serena_startup || result=$?

if [[ "$result" -eq 1 ]]; then
    _pass "_probe_serena_startup returns 1 when _SERENA_BIN=''"
else
    _fail "_probe_serena_startup returned ${result}, expected 1 when _SERENA_BIN=''"
fi

# =============================================================================
echo "=== AC4: start_mcp_server returns 1 and SERENA_ACTIVE=\"\" on probe failure ==="

# Build a complete Serena directory with a failing binary (exits 1).
# A pre-existing MCP config file bypasses template generation so the test
# works without a Tekhton tools/ setup.
PROBE_FAIL_DIR="${TMPDIR}/probe_fail"
mkdir -p "${PROBE_FAIL_DIR}/.claude/serena/.venv/bin"
touch "${PROBE_FAIL_DIR}/.claude/serena/.venv/bin/python"

# Binary that always exits 1 — probe must reject it regardless of arguments.
printf '#!/bin/sh\nexit 1\n' > "${PROBE_FAIL_DIR}/.claude/serena/.venv/bin/serena"
chmod +x "${PROBE_FAIL_DIR}/.claude/serena/.venv/bin/serena"

# Pre-existing config so _resolve_mcp_config returns 0 on the default-path branch.
printf '{"mcpServers":{}}\n' > "${PROBE_FAIL_DIR}/.claude/serena_mcp_config.json"

PROJECT_DIR="${PROBE_FAIL_DIR}"
SERENA_ENABLED=true
SERENA_PATH=".claude/serena"
_CLI_MCP_CONFIG_SUPPORTED="1"
_SERENA_DIR=""
_SERENA_PYTHON=""
_SERENA_BIN=""
_MCP_CONFIG_PATH=""
_MCP_SERVER_RUNNING=false
SERENA_MCP_AVAILABLE=false
SERENA_ACTIVE=""
SERENA_CONFIG_PATH=""

result=0
start_mcp_server 2>/dev/null || result=$?

if [[ "$result" -eq 1 ]]; then
    _pass "start_mcp_server returns 1 when probe fails"
else
    _fail "start_mcp_server returned ${result}, expected 1 when probe fails"
fi

assert_eq "SERENA_ACTIVE is empty string after probe failure" "" "$SERENA_ACTIVE"
assert_eq "SERENA_MCP_AVAILABLE is false after probe failure" "false" "$SERENA_MCP_AVAILABLE"
assert_eq "_MCP_SERVER_RUNNING is false after probe failure" "false" "$_MCP_SERVER_RUNNING"

# =============================================================================
echo "=== AC8: VERSION is 4.27.x (x >= 6, m28.2 floor) ==="

# Pipeline finalize hooks may patch-bump VERSION beyond 4.27.6 (e.g. to 4.27.7
# as observed post-m28.2). Assert the m28.2 floor: major.minor=4.27, patch>=6.
actual_version=$(tr -d '[:space:]' < "${TEKHTON_HOME}/VERSION" 2>/dev/null || echo "MISSING")
version_major_minor="${actual_version%.*}"
version_patch="${actual_version##*.}"

if [[ "$version_major_minor" == "4.27" ]] && [[ "$version_patch" -ge 6 ]]; then
    _pass "VERSION is 4.27.x (x >= 6) — current: ${actual_version}"
else
    _fail "VERSION reads '${actual_version}', expected 4.27.x where x >= 6"
fi

# =============================================================================
echo "=== AC9: CHANGELOG has m28.2 ### Changed entry under [Unreleased] ==="

CHANGELOG="${TEKHTON_HOME}/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
    _fail "CHANGELOG.md not found at ${CHANGELOG}"
else
    unreleased_block=$(awk '/^## \[Unreleased\]/{found=1; next} found && /^## \[[0-9]/{exit} found{print}' "$CHANGELOG")

    if echo "$unreleased_block" | grep -q "m28\.2"; then
        _pass "CHANGELOG [Unreleased] block contains m28.2 tag"
    else
        _fail "CHANGELOG [Unreleased] block does not contain m28.2 tag"
    fi

    if echo "$unreleased_block" | grep -qi "probe"; then
        _pass "CHANGELOG m28.2 entry mentions probe"
    else
        _fail "CHANGELOG m28.2 entry does not mention probe"
    fi

    if echo "$unreleased_block" | grep -q "^### Changed"; then
        _pass "CHANGELOG [Unreleased] block has ### Changed section"
    else
        _fail "CHANGELOG [Unreleased] block is missing ### Changed section"
    fi
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
