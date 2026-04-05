#!/usr/bin/env bash
# =============================================================================
# test_platform_base.sh — Unit tests for platforms/_base.sh (Milestone 57)
#
# Tests:
#   1.  detect_ui_platform() maps react → web
#   2.  detect_ui_platform() maps vue → web
#   3.  detect_ui_platform() maps svelte → web
#   4.  detect_ui_platform() maps angular → web
#   5.  detect_ui_platform() maps next.js → web
#   6.  detect_ui_platform() maps playwright → web
#   7.  detect_ui_platform() maps cypress → web
#   8.  detect_ui_platform() maps testing-library → web
#   9.  detect_ui_platform() maps puppeteer → web
#  10.  detect_ui_platform() maps selenium → web
#  11.  detect_ui_platform() maps flutter → mobile_flutter
#  12.  detect_ui_platform() maps swiftui → mobile_native_ios
#  13.  detect_ui_platform() maps jetpack-compose → mobile_native_android
#  14.  detect_ui_platform() maps phaser → game_web
#  15.  detect_ui_platform() maps pixi → game_web
#  16.  detect_ui_platform() maps three → game_web
#  17.  detect_ui_platform() maps babylon → game_web
#  18.  detect_ui_platform() detox → no platform (no adapter yet)
#  19.  detect_ui_platform() generic + web-game → game_web
#  20.  detect_ui_platform() generic + mobile-app → mobile_flutter
#  21.  detect_ui_platform() generic + other → web
#  22.  detect_ui_platform() returns 1 for non-UI project
#  23.  detect_ui_platform() honors explicit UI_PLATFORM (not auto)
#  24.  detect_ui_platform() handles custom_<name> platform
#
# Fragment loading tests (25-31) are in test_platform_fragments.sh
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Set up minimal environment
PROJECT_DIR="$TEST_TMPDIR/project"
mkdir -p "$PROJECT_DIR"

# Source the module under test
source "${TEKHTON_HOME}/platforms/_base.sh"

# Helper to reset globals before each test
reset_ui_globals() {
    UI_PLATFORM=""
    UI_PLATFORM_DIR=""
    UI_PROJECT_DETECTED="false"
    UI_FRAMEWORK=""
    PROJECT_TYPE=""
    DESIGN_SYSTEM=""
    DESIGN_SYSTEM_CONFIG=""
    COMPONENT_LIBRARY_DIR=""
    UI_CODER_GUIDANCE=""
    UI_SPECIALIST_CHECKLIST=""
    UI_TESTER_PATTERNS=""
}

make_proj() {
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
}

echo "=== test_platform_base.sh ==="

# --- detect_ui_platform() framework → platform mapping tests ---

# Test 1: react → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="react"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "1: react → web" || fail "1: react → web (got: $UI_PLATFORM)"

# Test 2: vue → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="vue"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "2: vue → web" || fail "2: vue → web (got: $UI_PLATFORM)"

# Test 3: svelte → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="svelte"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "3: svelte → web" || fail "3: svelte → web (got: $UI_PLATFORM)"

# Test 4: angular → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="angular"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "4: angular → web" || fail "4: angular → web (got: $UI_PLATFORM)"

# Test 5: next.js → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="next.js"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "5: next.js → web" || fail "5: next.js → web (got: $UI_PLATFORM)"

# Test 6: playwright → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="playwright"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "6: playwright → web" || fail "6: playwright → web (got: $UI_PLATFORM)"

# Test 7: cypress → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="cypress"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "7: cypress → web" || fail "7: cypress → web (got: $UI_PLATFORM)"

# Test 8: testing-library → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="testing-library"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "8: testing-library → web" || fail "8: testing-library → web (got: $UI_PLATFORM)"

# Test 9: puppeteer → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="puppeteer"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "9: puppeteer → web" || fail "9: puppeteer → web (got: $UI_PLATFORM)"

# Test 10: selenium → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="selenium"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "10: selenium → web" || fail "10: selenium → web (got: $UI_PLATFORM)"

