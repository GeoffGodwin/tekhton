#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_dedup.sh — Tests for lib/test_dedup.sh (M105)
#
# Verifies working-tree fingerprint dedup: skip behavior after a recorded pass,
# cache invalidation on file changes / TEST_CMD changes, reset semantics, and
# graceful degradation in non-git directories.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

_PASS=0 _FAIL=0
pass() { _PASS=$((_PASS + 1)); echo "PASS: $1"; }
fail() { _FAIL=$((_FAIL + 1)); echo "FAIL: $1"; if [[ "${2:-}" == "fatal" ]]; then exit 1; fi; }

# Source the module under test
source "${TEKHTON_HOME}/lib/test_dedup.sh"

# --- Sandboxed git repo for fingerprint tests ---
TEST_TMP=$(mktemp -d)
trap 'rm -rf "$TEST_TMP"' EXIT

cd "$TEST_TMP"
git init -q
git config user.email "test@example.com"
git config user.name "Test"
echo "initial" > initial.txt
git add initial.txt
git commit -q -m "initial"

export TEKHTON_DIR="${TEST_TMP}/.tekhton"
mkdir -p "$TEKHTON_DIR"
# Mirror production: .tekhton/ is never empty when record_pass fires — agent
# outputs (CODER_SUMMARY.md, logs) already exist. Pre-populate so git status
# reports "?? .tekhton/" from the first call onward, making the fingerprint
# stable across record_pass writes.
echo "placeholder" > "${TEKHTON_DIR}/placeholder"
export TEST_CMD="echo ok"
export TEST_DEDUP_ENABLED="true"

# =============================================================================
# Suite 1: test_dedup_can_skip baseline behavior
# =============================================================================
echo ""
echo "=== Suite 1: baseline skip behavior ==="

# 1.1: No fingerprint file → must run
test_dedup_reset
if test_dedup_can_skip; then
    fail "1.1: Should NOT skip when no fingerprint exists"
else
    pass "1.1: Must run when no fingerprint cached"
fi

# 1.2: After record_pass with no changes → skip
test_dedup_record_pass
if test_dedup_can_skip; then
    pass "1.2: Skips after record_pass with no file changes"
else
    fail "1.2: Should skip when working tree matches recorded fingerprint"
fi

# 1.3: TEST_DEDUP_ENABLED=false → never skip
TEST_DEDUP_ENABLED=false
if test_dedup_can_skip; then
    fail "1.3: Should NOT skip when TEST_DEDUP_ENABLED=false"
else
    pass "1.3: Must run when TEST_DEDUP_ENABLED=false"
fi
TEST_DEDUP_ENABLED=true

# =============================================================================
# Suite 2: fingerprint invalidation on working-tree changes
# =============================================================================
echo ""
echo "=== Suite 2: invalidation on file changes ==="

# 2.1: Modifying a tracked file invalidates cache
test_dedup_reset
test_dedup_record_pass
echo "changed" >> initial.txt
if test_dedup_can_skip; then
    fail "2.1: Should NOT skip after modifying a tracked file"
else
    pass "2.1: Must run after tracked file modification"
fi
# Restore so subsequent suites start clean
git checkout -q -- initial.txt

# 2.2: Adding an untracked file invalidates cache
test_dedup_reset
test_dedup_record_pass
echo "new" > untracked.txt
if test_dedup_can_skip; then
    fail "2.2: Should NOT skip after adding untracked file"
else
    pass "2.2: Must run after untracked file appears"
fi
rm -f untracked.txt

# 2.3: Removing a tracked file invalidates cache
echo "to-delete" > to-delete.txt
git add to-delete.txt
git commit -q -m "add to-delete"
test_dedup_reset
test_dedup_record_pass
rm to-delete.txt
if test_dedup_can_skip; then
    fail "2.3: Should NOT skip after deleting a tracked file"
else
    pass "2.3: Must run after tracked file deletion"
fi
git checkout -q -- to-delete.txt

