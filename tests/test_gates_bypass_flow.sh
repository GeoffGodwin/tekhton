#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_gates_bypass_flow.sh — Integration: gate env failure → bypass decision
#
# Tests the full gate→coder bypass path introduced in M53:
#   1. run_build_gate with env error → writes BUILD_RAW_ERRORS.txt
#   2. has_only_noncode_errors on BUILD_RAW_ERRORS.txt → returns 0 (bypass)
#   3. has_only_noncode_errors on annotated BUILD_ERRORS.md → returns 1
#      (markdown headers produce unclassified → code fallback; validates that
#       raw file is always preferred — Phase 4 now writes BUILD_RAW_ERRORS.txt)
#   4. Code errors in BUILD_RAW_ERRORS.txt → returns 1 (no bypass)
#   5. Mixed env+code errors → returns 1 (no bypass)
#   6. Pure env multi-category errors → returns 0 (bypass)
#
# Milestone 53: Error Pattern Registry — Coverage gap 2 from reviewer cycle 3
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
# Test 1: Gate Phase 1 env error → BUILD_RAW_ERRORS.txt → bypass triggers
# =============================================================================
echo "=== Gate env error → raw file → bypass (has_only_noncode_errors returns 0) ==="

export ANALYZE_CMD="printf 'ECONNREFUSED 127.0.0.1:5432\n'"
export ANALYZE_ERROR_PATTERN="ECONNREFUSED"

rm -f BUILD_RAW_ERRORS.txt BUILD_ERRORS.md

gate_exit=0
run_build_gate "test-bypass-env" || gate_exit=$?

if [[ "$gate_exit" -ne 0 ]]; then
    pass
else
    fail "Gate should fail on env errors"
fi

# Verify BUILD_RAW_ERRORS.txt was produced by the gate
if [[ -f BUILD_RAW_ERRORS.txt ]]; then
    pass
else
    fail "BUILD_RAW_ERRORS.txt must exist after Phase 1 env failure"
fi

# Simulate what coder.sh does: read BUILD_RAW_ERRORS.txt, call has_only_noncode_errors
raw_from_gate=$(cat BUILD_RAW_ERRORS.txt)
if has_only_noncode_errors "$raw_from_gate"; then
    pass  # All service_dep → bypass should trigger
else
    fail "has_only_noncode_errors on ECONNREFUSED raw content should return 0 (bypass); got non-zero"
fi

# =============================================================================
# Test 2: Annotated BUILD_ERRORS.md (written by gate) → markdown headers
#         cause unclassified fallback → has_only_noncode_errors returns 1.
#         This validates that the raw file path is always preferred over
#         BUILD_ERRORS.md (Phase 4 now writes BUILD_RAW_ERRORS.txt, so this
#         fallback only fires if raw file is missing for an unforeseen reason).
# =============================================================================
echo "=== Annotated BUILD_ERRORS.md markdown headers → no bypass (validates raw-file preference) ==="

# BUILD_ERRORS.md was written by the gate in Test 1 with annotated format
if [[ -f BUILD_ERRORS.md ]]; then
    pass
else
    fail "BUILD_ERRORS.md must exist from gate failure in Test 1"
fi

md_content=$(cat BUILD_ERRORS.md)

# Markdown headers like "# Build Errors — ..." are unclassified → "code" fallback
# so has_only_noncode_errors returns 1 — confirms raw file must be preferred
if ! has_only_noncode_errors "$md_content"; then
    pass  # Expected: markdown headers prevent bypass — raw file is the correct input
else
    fail "has_only_noncode_errors on annotated BUILD_ERRORS.md should return 1 (markdown headers → code fallback)"
fi

# Cross-check: if we strip markdown and pass only the raw error line, bypass DOES trigger
raw_only="ECONNREFUSED 127.0.0.1:5432"
if has_only_noncode_errors "$raw_only"; then
    pass  # Confirms: the raw error alone would bypass; it's the markdown overhead that blocks it
