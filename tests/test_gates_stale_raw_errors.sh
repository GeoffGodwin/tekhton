#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_gates_stale_raw_errors.sh — Tests for stale BUILD_RAW_ERRORS.txt cleanup
#
# Tests:
#   run_build_gate: removes stale BUILD_RAW_ERRORS.txt at entry (M53 fix)
#   run_build_gate: writes BUILD_RAW_ERRORS.txt with raw (not markdown) content on Phase 1 fail
#   run_build_gate: stale file from prior failed run cleaned before next gate run
#
# Milestone 53: Error Pattern Registry — Coverage gap 1 from reviewer cycle 3
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/error_patterns_remediation.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/gates.sh"
source "${TEKHTON_HOME}/lib/gates_phases.sh"
source "${TEKHTON_HOME}/lib/gates_ui.sh"

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT
cd "$TMPDIR_TEST"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Minimal config vars required by run_build_gate
export BUILD_GATE_TIMEOUT=60
export BUILD_CHECK_CMD=""
export UI_TEST_CMD=""
export UI_VALIDATION_ENABLED=false
export DEPENDENCY_CONSTRAINTS_FILE=""

# =============================================================================
# Test 1: Stale BUILD_RAW_ERRORS.txt removed when gate passes cleanly
# =============================================================================
echo "=== Stale file removed on passing gate ==="

export ANALYZE_CMD="true"
export ANALYZE_ERROR_PATTERN="^WILLNEVERMATCH$"

# Pre-seed a stale file with env error content
printf 'ECONNREFUSED 127.0.0.1:5432\nvenv directory not found\n' > BUILD_RAW_ERRORS.txt

gate_exit=0
run_build_gate "test-stale-pass" || gate_exit=$?

if [[ "$gate_exit" -eq 0 ]]; then
    pass
else
    fail "Gate should pass with ANALYZE_CMD=true, got exit ${gate_exit}"
fi

if [[ ! -f BUILD_RAW_ERRORS.txt ]]; then
    pass
else
    fail "Stale BUILD_RAW_ERRORS.txt should be removed after clean gate pass (still present)"
fi

# =============================================================================
# Test 2: BUILD_RAW_ERRORS.txt absent when no prior run left one (clean start)
# =============================================================================
echo "=== No BUILD_RAW_ERRORS.txt after clean gate with no stale file ==="

rm -f BUILD_RAW_ERRORS.txt BUILD_ERRORS.md

gate_exit2=0
run_build_gate "test-clean-pass" || gate_exit2=$?

if [[ "$gate_exit2" -eq 0 ]]; then
    pass
else
    fail "Gate should pass, got exit ${gate_exit2}"
fi

if [[ ! -f BUILD_RAW_ERRORS.txt ]]; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt should not be created by a passing gate"
fi

# =============================================================================
# Test 3: Phase 1 failure writes BUILD_RAW_ERRORS.txt with raw error lines
# =============================================================================
echo "=== Phase 1 failure writes raw (not markdown) content ==="

export ANALYZE_CMD="printf 'ECONNREFUSED 127.0.0.1:5432\n'"
export ANALYZE_ERROR_PATTERN="ECONNREFUSED"

rm -f BUILD_RAW_ERRORS.txt BUILD_ERRORS.md

gate_exit3=0
run_build_gate "test-phase1-fail" || gate_exit3=$?

if [[ "$gate_exit3" -ne 0 ]]; then
    pass
else
    fail "Gate should fail when ANALYZE_CMD outputs matching errors"
fi

if [[ -f BUILD_RAW_ERRORS.txt ]]; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt should be written after Phase 1 failure"
fi

raw_content=$(cat BUILD_RAW_ERRORS.txt)

# Content must be the raw error line, not markdown headers
if echo "$raw_content" | grep -q "ECONNREFUSED"; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt should contain raw error text, got: ${raw_content}"
fi

# Content must NOT have markdown headers (those go in BUILD_ERRORS.md only)
if ! echo "$raw_content" | grep -q "^# "; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt must not contain markdown headers (# ...); got: ${raw_content}"
fi

# =============================================================================
# Test 4: Stale file from a prior failed gate is cleaned before the next gate
# =============================================================================
echo "=== Stale file from prior failed run cleaned before new gate ==="

# BUILD_RAW_ERRORS.txt now exists from Test 3 (Phase 1 failure)
# Reset to a passing ANALYZE_CMD and verify the stale file is removed
export ANALYZE_CMD="true"
export ANALYZE_ERROR_PATTERN="^WILLNEVERMATCH$"

gate_exit4=0
run_build_gate "test-stale-after-fail" || gate_exit4=$?

if [[ "$gate_exit4" -eq 0 ]]; then
    pass
else
    fail "Gate should pass with ANALYZE_CMD=true, got exit ${gate_exit4}"
fi

if [[ ! -f BUILD_RAW_ERRORS.txt ]]; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt from prior failed run should be cleaned up (still present)"
fi

# =============================================================================
# Test 5: Stale file from prior run does not influence new Phase 1 failure
# =============================================================================
echo "=== Stale env file cleaned before new code-error Phase 1 failure ==="

# Create a stale file with env error content (service_dep)
printf 'ECONNREFUSED 127.0.0.1:5432\n' > BUILD_RAW_ERRORS.txt

# Now run a gate where Phase 1 fails with a code error
export ANALYZE_CMD="printf 'error TS2304: Cannot find name foo\n'"
export ANALYZE_ERROR_PATTERN="error TS"

rm -f BUILD_ERRORS.md

gate_exit5=0
run_build_gate "test-stale-replaced" || gate_exit5=$?

if [[ "$gate_exit5" -ne 0 ]]; then
    pass
else
    fail "Gate should fail with TypeScript errors, got exit 0"
fi

if [[ -f BUILD_RAW_ERRORS.txt ]]; then
    new_raw=$(cat BUILD_RAW_ERRORS.txt)
    # Must contain the NEW error (TypeScript), not the stale env error
    if echo "$new_raw" | grep -q "TS2304"; then
        pass
    else
        fail "BUILD_RAW_ERRORS.txt should contain new code error, got: ${new_raw}"
    fi

    if ! echo "$new_raw" | grep -q "ECONNREFUSED"; then
        pass
    else
        fail "BUILD_RAW_ERRORS.txt must not contain stale env error content; got: ${new_raw}"
    fi
else
    fail "BUILD_RAW_ERRORS.txt should exist after Phase 1 failure"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "--------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
echo "gates_stale_raw_errors tests passed"
