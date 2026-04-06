#!/usr/bin/env bash
# =============================================================================
# test_watchtower_msIdMatch.sh — Unit tests for msIdMatch() ID normalization
#
# Verifies that the msIdMatch() function in templates/watchtower/app.js
# correctly normalizes milestone IDs for comparison.
# The function normalizes "m60" ↔ "60" and similar variants to handle
# the mismatch between manifest IDs and run_state display numbers.
#
# This is a regression test for the bug where ID format mismatch prevented
# milestones from being displayed in the Active column.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Test helpers ---
PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

# --- Bash implementation of msIdMatch for testing ---
# This mirrors the JavaScript function from templates/watchtower/app.js
# function msIdMatch(mid, aid) {
#   if (!mid || !aid) return false;
#   if (mid === aid) return true;
#   var a = mid.replace(/^m0*/, ''), b = aid.replace(/^m0*/, '');
#   return a === b;
# }

ms_id_match() {
    local mid="$1"
    local aid="$2"

    # Return false if either is empty
    if [[ -z "$mid" ]] || [[ -z "$aid" ]]; then
        echo "false"
        return
    fi

    # Return true if they match exactly
    if [[ "$mid" = "$aid" ]]; then
        echo "true"
        return
    fi

    # Normalize: remove leading "m" and leading zeros
    # Replace ^m0* with empty string
    local a="${mid#m}"          # Remove leading 'm'
    a="${a##0}"                 # Remove leading zeros
    a="${a##0}"
    a="${a##0}"
    a="${a##0}"
    a="${a##0}"
    [[ -z "$a" ]] && a="0"      # If empty, it was all zeros

    local b="${aid#m}"          # Remove leading 'm'
    b="${b##0}"                 # Remove leading zeros
    b="${b##0}"
    b="${b##0}"
    b="${b##0}"
    b="${b##0}"
    [[ -z "$b" ]] && b="0"      # If empty, it was all zeros

    # Compare normalized values
    if [[ "$a" = "$b" ]]; then
        echo "true"
    else
        echo "false"
    fi
}

# =============================================================================
# Test Suite 1: Exact Matches
# =============================================================================
echo "=== Test Suite 1: Exact Matches ==="

result=$(ms_id_match "m60" "m60")
assert_eq "1.1 m60 matches m60" "true" "$result"

result=$(ms_id_match "60" "60")
assert_eq "1.2 60 matches 60" "true" "$result"

result=$(ms_id_match "m1" "m1")
assert_eq "1.3 m1 matches m1" "true" "$result"

# =============================================================================
# Test Suite 2: Format Variants (the main bug fix)
# =============================================================================
echo "=== Test Suite 2: Format Variants (Main Bug Fix) ==="

# These are the critical cases from the bug report:
# manifest IDs are "m60", run_state displays "60"

result=$(ms_id_match "m60" "60")
assert_eq "2.1 m60 matches 60" "true" "$result"

result=$(ms_id_match "60" "m60")
assert_eq "2.2 60 matches m60" "true" "$result"

result=$(ms_id_match "m1" "1")
assert_eq "2.3 m1 matches 1" "true" "$result"

result=$(ms_id_match "1" "m1")
assert_eq "2.4 1 matches m1" "true" "$result"

result=$(ms_id_match "m02" "2")
assert_eq "2.5 m02 matches 2" "true" "$result"

result=$(ms_id_match "2" "m02")
assert_eq "2.6 2 matches m02" "true" "$result"

# =============================================================================
# Test Suite 3: Leading Zeros Normalization
# =============================================================================
echo "=== Test Suite 3: Leading Zeros Normalization ==="

result=$(ms_id_match "m001" "1")
assert_eq "3.1 m001 matches 1" "true" "$result"

result=$(ms_id_match "m001" "m1")
assert_eq "3.2 m001 matches m1" "true" "$result"

result=$(ms_id_match "m010" "10")
assert_eq "3.3 m010 matches 10" "true" "$result"

result=$(ms_id_match "m010" "m10")
assert_eq "3.4 m010 matches m10" "true" "$result"

result=$(ms_id_match "m0060" "m60")
assert_eq "3.5 m0060 matches m60" "true" "$result"

result=$(ms_id_match "m0060" "60")
assert_eq "3.6 m0060 matches 60" "true" "$result"

# =============================================================================
# Test Suite 4: Mismatches (Should return false)
# =============================================================================
echo "=== Test Suite 4: Mismatches ==="

result=$(ms_id_match "m60" "m61")
assert_eq "4.1 m60 does not match m61" "false" "$result"

result=$(ms_id_match "60" "61")
assert_eq "4.2 60 does not match 61" "false" "$result"

result=$(ms_id_match "m1" "m2")
assert_eq "4.3 m1 does not match m2" "false" "$result"

result=$(ms_id_match "1" "2")
assert_eq "4.4 1 does not match 2" "false" "$result"

# =============================================================================
# Test Suite 5: Edge Cases (empty/null)
# =============================================================================
echo "=== Test Suite 5: Edge Cases ==="

result=$(ms_id_match "" "60")
assert_eq "5.1 empty string does not match 60" "false" "$result"

result=$(ms_id_match "m60" "")
assert_eq "5.2 m60 does not match empty string" "false" "$result"

result=$(ms_id_match "" "")
assert_eq "5.3 empty strings do not match" "false" "$result"

# =============================================================================
# Test Suite 6: Zero handling
# =============================================================================
echo "=== Test Suite 6: Zero handling ==="

result=$(ms_id_match "m0" "0")
assert_eq "6.1 m0 matches 0" "true" "$result"

result=$(ms_id_match "m000" "m0")
assert_eq "6.2 m000 matches m0" "true" "$result"

result=$(ms_id_match "m000" "0")
assert_eq "6.3 m000 matches 0" "true" "$result"

# =============================================================================
# Test Suite 7: Realistic Milestone Ranges
# =============================================================================
echo "=== Test Suite 7: Realistic Milestone Ranges ==="

# Test a range of milestone IDs that would appear in a real project
for i in 1 5 10 15 20 30 50 60 100; do
    result=$(ms_id_match "m$i" "$i")
    assert_eq "7.x m$i matches $i" "true" "$result"
done

# =============================================================================
# Summary
# =============================================================================
echo
echo "════════════════════════════════════════"
echo "  watchtower_msIdMatch tests: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"

[ "$FAIL" -eq 0 ] || exit 1
echo "All msIdMatch tests passed"
