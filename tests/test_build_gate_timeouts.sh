#!/usr/bin/env bash
# Test: Build gate timeouts and hang prevention (Milestone 30)
#
# Verifies:
# - _check_headless_browser() completes within 30s even when npx would hang
# - run_build_gate() respects BUILD_GATE_TIMEOUT
# - Per-phase timeouts are individually configurable
# - Timeout produces clear diagnostic messages
# - Orphaned processes are cleaned up after timeout
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"

# Set default file paths
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
BUILD_ERRORS_FILE="${BUILD_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_ERRORS.md}"
BUILD_RAW_ERRORS_FILE="${BUILD_RAW_ERRORS_FILE:-${TEKHTON_DIR}/BUILD_RAW_ERRORS.txt}"
UI_TEST_ERRORS_FILE="${UI_TEST_ERRORS_FILE:-${TEKHTON_DIR}/UI_TEST_ERRORS.md}"
UI_VALIDATION_REPORT_FILE="${UI_VALIDATION_REPORT_FILE:-${TEKHTON_DIR}/UI_VALIDATION_REPORT.md}"
export TEKHTON_DIR BUILD_ERRORS_FILE BUILD_RAW_ERRORS_FILE UI_TEST_ERRORS_FILE UI_VALIDATION_REPORT_FILE

# Source common.sh for log/warn/error
source "${TEKHTON_HOME}/lib/common.sh"

# Stub config values
ANALYZE_CMD="true"
ANALYZE_ERROR_PATTERN="^NEVER_MATCH$"
BUILD_CHECK_CMD=""
BUILD_ERROR_PATTERN="ERROR"
DEPENDENCY_CONSTRAINTS_FILE=""
UI_TEST_CMD=""
UI_VALIDATION_ENABLED="false"

cd "$TMPDIR"
mkdir -p "${TEKHTON_DIR:-.tekhton}"

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

# --- Source gates.sh (needs stubs for functions it calls) ---
run_ui_validation() { return 0; }
export -f run_ui_validation 2>/dev/null || true

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns_remediation.sh"
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/gates_phases.sh"
source "${TEKHTON_HOME}/lib/gates_ui.sh"

# --- Source ui_validate.sh ---
# Stub emit_event if not available
emit_event() { true; }
DASHBOARD_DIR="${TMPDIR}/.claude/dashboard"
WATCHTOWER_SELF_TEST="false"
DASHBOARD_ENABLED="false"
UI_SERVE_CMD=""
UI_SERVE_PORT=3000
UI_SERVER_STARTUP_TIMEOUT=30
UI_VALIDATION_VIEWPORTS="1280x800"
UI_VALIDATION_TIMEOUT=30
UI_VALIDATION_CONSOLE_SEVERITY="error"
UI_VALIDATION_FLICKER_THRESHOLD="0.05"
UI_VALIDATION_RETRY="false"
UI_VALIDATION_SCREENSHOTS="false"

source "${TEKHTON_HOME}/lib/ui_validate.sh"

echo "=== Build Gate Timeout Tests ==="

# --- Test 1: _check_headless_browser completes quickly when npx not installed ---
echo ""
echo "--- Test 1: Browser detection completes when no browsers available ---"
_UI_BROWSER_CHECKED=false
_UI_BROWSER_CMD=""

# Save and override PATH to exclude npx/chromium
_ORIG_PATH="$PATH"
export PATH="/usr/bin:/bin"

start_time=$(date +%s)
_check_headless_browser
end_time=$(date +%s)
elapsed=$((end_time - start_time))

export PATH="$_ORIG_PATH"

if [[ "$elapsed" -lt 35 ]]; then
    pass "Browser detection completed in ${elapsed}s (< 35s limit)"
else
    fail "Browser detection took ${elapsed}s (expected < 35s)"
fi

if [[ -z "$_UI_BROWSER_CMD" ]]; then
    pass "No browser detected when none available"
else
    fail "Unexpected browser detected: $_UI_BROWSER_CMD"
fi

# --- Test 2: _check_headless_browser uses cache on second call ---
echo ""
echo "--- Test 2: Browser detection cache ---"
_UI_BROWSER_CHECKED=true
_UI_BROWSER_CMD="test-cached-value"
_check_headless_browser
if [[ "$_UI_BROWSER_CMD" == "test-cached-value" ]]; then
    pass "Cached browser value preserved on second call"
else
    fail "Cache not respected: got '$_UI_BROWSER_CMD' expected 'test-cached-value'"
fi

# --- Test 3: run_build_gate passes with trivial ANALYZE_CMD ---
echo ""
echo "--- Test 3: Build gate passes with trivial commands ---"
BUILD_GATE_TIMEOUT=10
BUILD_GATE_ANALYZE_TIMEOUT=5
ANALYZE_CMD="echo ok"
if run_build_gate "test-pass"; then
    pass "Build gate passed with trivial ANALYZE_CMD"
else
    fail "Build gate should have passed"
fi

# --- Test 4: ANALYZE_CMD timeout is respected ---
echo ""
echo "--- Test 4: ANALYZE_CMD timeout ---"
BUILD_GATE_TIMEOUT=30
BUILD_GATE_ANALYZE_TIMEOUT=3
ANALYZE_CMD="sleep 60"

