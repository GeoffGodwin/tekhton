#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m131_coverage_gaps.sh — Coverage-gap tests for M131
#
# Addresses two gaps identified in the M131 reviewer report:
#
#   GAP-1: _ui_deterministic_env_list M131 escalation path
#     When PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1, the function must emit
#     CI=1 even when the caller does NOT pass hardened=1. The existing
#     test_ui_gate_force_noninteractive.sh P0-T6 only validates the explicit
#     hardened=1 argument path.
#
#   GAP-2: CY-2 pass case
#     reporter: 'mochawesome' in cypress.config combined with --exit present in
#     UI_TEST_CMD must produce zero warns (inner guard's "no issue" exit path).
#     No prior assertion covered this branch.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# gates_ui_helpers.sh is self-contained for the GAP-1 test.
# shellcheck source=lib/gates_ui_helpers.sh
source "${TEKHTON_HOME}/lib/gates_ui_helpers.sh"

# preflight.sh defines _pf_record and counters needed for GAP-2.
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks_ui.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        pass
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        fail "$desc"
    fi
}

assert_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        pass
    else
        echo "  FAIL: $desc — '$needle' not found in output"
        fail "$desc"
    fi
}

assert_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if ! printf '%s' "$haystack" | grep -qF "$needle"; then
        echo "  PASS: $desc"
        pass
    else
        echo "  FAIL: $desc — '$needle' found in output but should be absent"
        fail "$desc"
    fi
}

# Reset preflight counters and contract vars between tests.
_reset_pf_state() {
    _PF_PASS=0
    _PF_WARN=0
    _PF_FAIL=0
    _PF_REMEDIATED=0
    _PF_REPORT_LINES=()
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_RULE \
          PREFLIGHT_UI_INTERACTIVE_CONFIG_FILE \
          PREFLIGHT_UI_REPORTER_PATCHED 2>/dev/null || true
}

# =============================================================================
# GAP-1: _ui_deterministic_env_list M131 escalation path
#
# Behavioural contract (gates_ui_helpers.sh lines 65-67):
#   if [[ "${PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED:-}" == "1" ]]; then
#       hardened=1
#   fi
#
# Consequence: when M131 preflight detection fires, the FIRST gate run gets
# CI=1 (not just the hardened-retry run). This prevents a wasted timeout burn.
# =============================================================================
echo "=== GAP-1: PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1 escalation ==="

_clear_gate_vars() {
    TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=""
    UI_FRAMEWORK=""
    UI_TEST_CMD=""
    PROJECT_DIR="$TMPDIR_BASE"
    unset PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED 2>/dev/null || true
}

# GAP-1.1: Detection flag set, framework=playwright via UI_FRAMEWORK config,
# no hardened arg passed → must emit CI=1 (M131 escalation).
echo "  GAP-1.1: flag=1 + UI_FRAMEWORK=playwright → CI=1 without hardened arg"
_clear_gate_vars
PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
UI_FRAMEWORK=playwright
env_list=$(_ui_deterministic_env_list)
assert_contains "GAP-1.1 emits PLAYWRIGHT_HTML_OPEN=never" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
assert_contains "GAP-1.1 emits CI=1 via M131 escalation" "CI=1" "$env_list"

# GAP-1.2: Detection flag set, framework=playwright via UI_FRAMEWORK config,
# hardened=0 passed explicitly → flag still overrides to hardened=1 → CI=1.
echo "  GAP-1.2: flag=1 + hardened=0 arg → escalation overrides arg"
_clear_gate_vars
PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
UI_FRAMEWORK=playwright
env_list=$(_ui_deterministic_env_list 0)
assert_contains "GAP-1.2 emits PLAYWRIGHT_HTML_OPEN=never" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
assert_contains "GAP-1.2 emits CI=1 despite hardened=0 arg" "CI=1" "$env_list"

# GAP-1.3: Detection flag NOT set, framework=playwright, no hardened arg →
# PLAYWRIGHT_HTML_OPEN=never emitted but CI=1 must NOT be emitted.
echo "  GAP-1.3: flag unset + UI_FRAMEWORK=playwright → no CI=1 on first run"
_clear_gate_vars
UI_FRAMEWORK=playwright
env_list=$(_ui_deterministic_env_list)
assert_contains "GAP-1.3 emits PLAYWRIGHT_HTML_OPEN=never" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
assert_not_contains "GAP-1.3 does not emit CI=1 without detection flag" "CI=1" "$env_list"

# GAP-1.4: Detection flag NOT set, framework=playwright, hardened=1 passed →
# CI=1 emitted (original hardened path still works — no regression).
echo "  GAP-1.4: flag unset + hardened=1 arg → CI=1 via original path"
_clear_gate_vars
UI_FRAMEWORK=playwright
env_list=$(_ui_deterministic_env_list 1)
assert_contains "GAP-1.4 emits CI=1 via explicit hardened=1" "CI=1" "$env_list"

