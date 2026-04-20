#!/usr/bin/env bash
# Test: M109 init feature wizard — Python detection, prompt flow, config emission
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs for sourced deps.
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
_can_prompt()    { return 0; }
prompt_confirm() { return 0; }

# shellcheck source=../lib/init_wizard.sh
source "${TEKHTON_HOME}/lib/init_wizard.sh"
# shellcheck source=../lib/init_config_sections.sh
source "${TEKHTON_HOME}/lib/init_config_sections.sh"

_reset() { _wizard_reset_state; unset TEKHTON_NON_INTERACTIVE; }

# Helpers used across tests.
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        pass "${label} (=${expected})"
    else
        fail "${label}: expected '${expected}', got '${actual}'"
    fi
}

assert_unset() {
    local label="$1" actual="${2-}"
    if [[ -z "$actual" ]]; then
        pass "${label} (unset)"
    else
        fail "${label}: expected unset, got '${actual}'"
    fi
}

# --- Test 1: python not found -------------------------------------------------
echo "=== Test 1: python not found ==="
_reset
_wizard_find_python3() { return 1; }

_TMP_STDERR=$(mktemp)
run_feature_wizard "" 2>"$_TMP_STDERR"
stderr_out=$(cat "$_TMP_STDERR")
rm -f "$_TMP_STDERR"

assert_eq "python_not_found: PYTHON_FOUND" "false" "${_WIZARD_PYTHON_FOUND:-}"
if echo "$stderr_out" | grep -q "Python 3.8+ was not found"; then
    pass "python_not_found: advisory message printed"
else
    fail "python_not_found: advisory message missing"
fi
assert_unset "python_not_found: TUI_ENABLED" "${_WIZARD_TUI_ENABLED:-}"
assert_unset "python_not_found: REPO_MAP_ENABLED" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_unset "python_not_found: SERENA_ENABLED" "${_WIZARD_SERENA_ENABLED:-}"

# --- Test 2: all features yes -------------------------------------------------
echo "=== Test 2: all features yes ==="
_reset
_wizard_find_python3() { echo "python3"; return 0; }
prompt_confirm() { return 0; }

run_feature_wizard "" 2>/dev/null

assert_eq "all_yes: TUI" "true" "${_WIZARD_TUI_ENABLED:-}"
assert_eq "all_yes: REPO_MAP" "true" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_eq "all_yes: SERENA" "true" "${_WIZARD_SERENA_ENABLED:-}"
assert_eq "all_yes: NEEDS_VENV" "true" "${_WIZARD_NEEDS_VENV:-}"

# --- Test 3: all features no --------------------------------------------------
echo "=== Test 3: all features no ==="
_reset
_wizard_find_python3() { echo "python3"; return 0; }
prompt_confirm() { return 1; }

run_feature_wizard "" 2>/dev/null

assert_unset "all_no: TUI" "${_WIZARD_TUI_ENABLED:-}"
assert_unset "all_no: REPO_MAP" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_unset "all_no: SERENA" "${_WIZARD_SERENA_ENABLED:-}"
assert_unset "all_no: NEEDS_VENV" "${_WIZARD_NEEDS_VENV:-}"

# --- Test 4: mixed yes/no -----------------------------------------------------
echo "=== Test 4: mixed yes/no ==="
_reset
_wizard_find_python3() { echo "python3"; return 0; }
_PROMPT_CALL_COUNT=0
prompt_confirm() {
    _PROMPT_CALL_COUNT=$((_PROMPT_CALL_COUNT + 1))
    case "$_PROMPT_CALL_COUNT" in
        1) return 0 ;;  # TUI: yes
        2) return 1 ;;  # repo maps: no
        3) return 0 ;;  # serena: yes
        *) return 1 ;;
    esac
}

run_feature_wizard "" 2>/dev/null

assert_eq "mixed: TUI" "true" "${_WIZARD_TUI_ENABLED:-}"
assert_unset "mixed: REPO_MAP" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_eq "mixed: SERENA" "true" "${_WIZARD_SERENA_ENABLED:-}"
assert_eq "mixed: NEEDS_VENV" "true" "${_WIZARD_NEEDS_VENV:-}"

