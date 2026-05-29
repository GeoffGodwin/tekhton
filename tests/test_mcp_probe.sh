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
echo "=== AC8: VERSION floor — m28.2 opened at 4.27.6; m28 closes at 4.28.0+ ==="

# Pipeline finalize hooks may patch-bump VERSION between stages, and m28.3
# closes the arc by promoting the [Unreleased] entries to a clean minor at
# 4.28.0. Either the in-flight 4.27.x floor (>= 6) OR any 4.MM.* >= 4.28
# satisfies this AC.
actual_version=$(tr -d '[:space:]' < "${TEKHTON_HOME}/VERSION" 2>/dev/null || echo "MISSING")
version_major="${actual_version%%.*}"
version_rest="${actual_version#*.}"
version_minor="${version_rest%%.*}"
version_patch="${actual_version##*.}"

ok=false
if [[ "$version_major" == "4" ]] && [[ "$version_minor" == "27" ]] && [[ "$version_patch" -ge 6 ]]; then
    ok=true
elif [[ "$version_major" == "4" ]] && [[ "$version_minor" -ge 28 ]]; then
    ok=true
fi

if [[ "$ok" == "true" ]]; then
    _pass "VERSION at or above m28.2 floor — current: ${actual_version}"
else
    _fail "VERSION reads '${actual_version}', expected 4.27.x (x>=6) or 4.>=28.x"
fi

# =============================================================================
echo "=== AC9: CHANGELOG has m28.2 ### Changed entry (Unreleased or promoted) ==="

CHANGELOG="${TEKHTON_HOME}/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
    _fail "CHANGELOG.md not found at ${CHANGELOG}"
else
    # m28.3 close promotes the m28.x entries from [Unreleased] to [4.28.0].
    # Accept either: (a) entry still under [Unreleased] (mid-arc), or
    # (b) entry under any versioned ## [N.NN.N] block (post-promotion).
    unreleased_block=$(awk '/^## \[Unreleased\]/{found=1; next} found && /^## \[[0-9]/{exit} found{print}' "$CHANGELOG")
    promoted_block=$(awk '/^## \[4\.[0-9]+\.[0-9]+\]/{found=1; next} found && /^## \[/{exit} found{print}' "$CHANGELOG")

    if echo "$unreleased_block" | grep -q "m28\.2" \
        || echo "$promoted_block" | grep -q "m28\.2"; then
        _pass "CHANGELOG has m28.2 entry (Unreleased or promoted)"
    else
        _fail "CHANGELOG does not have m28.2 entry in either block"
    fi

    if echo "$unreleased_block" | grep -qi "probe" \
        || echo "$promoted_block" | grep -qi "probe"; then
        _pass "CHANGELOG m28.2 entry mentions probe"
    else
        _fail "CHANGELOG m28.2 entry does not mention probe"
    fi

    if echo "$unreleased_block" | grep -q "^### Changed" \
        || echo "$promoted_block" | grep -q "^### Changed"; then
        _pass "CHANGELOG has ### Changed section (Unreleased or promoted)"
    else
        _fail "CHANGELOG is missing ### Changed section in both blocks"
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
