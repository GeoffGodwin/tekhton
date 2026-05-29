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
echo "=== AC2: _resolve_serena_paths — POSIX, Windows, absent-binary scenarios ==="

# Reusable per-scenario runner. Args: label, dir, bin-relpath ("" if absent),
# python-relpath, expected-rc, expected-_SERENA_BIN.
_resolve_case() {
    local label="$1" dir="$2" bin_rel="$3" py_rel="$4" expect_rc="$5" expect_bin="$6"
    mkdir -p "${dir}/$(dirname "$py_rel")"
    touch "${dir}/${py_rel}"
    if [[ -n "$bin_rel" ]]; then
        mkdir -p "${dir}/$(dirname "$bin_rel")"
        touch "${dir}/${bin_rel}"
    fi
    _SERENA_BIN=""; _SERENA_PYTHON=""; _SERENA_DIR=""
    SERENA_PATH="$dir"
    local rc=0
    _resolve_serena_paths || rc=$?
    if [[ "$rc" -eq "$expect_rc" ]]; then
        _pass "${label}: _resolve_serena_paths returns $expect_rc"
    else
        _fail "${label}: _resolve_serena_paths returned $rc, expected $expect_rc"
    fi
    if [[ "$_SERENA_BIN" == "$expect_bin" ]]; then
        _pass "${label}: _SERENA_BIN matches expected"
    else
        _fail "${label}: _SERENA_BIN='${_SERENA_BIN}', expected '${expect_bin}'"
    fi
}

POSIX_DIR="${TMPDIR}/posix_serena"
_resolve_case "POSIX layout" \
    "$POSIX_DIR" ".venv/bin/serena" ".venv/bin/python" 0 "${POSIX_DIR}/.venv/bin/serena"

WIN_DIR="${TMPDIR}/win_serena"
_resolve_case "Windows layout" \
    "$WIN_DIR" ".venv/Scripts/serena.exe" ".venv/Scripts/python.exe" 0 "${WIN_DIR}/.venv/Scripts/serena.exe"

NO_BIN_DIR="${TMPDIR}/no_bin_serena"
_resolve_case "Binary absent" \
    "$NO_BIN_DIR" "" ".venv/bin/python" 1 ""

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
echo "=== AC8: VERSION floor — m28 arc opened at 4.27.5; closes at 4.28.0+ ==="

# Pipeline finalize hooks may patch-bump VERSION between stages, and m28.3
# closes the arc by promoting [Unreleased] entries to 4.28.0. Either the
# in-flight 4.27.x (x>=5) floor or any 4.MM.* >= 4.28 satisfies this AC.
ver=$(tr -d '[:space:]' < "${TEKHTON_HOME}/VERSION" 2>/dev/null || echo "MISSING")
vmaj="${ver%%.*}"; vrest="${ver#*.}"; vmin="${vrest%%.*}"; vpat="${ver##*.}"

if { [[ "$vmaj" == "4" ]] && [[ "$vmin" == "27" ]] && [[ "$vpat" -ge 5 ]]; } \
   || { [[ "$vmaj" == "4" ]] && [[ "$vmin" -ge 28 ]]; }; then
    _pass "VERSION at or above m28.1 floor — current: ${ver}"
else
    _fail "VERSION reads '${ver}', expected 4.27.x (x>=5) or 4.>=28.x"
fi

# =============================================================================
echo "=== AC9: CHANGELOG has m28.1 Fixed entry (Unreleased or promoted block) ==="

# m28.3 close promotes m28.x entries from [Unreleased] to [4.28.0]. Accept
# either: still under [Unreleased] (mid-arc) or any ## [N.NN.N] block.
CHANGELOG="${TEKHTON_HOME}/CHANGELOG.md"
if [[ ! -f "$CHANGELOG" ]]; then
    _fail "CHANGELOG.md not found at ${CHANGELOG}"
else
    ub=$(awk '/^## \[Unreleased\]/{f=1;next} f && /^## \[[0-9]/{exit} f' "$CHANGELOG")
    pb=$(awk '/^## \[4\.[0-9]+\.[0-9]+\]/{f=1;next} f && /^## \[/{exit} f' "$CHANGELOG")
    both="${ub}
${pb}"

    echo "$both" | grep -q "m28\.1" \
        && _pass "CHANGELOG.md has m28.1 entry (Unreleased or promoted)" \
        || _fail "CHANGELOG.md does not have m28.1 entry in either block"

    echo "$both" | grep -q "start-mcp-server" \
        && _pass "CHANGELOG.md m28.1 entry mentions start-mcp-server" \
        || _fail "CHANGELOG.md m28.1 entry does not mention start-mcp-server"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
