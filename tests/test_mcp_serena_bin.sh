#!/usr/bin/env bash
# =============================================================================
# Test: m28.1 Serena template + resolver acceptance-criteria coverage
#
# AC1  — template contains start-mcp-server, not python -m serena
# AC2  — _SERENA_BIN resolved for POSIX (.venv/bin/serena),
#         Windows (.venv/Scripts/serena.exe), and absent (returns 1)
# AC3  — _resolve_mcp_config substitutes {{SERENA_BIN}}, no placeholder remains
# AC4  — no {{SERENA_PYTHON}} in template, lib/mcp.sh, or tools/setup_serena.sh
# AC5  — generated config is valid JSON
# AC8  — VERSION reads 4.27.5
# AC9  — CHANGELOG has m28.1 Fixed entry under [Unreleased]
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

TEMPLATE="${TEKHTON_HOME}/tools/serena_config_template.json"

# =============================================================================
echo "=== AC1: Template contains 'start-mcp-server' ==="

if grep -q "start-mcp-server" "$TEMPLATE"; then
    _pass "template contains 'start-mcp-server'"
else
    _fail "template does not contain 'start-mcp-server'"
fi

# =============================================================================
echo "=== AC1: Template does NOT contain '\"-m\", \"serena\"' ==="

if grep -q '"-m", "serena"' "$TEMPLATE"; then
    _fail "template still contains '\"-m\", \"serena\"'"
else
    _pass "template does not contain '\"-m\", \"serena\"'"
fi

# =============================================================================
echo "=== AC4: No {{SERENA_PYTHON}} in tools/serena_config_template.json ==="

if grep -q '{{SERENA_PYTHON}}' "$TEMPLATE"; then
    _fail "template still contains {{SERENA_PYTHON}}"
else
    _pass "template does not contain {{SERENA_PYTHON}}"
fi

# =============================================================================
echo "=== AC4: No {{SERENA_PYTHON}} in lib/mcp.sh ==="

if grep -q '{{SERENA_PYTHON}}' "${TEKHTON_HOME}/lib/mcp.sh"; then
    _fail "lib/mcp.sh still contains {{SERENA_PYTHON}}"
else
    _pass "lib/mcp.sh does not contain {{SERENA_PYTHON}}"
fi

# =============================================================================
echo "=== AC4: No {{SERENA_PYTHON}} in tools/setup_serena.sh ==="

if grep -q '{{SERENA_PYTHON}}' "${TEKHTON_HOME}/tools/setup_serena.sh"; then
    _fail "tools/setup_serena.sh still contains {{SERENA_PYTHON}}"
else
    _pass "tools/setup_serena.sh does not contain {{SERENA_PYTHON}}"
fi

# =============================================================================
echo "=== AC2: _SERENA_BIN declared and empty at module scope ==="

# Sourcing mcp.sh must have declared _SERENA_BIN="" at module scope
if [[ "${_SERENA_BIN+set}" == "set" ]] && [[ -z "$_SERENA_BIN" ]]; then
    _pass "_SERENA_BIN is declared and empty at module scope"
else
    _fail "_SERENA_BIN not properly declared at module scope (value: '${_SERENA_BIN:-UNSET}')"
fi

# =============================================================================
echo "=== AC2: _resolve_serena_paths resolves POSIX .venv/bin/serena ==="

POSIX_DIR="${TMPDIR}/posix_serena"
mkdir -p "${POSIX_DIR}/.venv/bin"
touch "${POSIX_DIR}/.venv/bin/python"
touch "${POSIX_DIR}/.venv/bin/serena"

_SERENA_BIN=""
_SERENA_PYTHON=""
_SERENA_DIR=""
SERENA_PATH="${POSIX_DIR}"

result=0
_resolve_serena_paths || result=$?

if [[ "$result" -eq 0 ]]; then
    _pass "_resolve_serena_paths returns 0 for POSIX layout"
else
    _fail "_resolve_serena_paths returned $result for POSIX layout (expected 0)"
fi

expected="${POSIX_DIR}/.venv/bin/serena"
if [[ "$_SERENA_BIN" == "$expected" ]]; then
    _pass "_SERENA_BIN set to POSIX bin/serena path"
else
    _fail "_SERENA_BIN='${_SERENA_BIN}', expected '${expected}'"
fi

# =============================================================================
echo "=== AC2: _resolve_serena_paths resolves Windows .venv/Scripts/serena.exe ==="

WIN_DIR="${TMPDIR}/win_serena"
mkdir -p "${WIN_DIR}/.venv/Scripts"
touch "${WIN_DIR}/.venv/Scripts/python.exe"
touch "${WIN_DIR}/.venv/Scripts/serena.exe"

_SERENA_BIN=""
_SERENA_PYTHON=""
_SERENA_DIR=""
SERENA_PATH="${WIN_DIR}"

result=0
_resolve_serena_paths || result=$?

if [[ "$result" -eq 0 ]]; then
    _pass "_resolve_serena_paths returns 0 for Windows layout"
else
    _fail "_resolve_serena_paths returned $result for Windows layout (expected 0)"
fi

expected="${WIN_DIR}/.venv/Scripts/serena.exe"
if [[ "$_SERENA_BIN" == "$expected" ]]; then
    _pass "_SERENA_BIN set to Windows Scripts/serena.exe path"
else
    _fail "_SERENA_BIN='${_SERENA_BIN}', expected '${expected}'"
fi

# =============================================================================
echo "=== AC2: _resolve_serena_paths returns 1 when serena binary absent ==="

NO_BIN_DIR="${TMPDIR}/no_bin_serena"
mkdir -p "${NO_BIN_DIR}/.venv/bin"
touch "${NO_BIN_DIR}/.venv/bin/python"
# No serena binary in bin/ or Scripts/