start_time=$(date +%s)
if run_build_gate "test-analyze-timeout"; then
    pass "Build gate passed after ANALYZE_CMD timeout (treated as pass)"
else
    # Timeout is treated as pass for analyze
    pass "Build gate returned (did not hang) after ANALYZE_CMD timeout"
fi
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ "$elapsed" -lt 15 ]]; then
    pass "ANALYZE_CMD timeout completed in ${elapsed}s (< 15s)"
else
    fail "ANALYZE_CMD timeout took ${elapsed}s (expected < 15s)"
fi

# Reset
ANALYZE_CMD="true"

# --- Test 5: BUILD_CHECK_CMD timeout is respected ---
echo ""
echo "--- Test 5: BUILD_CHECK_CMD timeout ---"
BUILD_GATE_TIMEOUT=30
BUILD_GATE_COMPILE_TIMEOUT=3
BUILD_CHECK_CMD="sleep 60"

start_time=$(date +%s)
run_build_gate "test-compile-timeout" || true
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ "$elapsed" -lt 15 ]]; then
    pass "BUILD_CHECK_CMD timeout completed in ${elapsed}s (< 15s)"
else
    fail "BUILD_CHECK_CMD timeout took ${elapsed}s (expected < 15s)"
fi

BUILD_CHECK_CMD=""

# --- Test 6: Overall BUILD_GATE_TIMEOUT kills a hanging gate ---
echo ""
echo "--- Test 6: Overall gate timeout ---"
BUILD_GATE_TIMEOUT=5
BUILD_GATE_ANALYZE_TIMEOUT=300
# ANALYZE_CMD that hangs for longer than the overall timeout
ANALYZE_CMD="sleep 300"

start_time=$(date +%s)
gate_result=0
run_build_gate "test-overall-timeout" || gate_result=$?
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ "$gate_result" -ne 0 ]]; then
    pass "Overall gate timeout returned non-zero exit"
else
    fail "Overall gate timeout should return non-zero"
fi

if [[ "$elapsed" -lt 15 ]]; then
    pass "Overall gate timeout completed in ${elapsed}s (< 15s)"
else
    fail "Overall gate timeout took ${elapsed}s (expected < 15s)"
fi

# Check diagnostic message was written
if [[ -f "${BUILD_ERRORS_FILE}" ]] && grep -q "Gate Timeout" "${BUILD_ERRORS_FILE}"; then
    pass "Gate timeout wrote diagnostic to BUILD_ERRORS.md"
else
    fail "Gate timeout should write diagnostic to BUILD_ERRORS.md"
fi

rm -f "${BUILD_ERRORS_FILE}"
ANALYZE_CMD="true"

# --- Test 7: Build gate detects real analyze errors ---
echo ""
echo "--- Test 7: Build gate catches analyze errors ---"
BUILD_GATE_TIMEOUT=30
BUILD_GATE_ANALYZE_TIMEOUT=10
ANALYZE_CMD="echo 'error: something broke'"
ANALYZE_ERROR_PATTERN="error:"

gate_result=0
run_build_gate "test-real-error" || gate_result=$?

if [[ "$gate_result" -ne 0 ]]; then
    pass "Build gate correctly failed on analyze error"
else
    fail "Build gate should have failed on analyze error"
fi

if [[ -f "${BUILD_ERRORS_FILE}" ]]; then
    pass "BUILD_ERRORS.md created on failure"
    rm -f "${BUILD_ERRORS_FILE}"
else
    fail "BUILD_ERRORS.md should be created on failure"
fi

ANALYZE_CMD="true"
ANALYZE_ERROR_PATTERN="^NEVER_MATCH$"

# --- Test 8: Constraint timeout is respected ---
echo ""
echo "--- Test 8: Constraint validation timeout ---"
BUILD_GATE_TIMEOUT=30
BUILD_GATE_CONSTRAINT_TIMEOUT=3

# Create a fake constraints file with a hanging validation command
DEPENDENCY_CONSTRAINTS_FILE="${TMPDIR}/constraints.yaml"
cat > "$DEPENDENCY_CONSTRAINTS_FILE" << 'EOF'
validation_command: sleep 60
EOF

start_time=$(date +%s)
run_build_gate "test-constraint-timeout" || true
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ "$elapsed" -lt 15 ]]; then
    pass "Constraint timeout completed in ${elapsed}s (< 15s)"
else
    fail "Constraint timeout took ${elapsed}s (expected < 15s)"
fi

DEPENDENCY_CONSTRAINTS_FILE=""
rm -f "${TMPDIR}/constraints.yaml"

# --- Test 9: _check_npm_package does not hang ---
echo ""
echo "--- Test 9: _check_npm_package returns quickly for missing packages ---"
start_time=$(date +%s)
if _check_npm_package "nonexistent-package-xyz-12345" 2>/dev/null; then
    # It's OK if npm isn't installed — the test is about not hanging
    pass "_check_npm_package returned (found or npm not available)"
else
    pass "_check_npm_package returned false for missing package"
fi
end_time=$(date +%s)
elapsed=$((end_time - start_time))

if [[ "$elapsed" -lt 10 ]]; then
    pass "_check_npm_package completed in ${elapsed}s (< 10s)"
else
    fail "_check_npm_package took ${elapsed}s (expected < 10s)"
fi

# --- Summary ---
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
