#!/usr/bin/env bash
# =============================================================================
# test_config.sh — Unit tests for lib/config.sh functions
#
# Tests:
#   1. _clamp_config_float: clamps value within range [min, max]
#   2. _clamp_config_float: clamps value below minimum to minimum
#   3. _clamp_config_float: clamps value above maximum to maximum
#   4. _clamp_config_float: does not modify value already at minimum
#   5. _clamp_config_float: does not modify value already at maximum
#   6. _clamp_config_float: silently ignores negative values (regex reject)
#   7. _clamp_config_float: silently ignores leading-dot floats (regex reject)
#   8. _clamp_config_float: silently ignores non-numeric values
#   9. _clamp_config_float: handles leading-dot edge case like .5 (rejected)
#  10. _clamp_config_float: handles integer values correctly
#  11. _clamp_config_float: handles decimal values correctly
#  12. _clamp_config_float: preserves value when invalid input cannot be parsed
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Source libraries needed for _clamp_config_float
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/config.sh"

FAIL=0
TEST_NUM=0

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    TEST_NUM=$((TEST_NUM + 1))
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: Test $TEST_NUM ($name) — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: Test $TEST_NUM ($name)"
    fi
}

assert_variable_eq() {
    local name="$1" var_name="$2" expected="$3"
    TEST_NUM=$((TEST_NUM + 1))
    local actual="${!var_name:-}"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: Test $TEST_NUM ($name) — expected '$expected', got '$actual'"
        FAIL=1
    else
        echo "PASS: Test $TEST_NUM ($name)"
    fi
}

# Test 1: Clamps value within range [min, max]
TEST_VAL=1.5
_clamp_config_float TEST_VAL 1.0 2.0
assert_variable_eq "clamps value within range" "TEST_VAL" "1.5"

# Test 2: Clamps value below minimum to minimum
TEST_VAL=0.5
_clamp_config_float TEST_VAL 1.0 2.0
assert_variable_eq "clamps below minimum" "TEST_VAL" "1.0"

# Test 3: Clamps value above maximum to maximum
TEST_VAL=3.5
_clamp_config_float TEST_VAL 1.0 2.0
assert_variable_eq "clamps above maximum" "TEST_VAL" "2.0"

# Test 4: Does not modify value at minimum
TEST_VAL=1.0
_clamp_config_float TEST_VAL 1.0 2.0
assert_variable_eq "at minimum unchanged" "TEST_VAL" "1.0"

# Test 5: Does not modify value at maximum
TEST_VAL=2.0
_clamp_config_float TEST_VAL 1.0 2.0
assert_variable_eq "at maximum unchanged" "TEST_VAL" "2.0"

# Test 6: Silently ignores negative values (regex doesn't match)
TEST_VAL=-1.5
_clamp_config_float TEST_VAL 0.0 3.0
# Should remain unchanged because negative doesn't match regex
assert_variable_eq "silently ignores negative values" "TEST_VAL" "-1.5"

# Test 7: Silently ignores leading-dot floats (regex doesn't match)
TEST_VAL=.5
_clamp_config_float TEST_VAL 0.0 1.0
# Should remain unchanged because .5 doesn't match regex
assert_variable_eq "silently ignores leading-dot floats" "TEST_VAL" ".5"

# Test 8: Silently ignores non-numeric values
TEST_VAL="abc"
_clamp_config_float TEST_VAL 0.0 1.0
# Should remain unchanged
assert_variable_eq "silently ignores non-numeric values" "TEST_VAL" "abc"

# Test 9: Boundary test - at exactly minimum (integer gets formatted as float)
TEST_VAL=1
_clamp_config_float TEST_VAL 1 3
assert_variable_eq "integer at minimum" "TEST_VAL" "1.0"

# Test 10: Boundary test - at exactly maximum (integer gets formatted as float)
TEST_VAL=3
_clamp_config_float TEST_VAL 1 3
assert_variable_eq "integer at maximum" "TEST_VAL" "3.0"

# Test 11: Handles integer clamping below min
TEST_VAL=0
_clamp_config_float TEST_VAL 1 3
assert_variable_eq "integer below minimum" "TEST_VAL" "1.0"

# Test 12: Handles integer clamping above max
TEST_VAL=5
_clamp_config_float TEST_VAL 1 3
assert_variable_eq "integer above maximum" "TEST_VAL" "3.0"

exit $FAIL