else
    fail "has_only_noncode_errors on bare ECONNREFUSED line should return 0"
fi

# =============================================================================
# Test 3: Phase 1 code error → BUILD_RAW_ERRORS.txt has code error → no bypass
# =============================================================================
echo "=== Code error in raw file → no bypass (has_only_noncode_errors returns 1) ==="

export ANALYZE_CMD="printf 'error TS2304: Cannot find name foo\n'"
export ANALYZE_ERROR_PATTERN="error TS"

rm -f BUILD_RAW_ERRORS.txt BUILD_ERRORS.md

gate_exit2=0
run_build_gate "test-code-no-bypass" || gate_exit2=$?

if [[ "$gate_exit2" -ne 0 ]]; then
    pass
else
    fail "Gate should fail on code errors"
fi

if [[ -f BUILD_RAW_ERRORS.txt ]]; then
    raw_code=$(cat BUILD_RAW_ERRORS.txt)
    if ! has_only_noncode_errors "$raw_code"; then
        pass  # Correctly: TypeScript error → no bypass
    else
        fail "has_only_noncode_errors on TS2304 raw content should return 1; got 0 (would incorrectly bypass)"
    fi
else
    fail "BUILD_RAW_ERRORS.txt must exist after Phase 1 code failure"
fi

# =============================================================================
# Test 4: Mixed errors in Phase 1 (env + code) → no bypass
# =============================================================================
echo "=== Mixed env+code errors → no bypass ==="

export ANALYZE_CMD="printf 'ECONNREFUSED 127.0.0.1:5432\nerror TS2304: Cannot find name foo\n'"
export ANALYZE_ERROR_PATTERN="ECONNREFUSED|error TS"

rm -f BUILD_RAW_ERRORS.txt BUILD_ERRORS.md

gate_exit3=0
run_build_gate "test-mixed-no-bypass" || gate_exit3=$?

if [[ "$gate_exit3" -ne 0 ]]; then
    pass
else
    fail "Gate should fail on mixed errors"
fi

if [[ -f BUILD_RAW_ERRORS.txt ]]; then
    raw_mixed=$(cat BUILD_RAW_ERRORS.txt)
    if ! has_only_noncode_errors "$raw_mixed"; then
        pass  # Mixed: code error present → bypass must NOT trigger
    else
        fail "has_only_noncode_errors on mixed env+code content should return 1"
    fi
else
    fail "BUILD_RAW_ERRORS.txt must exist after Phase 1 mixed failure"
fi

# =============================================================================
# Test 5: Pure env multi-category content → bypass triggers
# =============================================================================
echo "=== Pure env multi-category errors → bypass (has_only_noncode_errors returns 0) ==="

# env_setup + service_dep + toolchain: all non-code → bypass
multi_env_raw="ECONNREFUSED 127.0.0.1:6379
Cannot find module 'express'
npx playwright install"

if has_only_noncode_errors "$multi_env_raw"; then
    pass
else
    fail "Pure env/toolchain/service errors should all be non-code → bypass should trigger"
fi

# =============================================================================
# Test 6: toolchain-only content (npm module missing) → bypass triggers
# =============================================================================
echo "=== Toolchain-only errors → bypass ==="

toolchain_raw="ModuleNotFoundError: No module named 'flask'
missing go.sum entry for module"

if has_only_noncode_errors "$toolchain_raw"; then
    pass
else
    fail "Toolchain-only errors (ModuleNotFoundError, missing go.sum) should trigger bypass"
fi

# =============================================================================
# Test 7: resource-only content (port in use) → bypass triggers
# =============================================================================
echo "=== Resource-only errors → bypass ==="

resource_raw="Error: listen EADDRINUSE :::3000"

if has_only_noncode_errors "$resource_raw"; then
    pass
else
    fail "Resource-only errors (EADDRINUSE) should trigger bypass"
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
echo "gates_bypass_flow tests passed"
