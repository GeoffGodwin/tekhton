#!/usr/bin/env bash
# =============================================================================
# test_config_defaults_claude_standard_model.sh
#
# Verifies the fix for CLAUDE_STANDARD_MODEL unbound variable bug.
# Tests that config_defaults.sh properly initializes the base model variable
# before any derived variables reference it, preventing `set -euo pipefail`
# crashes in express mode when no pipeline.conf sets explicit model values.
# =============================================================================

set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Source common.sh for helper functions
source "${TEKHTON_HOME}/lib/common.sh" 2>/dev/null || true

# Helper functions
pass() {
  echo "PASS: $*"
}

fail() {
  echo "FAIL: $*"
  exit 1
}

# Stub helper functions (config_defaults.sh calls these)
_clamp_config_value() {
  # No-op stub for testing — we only care that config_defaults.sh doesn't crash
  :
}

_clamp_config_float() {
  # No-op stub for testing — we only care that config_defaults.sh doesn't crash
  :
}

# Test 1: Verify CLAUDE_STANDARD_MODEL is defined after sourcing config_defaults.sh
test_claude_standard_model_defined() {
  local test_name="CLAUDE_STANDARD_MODEL is defined with default value"

  # Create a clean subshell environment (no vars from current shell)
  (
    set -euo pipefail
    unset -v CLAUDE_STANDARD_MODEL 2>/dev/null || true

    # Source the file under test
    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    # Verify the variable is set
    if [[ -z "${CLAUDE_STANDARD_MODEL:-}" ]]; then
      fail "$test_name: CLAUDE_STANDARD_MODEL is empty or unset after sourcing config_defaults.sh"
    fi
  ) || fail "$test_name: subshell exited with error"

  pass "$test_name"
}

# Test 2: Verify the default value is correct
test_claude_standard_model_default_value() {
  local test_name="CLAUDE_STANDARD_MODEL has correct default value"

  (
    set -euo pipefail
    unset -v CLAUDE_STANDARD_MODEL 2>/dev/null || true

    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    local expected="claude-sonnet-4-6"
    if [[ "${CLAUDE_STANDARD_MODEL}" != "${expected}" ]]; then
      fail "$test_name: expected '${expected}', got '${CLAUDE_STANDARD_MODEL}'"
    fi
  ) || fail "$test_name: subshell exited with error"

  pass "$test_name"
}

# Test 3: Verify derived model variables can safely reference CLAUDE_STANDARD_MODEL
test_derived_models_safe() {
  local test_name="Derived model variables can safely reference CLAUDE_STANDARD_MODEL"

  (
    set -euo pipefail
    unset -v CLAUDE_STANDARD_MODEL CLAUDE_CODER_MODEL CLAUDE_JR_CODER_MODEL \
             CLAUDE_REVIEWER_MODEL CLAUDE_TESTER_MODEL CLAUDE_ARCHITECT_MODEL \
             CLAUDE_SCOUT_MODEL 2>/dev/null || true

    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    # Attempt to dereference all derived variables
    # If any are unbound, the subshell will crash with "unbound variable"
    local coder="${CLAUDE_CODER_MODEL}"
    local jr_coder="${CLAUDE_JR_CODER_MODEL}"
    local reviewer="${CLAUDE_REVIEWER_MODEL}"
    local tester="${CLAUDE_TESTER_MODEL}"
    local architect="${CLAUDE_ARCHITECT_MODEL}"
    local scout="${CLAUDE_SCOUT_MODEL}"

    # All should equal the base model (or be derived from it)
    if [[ -z "${coder}" || -z "${jr_coder}" || -z "${reviewer}" || \
          -z "${tester}" || -z "${architect}" || -z "${scout}" ]]; then
      fail "$test_name: one or more derived model variables are empty"
    fi
  ) || fail "$test_name: subshell exited with 'unbound variable' error"

  pass "$test_name"
}

