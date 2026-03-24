#!/usr/bin/env bash
# Test: _semver_lt() edge cases
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS_COUNT=0
FAIL_COUNT=0

source "${TEKHTON_HOME}/lib/update_check.sh"

assert_lt() {
    local v1="$1" v2="$2" desc="$3"
    if _semver_lt "$v1" "$v2"; then
        echo "PASS: $desc"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        echo "FAIL: $desc — expected _semver_lt $v1 $v2 to return 0 (true)"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

assert_not_lt() {
    local v1="$1" v2="$2" desc="$3"
    if ! _semver_lt "$v1" "$v2"; then
        echo "PASS: $desc"
        PASS_COUNT=$(( PASS_COUNT + 1 ))
    else
        echo "FAIL: $desc — expected _semver_lt $v1 $v2 to return 1 (false)"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
}

# --- Equal versions (should return 1 / not less than) ---
assert_not_lt "1.2.3" "1.2.3" "equal versions: 1.2.3 not less than 1.2.3"
assert_not_lt "0.0.0" "0.0.0" "equal versions: 0.0.0 not less than 0.0.0"
assert_not_lt "3.19.0" "3.19.0" "equal versions: 3.19.0 not less than 3.19.0"

# --- Major-only bump ---
assert_lt     "1.0.0" "2.0.0" "major bump: 1.0.0 < 2.0.0"
assert_not_lt "2.0.0" "1.0.0" "major bump reversed: 2.0.0 not less than 1.0.0"
assert_lt     "0.0.0" "1.0.0" "major bump from zero: 0.0.0 < 1.0.0"

# --- Single-digit vs double-digit minor version (numeric, not lexicographic) ---
# Numeric comparison: 9 < 10 must hold (lexicographic would give "10" < "9")
assert_lt     "1.9.0"  "1.10.0" "minor: 1.9.0 < 1.10.0 (single vs double digit)"
assert_not_lt "1.10.0" "1.9.0"  "minor reversed: 1.10.0 not less than 1.9.0"
assert_lt     "1.9.9"  "1.10.0" "minor: 1.9.9 < 1.10.0"

# --- Patch-only bump ---
assert_lt     "1.2.3" "1.2.4" "patch bump: 1.2.3 < 1.2.4"
assert_not_lt "1.2.4" "1.2.3" "patch bump reversed: 1.2.4 not less than 1.2.3"

# --- Minor bump (same major) ---
assert_lt     "1.2.9" "1.3.0" "minor bump: 1.2.9 < 1.3.0"
assert_not_lt "1.3.0" "1.2.9" "minor bump reversed: 1.3.0 not less than 1.2.9"

# --- Downgrade ---
assert_not_lt "3.19.0" "3.18.0" "downgrade: 3.19.0 not less than 3.18.0"

# --- Summary ---
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "All _semver_lt tests passed ($PASS_COUNT)"
    exit 0
else
    echo "FAIL: $FAIL_COUNT tests failed ($PASS_COUNT passed)"
    exit 1
fi
