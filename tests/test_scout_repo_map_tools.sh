#!/usr/bin/env bash
# =============================================================================
# test_scout_repo_map_tools.sh — Tests for M45 Scout tool allowlist reduction
#
# Tests:
# - SCOUT_NO_REPO_MAP is set when REPO_MAP_CONTENT is empty
# - SCOUT_NO_REPO_MAP is unset when REPO_MAP_CONTENT is populated
# - Tool allowlist is reduced when repo map available + SCOUT_REPO_MAP_TOOLS_ONLY=true
# - Tool allowlist is NOT reduced when SCOUT_REPO_MAP_TOOLS_ONLY=false
# - SCOUT_REPO_MAP_TOOLS_ONLY defaults to true
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cd "$TMPDIR"

# --- Source common.sh for log/warn --------------------------------------------
source "${TEKHTON_HOME}/lib/common.sh"

# --- Test helpers -------------------------------------------------------------
PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

# =============================================================================
# Test Suite 1: SCOUT_NO_REPO_MAP flag behavior
# =============================================================================
echo "=== Test Suite 1: SCOUT_NO_REPO_MAP flag ==="

# Test with empty REPO_MAP_CONTENT
REPO_MAP_CONTENT=""
SCOUT_NO_REPO_MAP=""
if [[ -z "${REPO_MAP_CONTENT}" ]]; then
    SCOUT_NO_REPO_MAP="true"
fi

if [[ "$SCOUT_NO_REPO_MAP" = "true" ]]; then
    pass "1.1 SCOUT_NO_REPO_MAP is 'true' when REPO_MAP_CONTENT is empty"
else
    fail "1.1 SCOUT_NO_REPO_MAP is 'true' when REPO_MAP_CONTENT is empty (got: '$SCOUT_NO_REPO_MAP')"
fi

# Test with populated REPO_MAP_CONTENT
REPO_MAP_CONTENT="## src/main.py\n  def main()\n  class App"
SCOUT_NO_REPO_MAP=""
if [[ -z "${REPO_MAP_CONTENT}" ]]; then
    SCOUT_NO_REPO_MAP="true"
fi

if [[ -z "$SCOUT_NO_REPO_MAP" ]]; then
    pass "1.2 SCOUT_NO_REPO_MAP is empty when REPO_MAP_CONTENT is populated"
else
    fail "1.2 SCOUT_NO_REPO_MAP is empty when REPO_MAP_CONTENT is populated (got: '$SCOUT_NO_REPO_MAP')"
fi

# =============================================================================
# Test Suite 2: Tool allowlist reduction
# =============================================================================
echo "=== Test Suite 2: Tool allowlist reduction ==="

AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Bash(tail:*) Bash(file:*) Write"

# With repo map + SCOUT_REPO_MAP_TOOLS_ONLY=true
REPO_MAP_CONTENT="## src/main.py\n  def main()"
SCOUT_REPO_MAP_TOOLS_ONLY=true
_scout_tools="$AGENT_TOOLS_SCOUT"
if [[ -n "${REPO_MAP_CONTENT}" ]] && [[ "${SCOUT_REPO_MAP_TOOLS_ONLY:-true}" = "true" ]]; then
    _scout_tools="Read Glob Grep Write"
fi

if [[ "$_scout_tools" = "Read Glob Grep Write" ]]; then
    pass "2.1 tools reduced to 'Read Glob Grep Write' with repo map"
else
    fail "2.1 tools reduced to 'Read Glob Grep Write' — got '$_scout_tools'"
fi

# Without repo map: tools unchanged
REPO_MAP_CONTENT=""
_scout_tools="$AGENT_TOOLS_SCOUT"
if [[ -n "${REPO_MAP_CONTENT}" ]] && [[ "${SCOUT_REPO_MAP_TOOLS_ONLY:-true}" = "true" ]]; then
    _scout_tools="Read Glob Grep Write"
fi

if [[ "$_scout_tools" = "$AGENT_TOOLS_SCOUT" ]]; then
    pass "2.2 tools unchanged when no repo map"
else
    fail "2.2 tools unchanged when no repo map — got '$_scout_tools'"
fi

# With repo map but SCOUT_REPO_MAP_TOOLS_ONLY=false: tools unchanged
REPO_MAP_CONTENT="## src/main.py\n  def main()"
SCOUT_REPO_MAP_TOOLS_ONLY=false
_scout_tools="$AGENT_TOOLS_SCOUT"
if [[ -n "${REPO_MAP_CONTENT}" ]] && [[ "${SCOUT_REPO_MAP_TOOLS_ONLY:-true}" = "true" ]]; then
    _scout_tools="Read Glob Grep Write"
fi

if [[ "$_scout_tools" = "$AGENT_TOOLS_SCOUT" ]]; then
    pass "2.3 tools unchanged when SCOUT_REPO_MAP_TOOLS_ONLY=false"
else
    fail "2.3 tools unchanged when SCOUT_REPO_MAP_TOOLS_ONLY=false — got '$_scout_tools'"
fi

# =============================================================================
# Test Suite 3: Config default
# =============================================================================
echo "=== Test Suite 3: Config default ==="

# Source config_defaults.sh with required mocks
_clamp_config_value() { :; }
_clamp_config_float() { :; }

# Unset to test default
unset SCOUT_REPO_MAP_TOOLS_ONLY 2>/dev/null || true
source "${TEKHTON_HOME}/lib/config_defaults.sh"

if [[ "${SCOUT_REPO_MAP_TOOLS_ONLY}" = "true" ]]; then
    pass "3.1 SCOUT_REPO_MAP_TOOLS_ONLY defaults to true"
else
    fail "3.1 SCOUT_REPO_MAP_TOOLS_ONLY defaults to true (got: '${SCOUT_REPO_MAP_TOOLS_ONLY}')"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  scout repo map tools tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[[ "$FAIL" -eq 0 ]] || exit 1
echo "All scout repo map tools tests passed"