# Test 4: Verify no stale fallback patterns remain in derived model lines
test_no_redundant_fallbacks() {
  local test_name="No redundant fallback suffixes in derived model assignments"

  # Lines that previously had :-claude-sonnet-4-6 fallbacks but should now be clean:
  # Line 24: CLAUDE_CODER_MODEL
  # Line 25: CLAUDE_JR_CODER_MODEL
  # Line 26: CLAUDE_REVIEWER_MODEL
  # Line 27: CLAUDE_TESTER_MODEL
  # Line 47: CLAUDE_SCOUT_MODEL (now references CLAUDE_JR_CODER_MODEL)
  # Line 82: CLAUDE_ARCHITECT_MODEL

  local config_defaults="${TEKHTON_HOME}/lib/config_defaults.sh"

  # Search for the pattern where CLAUDE_*_MODEL has both :- fallback syntax
  # This would indicate the coder didn't clean up properly
  if grep -E 'CLAUDE_.*MODEL.*:-.*claude-' "${config_defaults}" | \
     grep -v '# ' | grep -v 'CLAUDE_STANDARD_MODEL' > /dev/null; then
    fail "$test_name: found redundant :-fallback patterns in derived model assignments"
  fi

  pass "$test_name"
}

# Test 5: Verify unset variables in clean environment don't crash with set -euo pipefail
test_no_unbound_crash_in_strict_mode() {
  local test_name="No unbound variable crashes when sourcing in strict bash mode"

  # This is the key bug: express mode runs with set -euo pipefail but no pipeline.conf
  # The bug was that CLAUDE_STANDARD_MODEL was never initialized, causing bare references to crash
  (
    set -euo pipefail

    # Explicitly unset everything to simulate express mode (no pipeline.conf)
    unset -v CLAUDE_STANDARD_MODEL CLAUDE_CODER_MODEL CLAUDE_JR_CODER_MODEL \
             CLAUDE_REVIEWER_MODEL CLAUDE_TESTER_MODEL CLAUDE_ARCHITECT_MODEL \
             CLAUDE_SCOUT_MODEL 2>/dev/null || true

    # This should NOT crash with "CLAUDE_STANDARD_MODEL: unbound variable"
    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    # Verify the base model was set
    [[ -n "${CLAUDE_STANDARD_MODEL}" ]] || \
      fail "$test_name: CLAUDE_STANDARD_MODEL not set after sourcing"
  ) || fail "$test_name: sourcing config_defaults.sh crashed with unbound variable error"

  pass "$test_name"
}

# Test 6: Verify preset values are NOT overwritten by defaults
test_preset_values_respected() {
  local test_name="Preset model values are not overwritten by defaults"

  (
    set -euo pipefail

    # Pre-set values (simulating pipeline.conf values)
    export CLAUDE_STANDARD_MODEL="claude-opus-4-6"
    export CLAUDE_CODER_MODEL="claude-haiku-4-5"

    source "${TEKHTON_HOME}/lib/config_defaults.sh"

    # The values should NOT be overwritten because : "${VAR:=value}" only sets if unset
    if [[ "${CLAUDE_STANDARD_MODEL}" != "claude-opus-4-6" ]]; then
      fail "$test_name: CLAUDE_STANDARD_MODEL was overwritten (expected to be preserved)"
    fi

    if [[ "${CLAUDE_CODER_MODEL}" != "claude-haiku-4-5" ]]; then
      fail "$test_name: CLAUDE_CODER_MODEL was overwritten (expected to be preserved)"
    fi
  ) || fail "$test_name: test failed"

  pass "$test_name"
}

# --- Run all tests ---
echo "=== Testing config_defaults.sh CLAUDE_STANDARD_MODEL fix ==="
test_claude_standard_model_defined
test_claude_standard_model_default_value
test_derived_models_safe
test_no_redundant_fallbacks
test_no_unbound_crash_in_strict_mode
test_preset_values_respected

echo ""
echo "All tests passed!"
exit 0
