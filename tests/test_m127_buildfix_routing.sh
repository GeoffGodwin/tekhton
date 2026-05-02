#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_m127_buildfix_routing.sh — Coverage gaps from M127 reviewer report:
#
#   1. _bf_read_raw_errors fallback: when BUILD_RAW_ERRORS_FILE is absent, the
#      function must fall back to BUILD_ERRORS_FILE (documented skew risk).
#
#   2. run_build_fix_loop noncode_dominant arm (M128 superseded M127's
#      _run_buildfix_routing): verifies that write_pipeline_state is called
#      with exit_reason="env_failure" AND that exit 1 fires. The routing
#      token itself is tested in test_m127_routing.sh; this file covers the
#      terminal orchestrator behavior that was not previously asserted.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME
export TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder_buildfix.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT

# =============================================================================
# _bf_read_raw_errors — primary path: BUILD_RAW_ERRORS_FILE exists
# Reviewer gap: "annotated-file skew risk is documented in comments but
# unverified by assertion."
# =============================================================================
echo "=== _bf_read_raw_errors: prefers BUILD_RAW_ERRORS_FILE ==="

_raw_file="${_TMP}/BUILD_RAW_ERRORS.txt"
_build_file="${_TMP}/BUILD_ERRORS.md"
printf '%s\n' "raw content SENTINEL_RAW" > "$_raw_file"
printf '%s\n' "annotated content SENTINEL_ANN" > "$_build_file"

BUILD_RAW_ERRORS_FILE="$_raw_file"
BUILD_ERRORS_FILE="$_build_file"

got=$(_bf_read_raw_errors)
if [[ "$got" == *"SENTINEL_RAW"* ]]; then
    pass
else
    fail "_bf_read_raw_errors should read BUILD_RAW_ERRORS_FILE when it exists, got: ${got}"
fi
if [[ "$got" != *"SENTINEL_ANN"* ]]; then
    pass
else
    fail "_bf_read_raw_errors must NOT read BUILD_ERRORS_FILE when BUILD_RAW_ERRORS_FILE exists"
fi

# =============================================================================
# _bf_read_raw_errors — fallback path: BUILD_RAW_ERRORS_FILE absent
# =============================================================================
echo "=== _bf_read_raw_errors: fallback to BUILD_ERRORS_FILE when raw absent ==="

BUILD_RAW_ERRORS_FILE="${_TMP}/nonexistent_raw_XXXXX.txt"
BUILD_ERRORS_FILE="$_build_file"

got=$(_bf_read_raw_errors)
if [[ "$got" == *"SENTINEL_ANN"* ]]; then
    pass
else
    fail "_bf_read_raw_errors fallback must read BUILD_ERRORS_FILE; got: ${got}"
fi
if [[ "$got" != *"SENTINEL_RAW"* ]]; then
    pass
else
    fail "_bf_read_raw_errors fallback must not include raw-file content; got: ${got}"
fi

# =============================================================================
# run_build_fix_loop — noncode_dominant arm exits 1 (M128 superseded M127)
# Reviewer gap: "no test verifies that write_pipeline_state is called with
# env_failure and that exit 1 fires."
# =============================================================================
echo "=== run_build_fix_loop: noncode_dominant arm exits 1 ==="

_capture="${_TMP}/wps_args"

subshell_rc=0
(
    # Use pure noncode input so classify_routing_decision returns noncode_dominant.
    # ECONNREFUSED.*5432 matches service_dep (noncode); 1 match, total=1,
    # 100% >= 60% threshold → noncode_dominant per Rule 2.
    _bf_read_raw_errors() { printf '%s\n' "ECONNREFUSED 127.0.0.1:5432"; }

    # Capture write_pipeline_state args before the exit fires.
    write_pipeline_state() { printf '%s\n' "$@" > "${_capture}"; }

    # _build_resume_flag needs HUMAN_MODE/MILESTONE_MODE; override to be safe.
    _build_resume_flag() { echo "--start-at coder"; }

    # append_human_action is conditionally called; make it a no-op.
    append_human_action() { :; }

    # run_build_gate won't be reached on noncode_dominant (exit fires first),
    # but define it to avoid command-not-found under set -euo pipefail.
    run_build_gate() { return 0; }

    export TASK="test task"
    export BUILD_ERRORS_FILE="${_TMP}/BUILD_ERRORS.md"
    export BUILD_FIX_ENABLED=true

    run_build_fix_loop
) || subshell_rc=$?

if [[ "$subshell_rc" -eq 1 ]]; then
    pass
else
    fail "noncode_dominant arm must exit 1; got exit code ${subshell_rc}"
fi

# =============================================================================
# run_build_fix_loop — noncode_dominant records env_failure pipeline state
# =============================================================================
echo "=== run_build_fix_loop: noncode_dominant records env_failure state ==="

if [[ -f "$_capture" ]] && grep -q "env_failure" "$_capture"; then
    pass
else
    fail "write_pipeline_state not called with env_failure; capture: $(cat "$_capture" 2>/dev/null || echo '(missing)')"
fi

# Stage argument must be "coder" (first positional).
if [[ -f "$_capture" ]] && head -1 "$_capture" | grep -q "^coder$"; then
    pass
else
    fail "write_pipeline_state first arg must be 'coder'; capture: $(cat "$_capture" 2>/dev/null || echo '(missing)')"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
echo "M127 buildfix routing coverage tests passed"