_SERENA_BIN=""
_SERENA_PYTHON=""
_SERENA_DIR=""
SERENA_PATH="${NO_BIN_DIR}"

result=0
_resolve_serena_paths || result=$?

if [[ "$result" -eq 1 ]]; then
    _pass "_resolve_serena_paths returns 1 when serena binary absent"
else
    _fail "_resolve_serena_paths returned $result, expected 1 when serena binary absent"
fi

if [[ -z "$_SERENA_BIN" ]]; then
    _pass "_SERENA_BIN remains empty when binary absent"
else
    _fail "_SERENA_BIN='${_SERENA_BIN}' despite missing binary"
fi

# =============================================================================
echo "=== AC3+AC5: _resolve_mcp_config substitutes {{SERENA_BIN}}, valid JSON ==="

GEN_DIR="${TMPDIR}/gen_serena"
mkdir -p "${GEN_DIR}/.venv/bin"
touch "${GEN_DIR}/.venv/bin/python"
touch "${GEN_DIR}/.venv/bin/serena"

# Pre-resolve paths
_SERENA_BIN=""
_SERENA_PYTHON=""
_SERENA_DIR=""
SERENA_PATH="${GEN_DIR}"
_resolve_serena_paths

# Clear any prior generated config so generation is forced
rm -f "${TMPDIR}/.claude/serena_mcp_config.json" 2>/dev/null || true
_MCP_CONFIG_PATH=""
SERENA_CONFIG_PATH=""
SERENA_LANGUAGE_SERVERS="auto"

result=0
_resolve_mcp_config || result=$?
GENERATED="${TMPDIR}/.claude/serena_mcp_config.json"

if [[ "$result" -eq 0 ]] && [[ -f "$GENERATED" ]]; then
    _pass "_resolve_mcp_config generated config file"
else
    _fail "_resolve_mcp_config failed (rc=$result, file exists=$(test -f "$GENERATED" && echo yes || echo no))"
fi

if [[ -f "$GENERATED" ]]; then
    # AC3: no {{SERENA_BIN}} placeholder in generated output
    if grep -q '{{SERENA_BIN}}' "$GENERATED"; then
        _fail "generated config still contains {{SERENA_BIN}} placeholder"
    else
        _pass "{{SERENA_BIN}} placeholder fully substituted in generated config"
    fi

    # AC3: actual binary path present
    expected_bin="${GEN_DIR}/.venv/bin/serena"
    if grep -qF "$expected_bin" "$GENERATED"; then
        _pass "generated config contains the resolved serena binary path"
    else
        _fail "generated config does not contain expected path '${expected_bin}'"
    fi

    # AC3: no {{SERENA_PYTHON}} in generated output
    if grep -q '{{SERENA_PYTHON}}' "$GENERATED"; then
        _fail "generated config contains {{SERENA_PYTHON}} placeholder"
    else
        _pass "generated config does not contain {{SERENA_PYTHON}} placeholder"
    fi

    # No other unresolved {{...}} placeholders
    if grep -qE '\{\{[A-Z_]+\}\}' "$GENERATED"; then
        unresolved=$(grep -oE '\{\{[A-Z_]+\}\}' "$GENERATED" | sort -u | tr '\n' ' ')
        _fail "generated config has unresolved placeholders: ${unresolved}"
    else
        _pass "no unresolved placeholders remain in generated config"
    fi

    # Generated config contains start-mcp-server (the command that replaced python -m serena)
    if grep -q "start-mcp-server" "$GENERATED"; then
        _pass "generated config references start-mcp-server command"
    else
        _fail "generated config does not reference start-mcp-server"
    fi

    # AC5: JSON validation
    if command -v python3 &>/dev/null; then
        if python3 -m json.tool "$GENERATED" >/dev/null 2>&1; then
            _pass "generated config is valid JSON (python3 -m json.tool)"
        else
            _fail "generated config failed JSON validation (python3 -m json.tool)"
        fi
    elif command -v jq &>/dev/null; then
        if jq . "$GENERATED" >/dev/null 2>&1; then
            _pass "generated config is valid JSON (jq)"
        else
            _fail "generated config failed JSON validation (jq)"
        fi
    else
        _pass "JSON validation skipped (python3 and jq unavailable)"
    fi
fi

# =============================================================================
echo "=== AC8: VERSION reads 4.27.5 ==="

actual_version=$(tr -d '[:space:]' < "${TEKHTON_HOME}/VERSION" 2>/dev/null || echo "MISSING")
if [[ "$actual_version" == "4.27.5" ]]; then
    _pass "VERSION reads 4.27.5"
else
    _fail "VERSION reads '${actual_version}', expected '4.27.5'"
fi

# =============================================================================
echo "=== AC9: CHANGELOG has m28.1 Fixed entry under [Unreleased] ==="

CHANGELOG="${TEKHTON_HOME}/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
    _fail "CHANGELOG.md not found at ${CHANGELOG}"
else
    # Extract content between ## [Unreleased] and the next versioned ## [...] heading
    unreleased_block=$(awk '/^## \[Unreleased\]/{found=1; next} found && /^## \[[0-9]/{exit} found{print}' "$CHANGELOG")

    if echo "$unreleased_block" | grep -q "m28\.1"; then
        _pass "CHANGELOG.md has m28.1 entry under [Unreleased]"
    else
        _fail "CHANGELOG.md does not have m28.1 entry under [Unreleased]"
    fi

    if echo "$unreleased_block" | grep -q "start-mcp-server"; then
        _pass "CHANGELOG.md m28.1 entry mentions start-mcp-server"
    else
        _fail "CHANGELOG.md m28.1 entry does not mention start-mcp-server"
    fi
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
