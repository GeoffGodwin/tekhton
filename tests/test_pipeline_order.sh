#!/usr/bin/env bash
# =============================================================================
# test_pipeline_order.sh — Unit tests for lib/pipeline_order.sh (Milestone 27)
#
# Tests:
#   1. validate_pipeline_order: valid values (standard, test_first, auto)
#   2. validate_pipeline_order: invalid value returns 1
#   3. get_pipeline_order: standard order returns expected stage list
#   4. get_pipeline_order: test_first order returns expected stage list
#   5. get_pipeline_order: auto falls back to standard
#   6. get_pipeline_order: unset PIPELINE_ORDER defaults to standard
#   7. get_stage_count: standard order has 4 visible stages (scout excluded)
#   8. get_stage_count: test_first order has 5 visible stages (scout excluded)
#   9. get_stage_position: each stage in standard order has correct 1-based position
#  10. get_stage_position: each stage in test_first order has correct 1-based position
#  11. get_stage_position: unknown stage returns 0
#  12. should_run_stage: default start_at runs everything
#  13. should_run_stage: start_at=coder skips scout, runs coder+later
#  14. should_run_stage: start_at=review skips scout/coder/security
#  15. should_run_stage: start_at=test maps to test_verify (skips everything before it)
#  16. should_run_stage: start_at=intake runs everything
#  17. should_run_stage: test_first order — start_at=coder skips scout and test_write
#  18. should_run_stage: test_first order — start_at=test maps to test_verify
#  19. get_tester_mode: test_write returns write_failing
#  20. get_tester_mode: test_verify returns verify_passing
#  21. get_tester_mode: unknown stage returns verify_passing
#  22. is_test_first_order: returns 0 for test_first, 1 for standard
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source minimal common.sh (needed for warn() used by validate_pipeline_order)
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/pipeline_order.sh"

FAIL=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $name — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

assert_exit() {
    local name="$1" expected_exit="$2"
    shift 2
    local actual_exit=0
    "$@" > /dev/null 2>&1 || actual_exit=$?
    if [ "$expected_exit" != "$actual_exit" ]; then
        echo "FAIL: $name — expected exit $expected_exit, got $actual_exit"
        FAIL=1
    else
        echo "PASS: $name"
    fi
}

assert_true() {
    local name="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected success (exit 0)"
        FAIL=1
    fi
}

assert_false() {
    local name="$1"
    shift
    if ! "$@" > /dev/null 2>&1; then
        echo "PASS: $name"
    else
        echo "FAIL: $name — expected failure (exit non-zero)"
        FAIL=1
    fi
}

# =============================================================================
# Phase 1: validate_pipeline_order
# =============================================================================

assert_exit "1.1 validate_pipeline_order: standard → exit 0" 0 validate_pipeline_order "standard"
assert_exit "1.2 validate_pipeline_order: test_first → exit 0" 0 validate_pipeline_order "test_first"
assert_exit "1.3 validate_pipeline_order: auto → exit 0 (with warning)" 0 validate_pipeline_order "auto"
assert_exit "1.4 validate_pipeline_order: invalid value → exit 1" 1 validate_pipeline_order "parallel"
assert_exit "1.5 validate_pipeline_order: empty string → exit 1" 1 validate_pipeline_order ""

# =============================================================================
# Phase 2: get_pipeline_order — standard
# =============================================================================

PIPELINE_ORDER="standard"
assert_eq "2.1 get_pipeline_order: standard contains scout" \
    "scout coder security review test_verify" "$(get_pipeline_order)"

# =============================================================================
# Phase 3: get_pipeline_order — test_first
# =============================================================================

PIPELINE_ORDER="test_first"
assert_eq "3.1 get_pipeline_order: test_first stage list" \
    "scout test_write coder security review test_verify" "$(get_pipeline_order)"

# =============================================================================
# Phase 4: get_pipeline_order — fallback cases
# =============================================================================

PIPELINE_ORDER="auto"
assert_eq "4.1 get_pipeline_order: auto falls back to standard" \
    "scout coder security review test_verify" "$(get_pipeline_order)"

