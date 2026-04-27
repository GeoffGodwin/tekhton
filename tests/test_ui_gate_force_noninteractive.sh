#!/usr/bin/env bash
# =============================================================================
# test_ui_gate_force_noninteractive.sh — M130 Priority 0 hook in _ui_detect_framework
#
# Covers the TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 short-circuit added in M130
# that makes the retry_ui_gate_env recovery action reliably trigger the hardened
# env profile on the next gate run, regardless of how the project's framework
# is normally detected.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# gates_ui_helpers.sh is self-contained — no transitive sources needed.
# shellcheck source=lib/gates_ui_helpers.sh
source "${TEKHTON_HOME}/lib/gates_ui_helpers.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" = "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# Helpers to isolate each test's env state
_clear_detection_vars() {
    TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=""
    UI_FRAMEWORK=""
    UI_TEST_CMD=""
    PROJECT_DIR="$TMPDIR"
}

# ============================================================================
# P0-T1: Priority 0 — TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1 forces playwright
# ============================================================================
echo "=== P0-T1: Priority 0 forces playwright when FORCE_NONINTERACTIVE=1 ==="
_clear_detection_vars
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
result=$(_ui_detect_framework)
assert_eq "P0-T1.1 returns playwright" "playwright" "$result"

# ============================================================================
# P0-T2: Priority 0 overrides UI_FRAMEWORK when FORCE_NONINTERACTIVE=1
# ============================================================================
echo "=== P0-T2: Priority 0 overrides UI_FRAMEWORK config ==="
_clear_detection_vars
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
UI_FRAMEWORK="none"
result=$(_ui_detect_framework)
assert_eq "P0-T2.1 overrides UI_FRAMEWORK=none" "playwright" "$result"

# ============================================================================
# P0-T3: Priority 0 overrides file-based detection when FORCE_NONINTERACTIVE=1
# ============================================================================
echo "=== P0-T3: Priority 0 fires even when no playwright.config.* file exists ==="
_clear_detection_vars
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
# PROJECT_DIR points at empty temp dir — no playwright config files present
result=$(_ui_detect_framework)
assert_eq "P0-T3.1 returns playwright with no config file" "playwright" "$result"

# ============================================================================
# P0-T4: Not set — falls through to normal detection (no regression)
# ============================================================================
echo "=== P0-T4: FORCE_NONINTERACTIVE unset — normal detection path unchanged ==="
_clear_detection_vars
# No framework signals present → should return "none"
result=$(_ui_detect_framework)
assert_eq "P0-T4.1 empty signals still return none" "none" "$result"

# ============================================================================
# P0-T5: Set to 0 — does NOT trigger Priority 0 (opt-out respected)
# ============================================================================
echo "=== P0-T5: FORCE_NONINTERACTIVE=0 does not trigger Priority 0 ==="
_clear_detection_vars
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
result=$(_ui_detect_framework)
assert_eq "P0-T5.1 value=0 falls through to normal detection" "none" "$result"

# ============================================================================
# P0-T6: Set to 1 — _ui_deterministic_env_list picks up hardened playwright env
# ============================================================================
echo "=== P0-T6: FORCE_NONINTERACTIVE=1 causes deterministic env list to emit playwright vars ==="
_clear_detection_vars
TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=1
env_list=$(_ui_deterministic_env_list 1)
if printf '%s' "$env_list" | grep -qF "PLAYWRIGHT_HTML_OPEN=never"; then
    echo "  PASS: P0-T6.1 hardened env list includes PLAYWRIGHT_HTML_OPEN=never"
    PASS=$((PASS + 1))
else
    echo "  FAIL: P0-T6.1 missing PLAYWRIGHT_HTML_OPEN=never in env list"
    FAIL=$((FAIL + 1))
fi
if printf '%s' "$env_list" | grep -qF "CI=1"; then
    echo "  PASS: P0-T6.2 hardened env list includes CI=1"
    PASS=$((PASS + 1))
else
    echo "  FAIL: P0-T6.2 missing CI=1 in hardened env list"
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Summary
# ============================================================================
echo
echo "════════════════════════════════════════"
echo "  M130 ui_gate Priority 0 tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All M130 ui_gate Priority 0 tests passed"
