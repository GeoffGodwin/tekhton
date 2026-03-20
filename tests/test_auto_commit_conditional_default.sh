#!/usr/bin/env bash
# =============================================================================
# test_auto_commit_conditional_default.sh — AUTO_COMMIT conditional default
#
# Tests that AUTO_COMMIT defaults to true in milestone mode and false otherwise.
# Explicit user overrides (pipeline.conf or --no-commit) take precedence.
#
# The conditional default works in two phases:
#   1. config_defaults.sh sets AUTO_COMMIT=false (non-milestone default)
#   2. Post-flag-parsing block in tekhton.sh overrides to true for milestone
#      mode, unless the user explicitly set AUTO_COMMIT.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
mkdir -p "$PROJECT_DIR/.claude"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

cd "$PROJECT_DIR"

# Source dependencies once at the top
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

# Simulate the post-flag-parsing conditional from tekhton.sh
apply_milestone_auto_commit() {
    # This mirrors the logic in tekhton.sh after flag parsing
    if [ "${MILESTONE_MODE:-false}" = true ] \
       && [[ " ${_CONF_KEYS_SET:-} " != *" AUTO_COMMIT "* ]] \
       && [ "${_AUTO_COMMIT_EXPLICIT:-false}" != true ]; then
        AUTO_COMMIT=true
    fi
}

reload_defaults() {
    unset AUTO_COMMIT 2>/dev/null || true
    # config_defaults.sh references CLAUDE_STANDARD_MODEL; stub it for test isolation
    : "${CLAUDE_STANDARD_MODEL:=sonnet}"
    source "${TEKHTON_HOME}/lib/config_defaults.sh"
}

# =============================================================================
# Test 1: Non-milestone mode defaults to false
# =============================================================================

MILESTONE_MODE=false
_CONF_KEYS_SET=""
_AUTO_COMMIT_EXPLICIT=false
reload_defaults
apply_milestone_auto_commit
assert_eq "1.1 non-milestone mode defaults to false" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 2: Milestone mode defaults to true
# =============================================================================

MILESTONE_MODE=true
_CONF_KEYS_SET=""
_AUTO_COMMIT_EXPLICIT=false
reload_defaults
apply_milestone_auto_commit
assert_eq "2.1 milestone mode defaults to true" "true" "$AUTO_COMMIT"

# =============================================================================
# Test 3: Explicit AUTO_COMMIT=false in pipeline.conf overrides milestone default
# =============================================================================

MILESTONE_MODE=true
_CONF_KEYS_SET=" AUTO_COMMIT "
_AUTO_COMMIT_EXPLICIT=false
AUTO_COMMIT=false
source "${TEKHTON_HOME}/lib/config_defaults.sh"
apply_milestone_auto_commit
assert_eq "3.1 explicit false in pipeline.conf overrides milestone" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 4: Explicit AUTO_COMMIT=true in pipeline.conf works in non-milestone mode
# =============================================================================

MILESTONE_MODE=false
_CONF_KEYS_SET=" AUTO_COMMIT "
_AUTO_COMMIT_EXPLICIT=false
AUTO_COMMIT=true
source "${TEKHTON_HOME}/lib/config_defaults.sh"
apply_milestone_auto_commit
assert_eq "4.1 explicit true in pipeline.conf works in non-milestone" "true" "$AUTO_COMMIT"

# =============================================================================
# Test 5: --no-commit flag overrides milestone default
# =============================================================================

MILESTONE_MODE=true
_CONF_KEYS_SET=""
_AUTO_COMMIT_EXPLICIT=true
reload_defaults
# Simulate --no-commit: sets AUTO_COMMIT=false
AUTO_COMMIT=false
apply_milestone_auto_commit
assert_eq "5.1 --no-commit overrides milestone default" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 6: Unset MILESTONE_MODE → AUTO_COMMIT defaults to false
# =============================================================================

unset MILESTONE_MODE 2>/dev/null || true
_CONF_KEYS_SET=""
_AUTO_COMMIT_EXPLICIT=false
reload_defaults
apply_milestone_auto_commit
assert_eq "6.1 unset MILESTONE_MODE defaults to false" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 7: config_defaults.sh alone (no milestone override) sets false
# =============================================================================

MILESTONE_MODE=false
reload_defaults
assert_eq "7.1 config_defaults.sh alone sets false" "false" "$AUTO_COMMIT"

# =============================================================================
# Test 8: config_defaults.sh :=false does not override explicit true
# =============================================================================

AUTO_COMMIT=true
MILESTONE_MODE=false
source "${TEKHTON_HOME}/lib/config_defaults.sh"
assert_eq "8.1 config_defaults.sh does not override explicit true" "true" "$AUTO_COMMIT"

# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo ""
    echo "FAILED"
    exit 1
fi

echo ""
echo "All tests passed."
