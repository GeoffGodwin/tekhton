#!/usr/bin/env bash
# =============================================================================
# test_platform_fragments.sh — Unit tests for load_platform_fragments()
#
# Split from test_platform_base.sh to stay under 300-line ceiling.
#
# Tests:
#  25.  load_platform_fragments() loads universal coder guidance
#  26.  load_platform_fragments() loads universal specialist checklist
#  27.  load_platform_fragments() appends platform-specific content
#  28.  load_platform_fragments() appends user override content
#  29.  load_platform_fragments() handles missing platform dir gracefully
#  30.  load_platform_fragments() appends design system info
#  31.  load_platform_fragments() appends component library info
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

echo "=== test_platform_fragments.sh ==="

# --- load_platform_fragments() tests ---

# Test 25: loads universal coder guidance
reset_ui_globals
make_proj
UI_PLATFORM="web"
load_platform_fragments
[[ "$UI_CODER_GUIDANCE" == *"State Presentation"* ]] && pass "25: universal coder guidance loaded" || fail "25: universal coder guidance not found in UI_CODER_GUIDANCE"

# Test 26: loads universal specialist checklist
reset_ui_globals
make_proj
UI_PLATFORM="web"
load_platform_fragments
[[ "$UI_SPECIALIST_CHECKLIST" == *"Component Structure"* ]] && pass "26: universal specialist checklist loaded" || fail "26: universal specialist checklist not found"

# Test 27: appends platform-specific content (M58 provides real web/coder_guidance.prompt.md)
reset_ui_globals
make_proj
UI_PLATFORM="web"
load_platform_fragments
# Should have both universal and platform content (M58 file contains "Web-Specific Coder Guidance")
[[ "$UI_CODER_GUIDANCE" == *"State Presentation"* ]] && [[ "$UI_CODER_GUIDANCE" == *"Web-Specific Coder Guidance"* ]] \
    && pass "27: platform-specific content appended" \
    || fail "27: platform-specific content not appended"

# Test 28: appends user override content
reset_ui_globals
make_proj
mkdir -p "${PROJECT_DIR}/.claude/platforms/web"
echo "### Custom project guidance" > "${PROJECT_DIR}/.claude/platforms/web/coder_guidance.prompt.md"
UI_PLATFORM="web"
load_platform_fragments
[[ "$UI_CODER_GUIDANCE" == *"Custom project guidance"* ]] \
    && pass "28: user override content appended" \
    || fail "28: user override content not found in UI_CODER_GUIDANCE"

# Test 29: handles missing platform dir gracefully
reset_ui_globals
make_proj
UI_PLATFORM="nonexistent_platform"
load_platform_fragments
# Should still have universal content
[[ "$UI_CODER_GUIDANCE" == *"State Presentation"* ]] \
    && pass "29: graceful fallback with missing platform dir" \
    || fail "29: universal content missing on fallback"

# Test 30: appends design system info
reset_ui_globals
make_proj
UI_PLATFORM="web"
DESIGN_SYSTEM="Tailwind CSS"
DESIGN_SYSTEM_CONFIG="tailwind.config.js"
load_platform_fragments
[[ "$UI_CODER_GUIDANCE" == *"Design System: Tailwind CSS"* ]] \
    && pass "30: design system info appended" \
    || fail "30: design system info not found"

# Test 31: appends component library info
reset_ui_globals
make_proj
UI_PLATFORM="web"
COMPONENT_LIBRARY_DIR="src/components"
load_platform_fragments
[[ "$UI_CODER_GUIDANCE" == *"src/components"* ]] \
    && pass "31: component library info appended" \
    || fail "31: component library info not found"

# --- Summary ---
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