unset PIPELINE_ORDER
assert_eq "4.2 get_pipeline_order: unset PIPELINE_ORDER defaults to standard" \
    "scout coder security review test_verify" "$(get_pipeline_order)"

PIPELINE_ORDER="bogus"
assert_eq "4.3 get_pipeline_order: unrecognized value falls back to standard" \
    "scout coder security review test_verify" "$(get_pipeline_order)"

# =============================================================================
# Phase 5: get_stage_count
# =============================================================================

PIPELINE_ORDER="standard"
assert_eq "5.1 get_stage_count: standard has 4 visible stages" "4" "$(get_stage_count)"

PIPELINE_ORDER="test_first"
assert_eq "5.2 get_stage_count: test_first has 5 visible stages" "5" "$(get_stage_count)"

# =============================================================================
# Phase 6: get_stage_position — standard order
# =============================================================================

PIPELINE_ORDER="standard"
assert_eq "6.1 get_stage_position: scout is position 1 in standard" "1" "$(get_stage_position scout)"
assert_eq "6.2 get_stage_position: coder is position 2 in standard" "2" "$(get_stage_position coder)"
assert_eq "6.3 get_stage_position: security is position 3 in standard" "3" "$(get_stage_position security)"
assert_eq "6.4 get_stage_position: review is position 4 in standard" "4" "$(get_stage_position review)"
assert_eq "6.5 get_stage_position: test_verify is position 5 in standard" "5" "$(get_stage_position test_verify)"
assert_eq "6.6 get_stage_position: unknown stage returns 0" "0" "$(get_stage_position no_such_stage)"
# test_write does not exist in standard order
assert_eq "6.7 get_stage_position: test_write not in standard → 0" "0" "$(get_stage_position test_write)"

# =============================================================================
# Phase 7: get_stage_position — test_first order
# =============================================================================

PIPELINE_ORDER="test_first"
assert_eq "7.1 get_stage_position: scout is position 1 in test_first" "1" "$(get_stage_position scout)"
assert_eq "7.2 get_stage_position: test_write is position 2 in test_first" "2" "$(get_stage_position test_write)"
assert_eq "7.3 get_stage_position: coder is position 3 in test_first" "3" "$(get_stage_position coder)"
assert_eq "7.4 get_stage_position: security is position 4 in test_first" "4" "$(get_stage_position security)"
assert_eq "7.5 get_stage_position: review is position 5 in test_first" "5" "$(get_stage_position review)"
assert_eq "7.6 get_stage_position: test_verify is position 6 in test_first" "6" "$(get_stage_position test_verify)"

# =============================================================================
# Phase 8: should_run_stage — standard order
# =============================================================================

PIPELINE_ORDER="standard"

# default (empty start_at): everything runs
assert_true  "8.1 should_run_stage: default start_at runs scout"      should_run_stage "scout"      ""
assert_true  "8.2 should_run_stage: default start_at runs coder"      should_run_stage "coder"      ""
assert_true  "8.3 should_run_stage: default start_at runs test_verify" should_run_stage "test_verify" ""

# start_at=coder: scout should be skipped (pos 1 < 2), coder+ should run
assert_false "8.4 should_run_stage: coder start skips scout"           should_run_stage "scout"      "coder"
assert_true  "8.5 should_run_stage: coder start runs coder"            should_run_stage "coder"      "coder"
assert_true  "8.6 should_run_stage: coder start runs security"         should_run_stage "security"   "coder"
assert_true  "8.7 should_run_stage: coder start runs review"           should_run_stage "review"     "coder"
assert_true  "8.8 should_run_stage: coder start runs test_verify"      should_run_stage "test_verify" "coder"

# start_at=review: scout/coder/security skipped
assert_false "8.9  should_run_stage: review start skips scout"         should_run_stage "scout"      "review"
assert_false "8.10 should_run_stage: review start skips coder"         should_run_stage "coder"      "review"
assert_false "8.11 should_run_stage: review start skips security"      should_run_stage "security"   "review"
assert_true  "8.12 should_run_stage: review start runs review"         should_run_stage "review"     "review"
assert_true  "8.13 should_run_stage: review start runs test_verify"    should_run_stage "test_verify" "review"