# --- Test 5: reinit skipped (no-op) -------------------------------------------
echo "=== Test 5: reinit skipped ==="
_reset
_wizard_find_python3() { echo "python3"; return 0; }
prompt_confirm() { return 0; }

run_feature_wizard "reinit" 2>/dev/null

assert_unset "reinit: TUI" "${_WIZARD_TUI_ENABLED:-}"
assert_unset "reinit: PYTHON_FOUND" "${_WIZARD_PYTHON_FOUND:-}"
assert_unset "reinit: NEEDS_VENV" "${_WIZARD_NEEDS_VENV:-}"

# --- Test 6: non-interactive with python --------------------------------------
echo "=== Test 6: non-interactive with python ==="
_reset
_wizard_find_python3() { echo "python3"; return 0; }
export TEKHTON_NON_INTERACTIVE=true

run_feature_wizard "" 2>/dev/null

assert_eq "non_interactive: TUI=auto" "auto" "${_WIZARD_TUI_ENABLED:-}"
assert_eq "non_interactive: REPO_MAP" "true" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_eq "non_interactive: SERENA" "true" "${_WIZARD_SERENA_ENABLED:-}"
assert_eq "non_interactive: PYTHON_FOUND" "true" "${_WIZARD_PYTHON_FOUND:-}"
assert_unset "non_interactive: NEEDS_VENV (never triggers venv)" "${_WIZARD_NEEDS_VENV:-}"

unset TEKHTON_NON_INTERACTIVE

# --- Test 7: non-interactive without python -----------------------------------
echo "=== Test 7: non-interactive without python ==="
_reset
_wizard_find_python3() { return 1; }
export TEKHTON_NON_INTERACTIVE=true

run_feature_wizard "" 2>/dev/null

assert_eq "non_interactive_no_python: PYTHON_FOUND" "false" "${_WIZARD_PYTHON_FOUND:-}"
assert_unset "non_interactive_no_python: TUI" "${_WIZARD_TUI_ENABLED:-}"
assert_unset "non_interactive_no_python: REPO_MAP" "${_WIZARD_REPO_MAP_ENABLED:-}"
assert_unset "non_interactive_no_python: SERENA" "${_WIZARD_SERENA_ENABLED:-}"
assert_unset "non_interactive_no_python: NEEDS_VENV" "${_WIZARD_NEEDS_VENV:-}"

unset TEKHTON_NON_INTERACTIVE

# --- Test 8: _emit_section_features WITH wizard vars --------------------------
echo "=== Test 8: _emit_section_features with wizard vars ==="
_reset
export _WIZARD_TUI_ENABLED=true
export _WIZARD_REPO_MAP_ENABLED=true
# SERENA left unset

output=$(_emit_section_features)

grep_pass() {
    local label="$1" pattern="$2"
    if echo "$output" | grep -qE "$pattern"; then
        pass "$label"
    else
        fail "${label}: pattern '${pattern}' not found"
    fi
}

grep_pass "with_wizard: TUI_ENABLED=true uncommented" '^TUI_ENABLED=true'
grep_pass "with_wizard: REPO_MAP_ENABLED=true uncommented" '^REPO_MAP_ENABLED=true'
grep_pass "with_wizard: SERENA_ENABLED commented" '^# SERENA_ENABLED='
grep_pass "with_wizard: DASHBOARD_ENABLED uncommented" '^DASHBOARD_ENABLED=true'

# TUI=auto path
_reset
export _WIZARD_TUI_ENABLED=auto
output=$(_emit_section_features)
grep_pass "with_wizard: TUI_ENABLED=auto when set to auto" '^TUI_ENABLED=auto'

# --- Test 9: _emit_section_features WITHOUT wizard vars -----------------------
echo "=== Test 9: _emit_section_features without wizard vars ==="
_reset
output=$(_emit_section_features)

grep_pass "without_wizard: TUI_ENABLED commented" '^# TUI_ENABLED='
grep_pass "without_wizard: REPO_MAP_ENABLED commented" '^# REPO_MAP_ENABLED='
grep_pass "without_wizard: SERENA_ENABLED commented" '^# SERENA_ENABLED='
grep_pass "without_wizard: DASHBOARD_ENABLED uncommented" '^DASHBOARD_ENABLED=true'

# --- Summary ------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
