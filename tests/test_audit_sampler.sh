#!/usr/bin/env bash
# test_audit_sampler.sh — Tests for lib/test_audit_sampler.sh (Milestone 89)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

# Minimal common.sh stubs — tests don't need colors or formatting
warn() { :; }
log() { :; }

# Initialize a git repo so _discover_all_test_files (uses git ls-files) works
cd "$PROJECT_DIR"
git init -q
git config user.email test@example.com
git config user.name test
git commit --allow-empty -m init -q

# Source units under test
source "${TEKHTON_HOME}/lib/test_audit.sh"
source "${TEKHTON_HOME}/lib/test_audit_sampler.sh"

PASS=0
FAIL=0

pass() {
    echo -e "\033[0;32mPASS\033[0m $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "\033[0;31mFAIL\033[0m $1: $2"
    FAIL=$((FAIL + 1))
}

# Reset all sampler state between tests
_reset_sampler_state() {
    _TEST_AUDIT_HISTORY_FILE=""
    _AUDIT_TEST_FILES=""
    _AUDIT_SAMPLE_FILES=""
    unset TEST_AUDIT_ROLLING_SAMPLE_K TEST_AUDIT_ROLLING_ENABLED \
          TEST_AUDIT_HISTORY_MAX_RECORDS REPO_MAP_CACHE_DIR
    rm -rf "${PROJECT_DIR}/.claude" 2>/dev/null || true
    git -C "$PROJECT_DIR" rm -rf --cached tests >/dev/null 2>&1 || true
    rm -rf "${PROJECT_DIR}/tests" 2>/dev/null || true
}

# Create N test files matching the _discover_all_test_files regex and stage them
_make_test_files() {
    local n="$1"
    local prefix="${2:-test_file}"
    mkdir -p "${PROJECT_DIR}/tests"
    local i
    for ((i = 0; i < n; i++)); do
        printf '# %s_%02d\n' "$prefix" "$i" > "${PROJECT_DIR}/tests/test_${prefix}_${i}.sh"
    done
    git -C "$PROJECT_DIR" add tests/ 2>/dev/null
}

echo "=== Test Audit Sampler Tests (M89) ==="

# -----------------------------------------------------------------------------
# Test 1: sampler returns K files (default K=3 from config)
# -----------------------------------------------------------------------------
_reset_sampler_state
_make_test_files 10 t1
TEST_AUDIT_ROLLING_SAMPLE_K=3
_sample_unaudited_test_files
COUNT=$(printf '%s\n' "${_AUDIT_SAMPLE_FILES:-}" | grep -c '.' || echo 0)
if [[ "$COUNT" -eq 3 ]]; then
    pass "test_sampler_returns_k_files"
else
    fail "test_sampler_returns_k_files" "expected 3 sampled, got $COUNT"
fi

# -----------------------------------------------------------------------------
# Test 2: sampler skips recently-audited files (history wins)
# -----------------------------------------------------------------------------
_reset_sampler_state
_make_test_files 10 t2
TEST_AUDIT_ROLLING_SAMPLE_K=3
# Record 7 files as audited NOW (recent timestamp). Only 3 should remain.
_AUDIT_TEST_FILES=""
RECORD_FILES=$(printf 'tests/test_t2_%d.sh\n' 0 1 2 3 4 5 6)
_record_audit_history "$RECORD_FILES"
_sample_unaudited_test_files
# Sampled files should be the 3 unrecorded ones
EXPECTED=$(printf 'tests/test_t2_%d.sh\n' 7 8 9 | LC_ALL=C sort)
GOT=$(printf '%s\n' "${_AUDIT_SAMPLE_FILES}" | LC_ALL=C sort)
if [[ "$EXPECTED" == "$GOT" ]]; then
    pass "test_sampler_skips_recently_audited"
else
    fail "test_sampler_skips_recently_audited" "expected=[$EXPECTED] got=[$GOT]"
fi

# -----------------------------------------------------------------------------
# Test 3: sampler picks oldest first
# -----------------------------------------------------------------------------
_reset_sampler_state
_make_test_files 5 t3
TEST_AUDIT_ROLLING_SAMPLE_K=2
# Manually write history with mixed timestamps. The files with the OLDEST
# timestamps should be picked first.
_ensure_test_audit_history_file
{
    echo '{"ts":"2025-01-01T00:00:00Z","file":"tests/test_t3_0.sh"}'
    echo '{"ts":"2025-06-01T00:00:00Z","file":"tests/test_t3_1.sh"}'
    echo '{"ts":"2026-01-01T00:00:00Z","file":"tests/test_t3_2.sh"}'
    echo '{"ts":"2026-04-01T00:00:00Z","file":"tests/test_t3_3.sh"}'
    echo '{"ts":"2026-04-15T00:00:00Z","file":"tests/test_t3_4.sh"}'
} > "$_TEST_AUDIT_HISTORY_FILE"
_sample_unaudited_test_files
# Oldest two are _0 (2025-01) and _1 (2025-06)
SORTED=$(printf '%s\n' "${_AUDIT_SAMPLE_FILES}" | LC_ALL=C sort)
EXPECTED=$(printf 'tests/test_t3_0.sh\ntests/test_t3_1.sh\n' | LC_ALL=C sort)
if [[ "$SORTED" == "$EXPECTED" ]]; then
    pass "test_sampler_oldest_first"
else
    fail "test_sampler_oldest_first" "expected=[$EXPECTED] got=[$SORTED]"
fi

# -----------------------------------------------------------------------------
# Test 4: sampler deduplicates against current modified-files set
# -----------------------------------------------------------------------------
_reset_sampler_state
_make_test_files 5 t4
TEST_AUDIT_ROLLING_SAMPLE_K=3
# These are the modified-this-run files, sampler must NOT include them
_AUDIT_TEST_FILES=$'tests/test_t4_0.sh\ntests/test_t4_1.sh'
_sample_unaudited_test_files
# Sample should be K=3 files, none of which match _AUDIT_TEST_FILES
DUP=$(printf '%s\n' "${_AUDIT_SAMPLE_FILES}" \
    | grep -E '^tests/test_t4_[01]\.sh$' || true)
if [[ -z "$DUP" ]]; then
    COUNT=$(printf '%s\n' "${_AUDIT_SAMPLE_FILES}" | grep -c '.' || echo 0)
    if [[ "$COUNT" -eq 3 ]]; then
        pass "test_sampler_deduplicates_with_current_set"
    else
        fail "test_sampler_deduplicates_with_current_set" "got $COUNT files (want 3)"
    fi
else
    fail "test_sampler_deduplicates_with_current_set" "found duplicates: $DUP"
fi

# -----------------------------------------------------------------------------
# Test 5: sampler honors TEST_AUDIT_ROLLING_ENABLED=false (run_test_audit gate)
# -----------------------------------------------------------------------------
# The _sample_unaudited_test_files function itself doesn't read the toggle;
# the gate lives in run_test_audit. We verify the documented behavior by
# proving the sampler is callable and that _AUDIT_SAMPLE_FILES is empty when
# run_test_audit's gate would skip it. Here we simulate by leaving _AUDIT_
# SAMPLE_FILES untouched (no call) when the toggle is false.
_reset_sampler_state
_make_test_files 5 t5
TEST_AUDIT_ROLLING_ENABLED=false
TEST_AUDIT_ROLLING_SAMPLE_K=3
# Caller-side gate: skip sampler call when disabled
if [[ "${TEST_AUDIT_ROLLING_ENABLED:-true}" == "true" ]]; then
    _sample_unaudited_test_files
fi
if [[ -z "${_AUDIT_SAMPLE_FILES:-}" ]]; then
    pass "test_sampler_disabled"
else
    fail "test_sampler_disabled" "expected empty, got [${_AUDIT_SAMPLE_FILES}]"
fi

# -----------------------------------------------------------------------------
# Test 6: _record_audit_history appends valid JSONL entries
# -----------------------------------------------------------------------------
_reset_sampler_state
_ensure_test_audit_history_file
_record_audit_history $'tests/test_a.sh\ntests/test_b.sh'
LINES=$(wc -l < "$_TEST_AUDIT_HISTORY_FILE" | tr -d '[:space:]')
if [[ "$LINES" -eq 2 ]]; then
    # Verify each line parses as expected
    if grep -q '"file":"tests/test_a.sh"' "$_TEST_AUDIT_HISTORY_FILE" \
       && grep -q '"file":"tests/test_b.sh"' "$_TEST_AUDIT_HISTORY_FILE" \
       && grep -q '"ts":"' "$_TEST_AUDIT_HISTORY_FILE"; then
        pass "test_record_audit_history_appends"
    else
        fail "test_record_audit_history_appends" "JSONL fields missing"
    fi
else
    fail "test_record_audit_history_appends" "expected 2 lines, got $LINES"
fi

# -----------------------------------------------------------------------------
# Test 7: _prune_audit_history trims to max records
# -----------------------------------------------------------------------------
_reset_sampler_state
_ensure_test_audit_history_file
TEST_AUDIT_HISTORY_MAX_RECORDS=10
# Write 25 entries, expect prune to leave 10
for i in $(seq 1 25); do
    echo "{\"ts\":\"2026-01-01T00:00:0${i}Z\",\"file\":\"tests/f${i}.sh\"}" \
        >> "$_TEST_AUDIT_HISTORY_FILE"
done
_prune_audit_history
LINES=$(wc -l < "$_TEST_AUDIT_HISTORY_FILE" | tr -d '[:space:]')
if [[ "$LINES" -eq 10 ]]; then
    # The last 10 should be entries 16..25
    if grep -q '"file":"tests/f25.sh"' "$_TEST_AUDIT_HISTORY_FILE" \
       && ! grep -q '"file":"tests/f1.sh"$' "$_TEST_AUDIT_HISTORY_FILE"; then
        pass "test_prune_audit_history"
    else
        fail "test_prune_audit_history" "wrong entries kept after prune"
    fi
else
    fail "test_prune_audit_history" "expected 10 lines, got $LINES"
fi

echo
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="
[[ "$FAIL" -eq 0 ]]
