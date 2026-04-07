#!/usr/bin/env bash
# =============================================================================
# test_platform_web_component_tokens.sh — Component dir + token detection
#                                           tests for platforms/web/ (M58)
#
# Split from test_platform_web_detection.sh. Tests 21-26: component
# directory detection and CSS custom property / design token detection.
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

# Source detect.sh for _extract_json_keys and _check_dep
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# Helper to reset globals and create fresh project dir
reset_and_make() {
    DESIGN_SYSTEM=""
    DESIGN_SYSTEM_CONFIG=""
    COMPONENT_LIBRARY_DIR=""
    PROJECT_DIR="${TEST_TMPDIR}/proj_${1}"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
}

# Helper to source detect.sh for web platform
run_web_detect() {
    # shellcheck source=/dev/null
    source "${TEKHTON_HOME}/platforms/web/detect.sh"
}

echo "=== test_platform_web_component_tokens.sh ==="

# --- Component directory detection --------------------------------------------

# Test 21: src/components/ui/
reset_and_make "comp_ui"
mkdir -p "$PROJECT_DIR/src/components/ui"
run_web_detect
[[ "$COMPONENT_LIBRARY_DIR" == "${PROJECT_DIR}/src/components/ui" ]] && pass "21: Component dir src/components/ui/" || fail "21: Component dir (got: $COMPONENT_LIBRARY_DIR)"

# Test 22: src/components/common/
reset_and_make "comp_common"
mkdir -p "$PROJECT_DIR/src/components/common"
run_web_detect
[[ "$COMPONENT_LIBRARY_DIR" == "${PROJECT_DIR}/src/components/common" ]] && pass "22: Component dir src/components/common/" || fail "22: Component dir (got: $COMPONENT_LIBRARY_DIR)"

# Test 23: app/components/ui/
reset_and_make "comp_app"
mkdir -p "$PROJECT_DIR/app/components/ui"
run_web_detect
[[ "$COMPONENT_LIBRARY_DIR" == "${PROJECT_DIR}/app/components/ui" ]] && pass "23: Component dir app/components/ui/" || fail "23: Component dir (got: $COMPONENT_LIBRARY_DIR)"

# --- CSS custom property / design token detection -----------------------------

# Test 24: variables.css in src/
reset_and_make "tokens_src"
mkdir -p "$PROJECT_DIR/src"
touch "$PROJECT_DIR/src/variables.css"
run_web_detect
[[ "$DESIGN_SYSTEM_CONFIG" == "${PROJECT_DIR}/src/variables.css" ]] && pass "24: CSS tokens in src/" || fail "24: CSS tokens in src/ (got: $DESIGN_SYSTEM_CONFIG)"

# Test 25: tokens.scss in root
reset_and_make "tokens_root"
touch "$PROJECT_DIR/tokens.scss"
run_web_detect
[[ "$DESIGN_SYSTEM_CONFIG" == "${PROJECT_DIR}/tokens.scss" ]] && pass "25: CSS tokens in root" || fail "25: CSS tokens in root (got: $DESIGN_SYSTEM_CONFIG)"

# Test 26: Design tokens not overridden when config already set (e.g., Tailwind)
reset_and_make "tokens_no_override"
touch "$PROJECT_DIR/tailwind.config.js"
mkdir -p "$PROJECT_DIR/src"
touch "$PROJECT_DIR/src/variables.css"
run_web_detect
[[ "$DESIGN_SYSTEM_CONFIG" == "${PROJECT_DIR}/tailwind.config.js" ]] && pass "26: Tokens don't override existing config" || fail "26: Tokens don't override existing config (got: $DESIGN_SYSTEM_CONFIG)"

# --- Summary ------------------------------------------------------------------

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
