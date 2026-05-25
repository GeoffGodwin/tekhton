#!/usr/bin/env bash
# =============================================================================
# tests/lib/parity.sh — Shared parity-gate driver.
#
# Sourced by parity-gate tests (test_preflight_parity.sh — m22, planned
# test_tui_parity.sh — m23, dashboard/drift gates in later milestones). Owns
# the diff/normalize/compare shape so each test file can focus on its own
# scenarios.
#
# Sourcing contract:
#   source "${TESTS_DIR}/lib/parity.sh"
#   PARITY_PASS=0; PARITY_FAIL=0
#   parity_assert_equal "scenario name" expected_file actual_file [normalize_fn]
#
# normalize_fn (optional) takes one argument: the file to normalise in place.
# When omitted, files are diffed verbatim.
# =============================================================================

PARITY_PASS=${PARITY_PASS:-0}
PARITY_FAIL=${PARITY_FAIL:-0}
_PARITY_FAIL_MESSAGES=""

parity_pass() {
    PARITY_PASS=$(( PARITY_PASS + 1 ))
    printf '\033[0;32mPASS\033[0m %s\n' "$1"
}

parity_fail() {
    PARITY_FAIL=$(( PARITY_FAIL + 1 ))
    printf '\033[0;31mFAIL\033[0m %s\n' "$1" >&2
    _PARITY_FAIL_MESSAGES+="$1"$'\n'
}

# parity_assert_equal NAME EXPECTED ACTUAL [NORMALIZE_FN]
parity_assert_equal() {
    local name="$1" expected="$2" actual="$3" normalize="${4:-}"
    if [[ ! -f "$expected" ]]; then
        parity_fail "${name}: expected file missing: ${expected}"
        return
    fi
    if [[ ! -f "$actual" ]]; then
        parity_fail "${name}: actual file missing: ${actual}"
        return
    fi
    if [[ -n "$normalize" ]]; then
        "$normalize" "$actual"
    fi
    if diff -u "$expected" "$actual" >/dev/null; then
        parity_pass "${name}: byte-identical to baseline"
    else
        parity_fail "${name}: diverges from baseline"
        diff -u "$expected" "$actual" || true
    fi
}

# parity_assert_no_file NAME ACTUAL
parity_assert_no_file() {
    local name="$1" actual="$2"
    if [[ -f "$actual" ]]; then
        parity_fail "${name}: expected no file at ${actual}"
    else
        parity_pass "${name}: no file emitted (matches baseline)"
    fi
}

# parity_summary — print summary, return 0 if no failures, 1 otherwise.
parity_summary() {
    local label="${1:-parity}"
    printf '\n=== %s: %d passed, %d failed ===\n' "$label" "$PARITY_PASS" "$PARITY_FAIL"
    if (( PARITY_FAIL > 0 )); then
        printf '\nFailures:\n%s' "$_PARITY_FAIL_MESSAGES" >&2
        return 1
    fi
    return 0
}
