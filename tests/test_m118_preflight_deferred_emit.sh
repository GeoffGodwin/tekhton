#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m118_preflight_deferred_emit.sh — M118 deferred emit pattern for preflight
#
# Verifies that run_preflight_checks() sets _PREFLIGHT_SUMMARY (not calls
# success()) on the PASS path, and leaves _PREFLIGHT_SUMMARY unset on
# WARN / FAIL / disabled / PREFLIGHT_FAIL_ON_WARN paths.
#
# Milestone 118: Preflight / Intake Success-Line Timing Fix
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks_env.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services_infer.sh"

TEKHTON_DIR=".tekhton"
PREFLIGHT_REPORT_FILE="${TEKHTON_DIR}/PREFLIGHT_REPORT.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

_make_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/.tekhton"
    echo "$tmpdir"
}

_cleanup() {
    [[ -n "${1:-}" ]] && rm -rf "$1"
}

# Override all individual check functions to produce exactly one pass result.
# Called at the top of run_preflight_checks, these stubs let us control the
# PASS/WARN/FAIL counters without depending on the real file-system state.
_stub_all_pass() {
    _preflight_check_dependencies() { _pf_record pass "Deps" "All clear"; }
    _preflight_check_tools()         { :; }
    _preflight_check_generated_code(){ :; }
    _preflight_check_env_vars()      { :; }
    _preflight_check_runtime_version(){ :; }
    _preflight_check_ports()         { :; }
    _preflight_check_lock_freshness(){ :; }
}

_stub_all_warn() {
    _preflight_check_dependencies() { _pf_record warn "Deps" "Something advisory"; }
    _preflight_check_tools()         { :; }
    _preflight_check_generated_code(){ :; }
    _preflight_check_env_vars()      { :; }
    _preflight_check_runtime_version(){ :; }
    _preflight_check_ports()         { :; }
    _preflight_check_lock_freshness(){ :; }
}

_stub_all_fail() {
    _preflight_check_dependencies() { _pf_record fail "Deps" "Something broken"; }
    _preflight_check_tools()         { :; }
    _preflight_check_generated_code(){ :; }
    _preflight_check_env_vars()      { :; }
    _preflight_check_runtime_version(){ :; }
    _preflight_check_ports()         { :; }
    _preflight_check_lock_freshness(){ :; }
}

# =============================================================================
# Test 1: PASS path sets _PREFLIGHT_SUMMARY to a non-empty string
# =============================================================================

echo "=== PASS path: _PREFLIGHT_SUMMARY is set ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_ENABLED=true
export PREFLIGHT_FAIL_ON_WARN=false
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

_stub_all_pass
run_preflight_checks

if [[ -n "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "PASS path should set _PREFLIGHT_SUMMARY (got empty or unset)"
fi

_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 2: PASS path _PREFLIGHT_SUMMARY contains expected summary format
# =============================================================================

echo "=== PASS path: _PREFLIGHT_SUMMARY content format ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

_stub_all_pass
run_preflight_checks

if [[ "${_PREFLIGHT_SUMMARY:-}" == *"passed"* ]]; then
    pass
else
    fail "_PREFLIGHT_SUMMARY should contain 'passed' (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

if [[ "${_PREFLIGHT_SUMMARY:-}" == *"Pre-flight:"* ]]; then
    pass
else
    fail "_PREFLIGHT_SUMMARY should contain 'Pre-flight:' prefix (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 3: PASS path does NOT call success() directly from run_preflight_checks
# =============================================================================

echo "=== PASS path: success() not called inside run_preflight_checks ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

# Override success to record whether it was called.
_M118_SUCCESS_CALLED=""
success() { _M118_SUCCESS_CALLED="true"; }

_stub_all_pass
run_preflight_checks

if [[ "${_M118_SUCCESS_CALLED:-}" != "true" ]]; then
    pass
else
    fail "run_preflight_checks should NOT call success() on PASS path (M118: caller emits after tui_stage_end)"
fi

# Restore success from common.sh
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
unset _M118_SUCCESS_CALLED

_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 4: WARN path leaves _PREFLIGHT_SUMMARY unset
# =============================================================================

echo "=== WARN path: _PREFLIGHT_SUMMARY stays unset ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_FAIL_ON_WARN=false
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

_stub_all_warn
run_preflight_checks

if [[ -z "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "WARN path should NOT set _PREFLIGHT_SUMMARY (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 5: FAIL path leaves _PREFLIGHT_SUMMARY unset
# =============================================================================

echo "=== FAIL path: _PREFLIGHT_SUMMARY stays unset ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

_stub_all_fail
rc=0
run_preflight_checks || rc=$?

if [[ -z "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "FAIL path should NOT set _PREFLIGHT_SUMMARY (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

if [[ "$rc" -ne 0 ]]; then
    pass
else
    fail "FAIL path should return non-zero (got rc=$rc)"
fi

_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 6: PREFLIGHT_ENABLED=false returns 0 and leaves _PREFLIGHT_SUMMARY unset
# =============================================================================

echo "=== PREFLIGHT_ENABLED=false: _PREFLIGHT_SUMMARY stays unset ==="

unset _PREFLIGHT_SUMMARY 2>/dev/null || true
export PREFLIGHT_ENABLED=false

run_preflight_checks

if [[ -z "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "Disabled preflight should NOT set _PREFLIGHT_SUMMARY (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

export PREFLIGHT_ENABLED=true

# =============================================================================
# Test 7: PREFLIGHT_FAIL_ON_WARN=true with warns leaves _PREFLIGHT_SUMMARY unset
# =============================================================================

echo "=== PREFLIGHT_FAIL_ON_WARN=true: _PREFLIGHT_SUMMARY stays unset ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_FAIL_ON_WARN=true
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

_stub_all_warn
rc=0
run_preflight_checks || rc=$?

if [[ -z "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "PREFLIGHT_FAIL_ON_WARN warn path should NOT set _PREFLIGHT_SUMMARY (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

if [[ "$rc" -ne 0 ]]; then
    pass
else
    fail "PREFLIGHT_FAIL_ON_WARN=true with warnings should return non-zero (got rc=$rc)"
fi

export PREFLIGHT_FAIL_ON_WARN=false
_cleanup "$PROJECT_DIR"

# =============================================================================
# Test 8: No applicable checks returns 0 and leaves _PREFLIGHT_SUMMARY unset
# =============================================================================

echo "=== No applicable checks: _PREFLIGHT_SUMMARY stays unset ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_ENABLED=true
unset _PREFLIGHT_SUMMARY 2>/dev/null || true

# Override all checks as true no-ops (produce no records → total=0 → early return)
_preflight_check_dependencies() { :; }
_preflight_check_tools()         { :; }
_preflight_check_generated_code(){ :; }
_preflight_check_env_vars()      { :; }
_preflight_check_runtime_version(){ :; }
_preflight_check_ports()         { :; }
_preflight_check_lock_freshness(){ :; }

run_preflight_checks

if [[ -z "${_PREFLIGHT_SUMMARY:-}" ]]; then
    pass
else
    fail "No-checks path should NOT set _PREFLIGHT_SUMMARY (got: '${_PREFLIGHT_SUMMARY:-}')"
fi

_cleanup "$PROJECT_DIR"

# =============================================================================
# Results
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