# Test 11: flutter → mobile_flutter
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="flutter"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_flutter" ]] && pass "11: flutter → mobile_flutter" || fail "11: flutter → mobile_flutter (got: $UI_PLATFORM)"

# Test 12: swiftui → mobile_native_ios
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="swiftui"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_native_ios" ]] && pass "12: swiftui → mobile_native_ios" || fail "12: swiftui → mobile_native_ios (got: $UI_PLATFORM)"

# Test 13: jetpack-compose → mobile_native_android
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="jetpack-compose"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_native_android" ]] && pass "13: jetpack-compose → mobile_native_android" || fail "13: jetpack-compose → mobile_native_android (got: $UI_PLATFORM)"

# Test 14: phaser → game_web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="phaser"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "14: phaser → game_web" || fail "14: phaser → game_web (got: $UI_PLATFORM)"

# Test 15: pixi → game_web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="pixi"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "15: pixi → game_web" || fail "15: pixi → game_web (got: $UI_PLATFORM)"

# Test 16: three → game_web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="three"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "16: three → game_web" || fail "16: three → game_web (got: $UI_PLATFORM)"

# Test 17: babylon → game_web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="babylon"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "17: babylon → game_web" || fail "17: babylon → game_web (got: $UI_PLATFORM)"

# Test 18: detox → no platform (Detox is React Native, not Flutter; no adapter yet)
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="detox"
if detect_ui_platform; then
    fail "18: detox should return 1 (no platform) (got: $UI_PLATFORM)"
else
    [[ -z "$UI_PLATFORM" ]] && pass "18: detox → no platform" || fail "18: detox platform should be empty (got: $UI_PLATFORM)"
fi

# Test 19: generic + web-game → game_web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK=""
PROJECT_TYPE="web-game"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "19: generic + web-game → game_web" || fail "19: generic + web-game → game_web (got: $UI_PLATFORM)"

# Test 20: generic + mobile-app → mobile_flutter
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK=""
PROJECT_TYPE="mobile-app"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_flutter" ]] && pass "20: generic + mobile-app → mobile_flutter" || fail "20: generic + mobile-app → mobile_flutter (got: $UI_PLATFORM)"

# Test 21: generic + other → web
reset_ui_globals
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK=""
PROJECT_TYPE="web-app"
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "21: generic + other → web" || fail "21: generic + other → web (got: $UI_PLATFORM)"

# Test 22: non-UI project returns 1
reset_ui_globals
UI_PROJECT_DETECTED="false"
if detect_ui_platform; then
    fail "22: non-UI project should return 1"
else
    [[ -z "$UI_PLATFORM" ]] && pass "22: non-UI project returns 1" || fail "22: non-UI platform should be empty (got: $UI_PLATFORM)"
fi

# Test 23: explicit UI_PLATFORM (not auto) is honored
reset_ui_globals
UI_PLATFORM="web"
UI_PROJECT_DETECTED="true"
UI_FRAMEWORK="flutter"  # Would normally map to mobile_flutter
detect_ui_platform
[[ "$UI_PLATFORM" == "web" ]] && pass "23: explicit UI_PLATFORM honored" || fail "23: explicit UI_PLATFORM should be honored (got: $UI_PLATFORM)"

# Test 24: custom_<name> platform resolves to user directory
reset_ui_globals
make_proj
mkdir -p "${PROJECT_DIR}/.claude/platforms/custom_myplatform"
UI_PLATFORM="custom_myplatform"
detect_ui_platform
[[ "$UI_PLATFORM" == "custom_myplatform" ]] && pass "24a: custom platform name preserved" || fail "24a: custom platform name (got: $UI_PLATFORM)"
[[ "$UI_PLATFORM_DIR" == "${PROJECT_DIR}/.claude/platforms/custom_myplatform" ]] && pass "24b: custom platform dir resolves" || fail "24b: custom platform dir (got: $UI_PLATFORM_DIR)"

# --- Summary ---
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
