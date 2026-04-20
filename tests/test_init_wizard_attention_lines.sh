#!/usr/bin/env bash
# Test: _wizard_attention_lines — direct unit tests for all three _WIZARD_PYTHON_FOUND
# cases: true (features enabled), false (no Python), unset (wizard never ran).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0
pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs for init_wizard.sh deps (only needed to satisfy sourcing; not called
# by _wizard_attention_lines itself).
log()          { :; }
warn()         { :; }
error()        { :; }
success()      { :; }
header()       { :; }
_can_prompt()  { return 0; }
prompt_confirm() { return 0; }

# shellcheck source=../lib/init_wizard.sh
source "${TEKHTON_HOME}/lib/init_wizard.sh"

_reset() { _wizard_reset_state; }

assert_output_contains() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -qF -- "$pattern"; then
        pass "${label}: contains '${pattern}'"
    else
        fail "${label}: expected '${pattern}' in output '${output}'"
    fi
}

assert_output_empty() {
    local label="$1" output="$2"
    if [[ -z "$output" ]]; then
        pass "${label}: output empty as expected"
    else
        fail "${label}: expected empty output, got '${output}'"
    fi
}

assert_output_not_contains() {
    local label="$1" pattern="$2" output="$3"
    if echo "$output" | grep -qF -- "$pattern"; then
        fail "${label}: output should NOT contain '${pattern}'"
    else
        pass "${label}: does not contain '${pattern}'"
    fi
}

# --- Test 1: PYTHON_FOUND=false — install advisory ----------------------------
echo "=== Test 1: PYTHON_FOUND=false — install advisory ==="
_reset
export _WIZARD_PYTHON_FOUND="false"

out=$(_wizard_attention_lines "•")
assert_output_contains "no_python" "Install Python 3.8+ to enable enhanced features" "$out"
assert_output_contains "no_python: bullet passthrough" "•" "$out"

# --- Test 2: PYTHON_FOUND unset — wizard never ran, no output -----------------
echo "=== Test 2: PYTHON_FOUND unset — no output ==="
_reset

out=$(_wizard_attention_lines "•")
assert_output_empty "unset_python_found" "$out"

# --- Test 3: PYTHON_FOUND=true, all three features enabled --------------------
echo "=== Test 3: PYTHON_FOUND=true, all features enabled ==="
_reset
export _WIZARD_PYTHON_FOUND="true"
export _WIZARD_TUI_ENABLED="true"
export _WIZARD_REPO_MAP_ENABLED="true"
export _WIZARD_SERENA_ENABLED="true"

out=$(_wizard_attention_lines "✓")
assert_output_contains "all_features: header phrase" "Enhanced features enabled:" "$out"
assert_output_contains "all_features: TUI listed" "TUI" "$out"
assert_output_contains "all_features: repo maps listed" "repo maps" "$out"
assert_output_contains "all_features: Serena listed" "Serena" "$out"
assert_output_contains "all_features: bullet passthrough" "✓" "$out"

# --- Test 4: PYTHON_FOUND=true, TUI=auto (non-interactive path) ---------------
echo "=== Test 4: PYTHON_FOUND=true, TUI=auto ==="
_reset
export _WIZARD_PYTHON_FOUND="true"
export _WIZARD_TUI_ENABLED="auto"
export _WIZARD_REPO_MAP_ENABLED="true"

out=$(_wizard_attention_lines "•")
assert_output_contains "tui_auto: TUI listed" "TUI" "$out"
assert_output_contains "tui_auto: repo maps listed" "repo maps" "$out"
assert_output_not_contains "tui_auto: Serena not listed" "Serena" "$out"

# --- Test 5: PYTHON_FOUND=true, only one feature selected ---------------------
echo "=== Test 5: PYTHON_FOUND=true, only repo maps enabled ==="
_reset
export _WIZARD_PYTHON_FOUND="true"
export _WIZARD_REPO_MAP_ENABLED="true"
# TUI and Serena left unset

out=$(_wizard_attention_lines "-")
assert_output_contains "one_feature: header phrase" "Enhanced features enabled:" "$out"
assert_output_contains "one_feature: repo maps listed" "repo maps" "$out"
assert_output_not_contains "one_feature: TUI not listed" "TUI" "$out"
assert_output_not_contains "one_feature: Serena not listed" "Serena" "$out"

# --- Test 6: PYTHON_FOUND=true, no features selected — empty output -----------
echo "=== Test 6: PYTHON_FOUND=true, no features selected — empty output ==="
_reset
export _WIZARD_PYTHON_FOUND="true"
# All feature vars deliberately left unset

out=$(_wizard_attention_lines "•")
assert_output_empty "no_features_selected" "$out"

# --- Test 7: custom bullet glyph is forwarded verbatim ------------------------
echo "=== Test 7: custom bullet glyph forwarded verbatim ==="
_reset
export _WIZARD_PYTHON_FOUND="false"

out_hash=$(_wizard_attention_lines "#")
assert_output_contains "custom_bullet_hash" "#" "$out_hash"

out_arrow=$(_wizard_attention_lines "->")
assert_output_contains "custom_bullet_arrow" "->" "$out_arrow"

# --- Summary ------------------------------------------------------------------
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