# =============================================================================
# Suite 3: TEST_CMD invalidates cache
# =============================================================================
echo ""
echo "=== Suite 3: TEST_CMD changes invalidate cache ==="

# 3.1: Changing TEST_CMD invalidates fingerprint even with no file changes
test_dedup_reset
export TEST_CMD="echo first"
test_dedup_record_pass
export TEST_CMD="echo second"
if test_dedup_can_skip; then
    fail "3.1: Should NOT skip when TEST_CMD changed"
else
    pass "3.1: Must run when TEST_CMD differs from recorded value"
fi
export TEST_CMD="echo ok"

# =============================================================================
# Suite 4: test_dedup_reset semantics
# =============================================================================
echo ""
echo "=== Suite 4: reset semantics ==="

# 4.1: Reset removes fingerprint file and forces must-run
test_dedup_record_pass
fp_file="${TEKHTON_DIR}/test_dedup.fingerprint"
if [[ ! -f "$fp_file" ]]; then
    fail "4.1 setup: fingerprint file not created"
fi
test_dedup_reset
if [[ -f "$fp_file" ]]; then
    fail "4.1: fingerprint file still exists after reset"
elif test_dedup_can_skip; then
    fail "4.1: Should NOT skip after reset"
else
    pass "4.1: reset removes fingerprint and forces must-run"
fi

# =============================================================================
# Suite 4.5: M112 — fingerprint includes HEAD identity
# =============================================================================
echo ""
echo "=== Suite 4.5: HEAD identity in fingerprint (M112) ==="

# Cache should be invalidated when HEAD changes even if the working tree is
# clean, so a different commit never reuses a prior pass fingerprint.
test_dedup_reset
test_dedup_record_pass
echo "second-file" > second.txt
git add second.txt
git commit -q -m "second commit"
# Clean working tree at a different HEAD — must NOT match prior fingerprint.
if test_dedup_can_skip; then
    fail "4.5.1: Should NOT skip across commits with clean working tree"
else
    pass "4.5.1: Different HEAD invalidates prior pass fingerprint"
fi
# Record at new HEAD, then confirm skip works at the same HEAD.
test_dedup_record_pass
if test_dedup_can_skip; then
    pass "4.5.2: Skips at same HEAD after record_pass"
else
    fail "4.5.2: Should skip with identical HEAD + clean tree after record_pass"
fi

# =============================================================================
# Suite 4.6: M112 — record_pass is a no-op when TEST_DEDUP_ENABLED=false
# =============================================================================
echo ""
echo "=== Suite 4.6: record_pass honors TEST_DEDUP_ENABLED (M112) ==="

test_dedup_reset
TEST_DEDUP_ENABLED=false
test_dedup_record_pass
TEST_DEDUP_ENABLED=true
if [[ -f "${TEKHTON_DIR}/test_dedup.fingerprint" ]]; then
    fail "4.6.1: record_pass wrote fingerprint despite TEST_DEDUP_ENABLED=false"
else
    pass "4.6.1: record_pass is a no-op when TEST_DEDUP_ENABLED=false"
fi

# =============================================================================
# Suite 5: non-git directory graceful degradation
# =============================================================================
echo ""
echo "=== Suite 5: non-git graceful degradation ==="

# 5.1: In a non-git directory, can_skip always returns must-run because the
# fallback fingerprint embeds a nanosecond timestamp that changes per call.
NON_GIT_TMP=$(mktemp -d)
pushd "$NON_GIT_TMP" >/dev/null
# Isolate fingerprint storage so prior suite state doesn't leak in
export TEKHTON_DIR="${NON_GIT_TMP}/.tekhton"
mkdir -p "$TEKHTON_DIR"
test_dedup_reset
test_dedup_record_pass
if test_dedup_can_skip; then
    fail "5.1: Should NOT skip in a non-git directory"
else
    pass "5.1: Non-git directory: must run (graceful degradation)"
fi
popd >/dev/null
rm -rf "$NON_GIT_TMP"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Summary ==="
echo "Passed: ${_PASS}, Failed: ${_FAIL}"
if [[ "$_FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