# start_at=test maps to test_verify
assert_false "8.14 should_run_stage: test start skips scout"           should_run_stage "scout"      "test"
assert_false "8.15 should_run_stage: test start skips coder"           should_run_stage "coder"      "test"
assert_false "8.16 should_run_stage: test start skips security"        should_run_stage "security"   "test"
assert_false "8.17 should_run_stage: test start skips review"          should_run_stage "review"     "test"
assert_true  "8.18 should_run_stage: test start runs test_verify"      should_run_stage "test_verify" "test"

# start_at=tester (alias) same as test
assert_true  "8.19 should_run_stage: tester start runs test_verify"    should_run_stage "test_verify" "tester"

# start_at=intake: everything runs
assert_true  "8.20 should_run_stage: intake start runs scout"          should_run_stage "scout"      "intake"
assert_true  "8.21 should_run_stage: intake start runs coder"          should_run_stage "coder"      "intake"

# start_at=security
assert_false "8.22 should_run_stage: security start skips scout"       should_run_stage "scout"      "security"
assert_false "8.23 should_run_stage: security start skips coder"       should_run_stage "coder"      "security"
assert_true  "8.24 should_run_stage: security start runs security"     should_run_stage "security"   "security"

# =============================================================================
# Phase 9: should_run_stage — test_first order
# =============================================================================

PIPELINE_ORDER="test_first"

# start_at=coder: scout (pos 1) and test_write (pos 2) skipped; coder (pos 3) onwards runs
assert_false "9.1 should_run_stage: test_first coder start skips scout"      should_run_stage "scout"      "coder"
assert_false "9.2 should_run_stage: test_first coder start skips test_write" should_run_stage "test_write" "coder"
assert_true  "9.3 should_run_stage: test_first coder start runs coder"       should_run_stage "coder"      "coder"
assert_true  "9.4 should_run_stage: test_first coder start runs test_verify" should_run_stage "test_verify" "coder"

# start_at=test maps to test_verify (pos 6 in test_first), all prior stages skipped
assert_false "9.5 should_run_stage: test_first test start skips test_write"  should_run_stage "test_write" "test"
assert_false "9.6 should_run_stage: test_first test start skips coder"       should_run_stage "coder"      "test"
assert_false "9.7 should_run_stage: test_first test start skips review"      should_run_stage "review"     "test"
assert_true  "9.8 should_run_stage: test_first test start runs test_verify"  should_run_stage "test_verify" "test"

# default start_at: all stages run in test_first order
assert_true  "9.9  should_run_stage: test_first default runs test_write"     should_run_stage "test_write" ""
assert_true  "9.10 should_run_stage: test_first default runs test_verify"    should_run_stage "test_verify" ""

# =============================================================================
# Phase 10: get_tester_mode
# =============================================================================

assert_eq "10.1 get_tester_mode: test_write → write_failing"     "write_failing"  "$(get_tester_mode test_write)"
assert_eq "10.2 get_tester_mode: test_verify → verify_passing"   "verify_passing" "$(get_tester_mode test_verify)"
assert_eq "10.3 get_tester_mode: unknown → verify_passing"       "verify_passing" "$(get_tester_mode unknown_stage)"

# =============================================================================
# Phase 11: is_test_first_order
# =============================================================================

PIPELINE_ORDER="test_first"
assert_true  "11.1 is_test_first_order: returns 0 for test_first"  is_test_first_order

PIPELINE_ORDER="standard"
assert_false "11.2 is_test_first_order: returns 1 for standard"    is_test_first_order

unset PIPELINE_ORDER
assert_false "11.3 is_test_first_order: returns 1 when unset"      is_test_first_order

# =============================================================================
# Done
# =============================================================================

if [ "$FAIL" -ne 0 ]; then
    echo "FAILED: one or more tests failed"
    exit 1
fi
echo "All tests passed!"
exit 0