# GAP-1.5: Detection flag set to "0" (not "1") → not escalated → no CI=1.
echo "  GAP-1.5: flag=0 + UI_FRAMEWORK=playwright → not escalated"
_clear_gate_vars
PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=0
UI_FRAMEWORK=playwright
env_list=$(_ui_deterministic_env_list)
assert_contains "GAP-1.5 emits PLAYWRIGHT_HTML_OPEN=never" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
assert_not_contains "GAP-1.5 does not emit CI=1 when flag=0" "CI=1" "$env_list"

# GAP-1.6: Detection flag set, framework=none (no playwright signals) →
# no env vars emitted at all (framework short-circuit respected).
echo "  GAP-1.6: flag=1 + no playwright framework → empty output"
_clear_gate_vars
PREFLIGHT_UI_INTERACTIVE_CONFIG_DETECTED=1
# Leave UI_FRAMEWORK unset, UI_TEST_CMD unset, no playwright.config.* in TMPDIR
env_list=$(_ui_deterministic_env_list)
assert_not_contains "GAP-1.6 no PLAYWRIGHT_HTML_OPEN=never for non-playwright" "PLAYWRIGHT_HTML_OPEN=never" "$env_list"
assert_not_contains "GAP-1.6 no CI=1 for non-playwright" "CI=1" "$env_list"

# =============================================================================
# GAP-2: CY-2 pass case — mochawesome reporter + --exit in UI_TEST_CMD
#
# The CY-2 rule fires only when BOTH conditions are true:
#   1. reporter: 'mochawesome' present in cypress.config
#   2. --exit is NOT in UI_TEST_CMD
# When --exit is present, the inner guard prevents the warn from firing and
# _pf_uitest_cypress emits a pass record instead. This path had no assertion.
# =============================================================================
echo "=== GAP-2: CY-2 pass case — mochawesome + --exit present ==="

# GAP-2.1: reporter: 'mochawesome' + --exit in UI_TEST_CMD → no warn, pass emitted.
echo "  GAP-2.1: mochawesome reporter + --exit → zero warns"
_reset_pf_state
PROJ=$(mktemp -d)
PROJECT_DIR="$PROJ"
export PROJECT_DIR
export UI_TEST_CMD="cypress run --exit"
cat > "$PROJ/cypress.config.ts" <<'EOF'
import { defineConfig } from 'cypress';
export default defineConfig({
  reporter: 'mochawesome',
  reporterOptions: { reportDir: 'cypress/results' },
});
EOF
_preflight_check_ui_test_config
assert_eq "GAP-2.1 _PF_WARN=0 (no CY-2 warn when --exit present)" "0" "$_PF_WARN"
assert_eq "GAP-2.1 _PF_PASS=1 (pass record emitted)" "1" "$_PF_PASS"
assert_eq "GAP-2.1 _PF_FAIL=0" "0" "$_PF_FAIL"
rm -rf "$PROJ"

# GAP-2.2: reporter: 'mochawesome' WITHOUT --exit → warn emitted (confirm
# the positive case still fires — ensures the guard logic is directionally correct).
echo "  GAP-2.2: mochawesome reporter without --exit → warn emitted"
_reset_pf_state
PROJ=$(mktemp -d)
PROJECT_DIR="$PROJ"
export PROJECT_DIR
export UI_TEST_CMD="cypress run"
cat > "$PROJ/cypress.config.ts" <<'EOF'
import { defineConfig } from 'cypress';
export default defineConfig({
  reporter: 'mochawesome',
});
EOF
_preflight_check_ui_test_config
assert_eq "GAP-2.2 _PF_WARN>=1 (CY-2 warn fires without --exit)" "1" "$([[ $_PF_WARN -ge 1 ]] && echo 1 || echo 0)"
assert_eq "GAP-2.2 _PF_PASS=0 (no pass when issue found)" "0" "$_PF_PASS"
rm -rf "$PROJ"

# GAP-2.3: reporter: 'mochawesome' + --exit embedded mid-command string.
echo "  GAP-2.3: mochawesome + --exit mid-string → no warn"
_reset_pf_state
PROJ=$(mktemp -d)
PROJECT_DIR="$PROJ"
export PROJECT_DIR
export UI_TEST_CMD="cypress run --browser chrome --exit --headless"
cat > "$PROJ/cypress.config.js" <<'EOF'
module.exports = { reporter: 'mochawesome' };
EOF
_preflight_check_ui_test_config
assert_eq "GAP-2.3 _PF_WARN=0 (--exit mid-string suppresses CY-2)" "0" "$_PF_WARN"
assert_eq "GAP-2.3 _PF_PASS=1 (pass emitted)" "1" "$_PF_PASS"
rm -rf "$PROJ"

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  M131 coverage gaps: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]] || exit 1
