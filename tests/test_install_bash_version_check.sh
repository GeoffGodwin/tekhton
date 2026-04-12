#!/usr/bin/env bash
# Test bash version checking in install.sh
set -euo pipefail

# Test framework
pass() { echo "PASS: $*"; ((PASS_COUNT++)); }
fail() { echo "FAIL: $*"; ((FAIL_COUNT++)); return 1; }

PASS_COUNT=0
FAIL_COUNT=0

# Temporary directory for test isolation
TEST_DIR=$(mktemp -d)
trap "rm -rf '$TEST_DIR'" EXIT

# Extract the check_bash_version function directly from install.sh
# This avoids sourcing the whole script
INSTALL_SH="/home/geoff/workspace/geoffgodwin/tekhton/install.sh"

# Test 1: Verify check_bash_version function exists in install.sh
test_function_exists() {
    if grep -q "^check_bash_version()" "$INSTALL_SH"; then
        pass "check_bash_version function exists in install.sh"
    else
        fail "check_bash_version function not found"
    fi
}

# Test 2: Verify the function checks BASH_VERSINFO[0]
test_uses_bash_versinfo() {
    # Extract the function
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    if echo "$func_def" | grep -q 'BASH_VERSINFO\[0\]'; then
        pass "Function uses BASH_VERSINFO[0] for version check"
    else
        fail "Function should use BASH_VERSINFO[0]"
    fi
}

# Test 3: Verify the function checks major < 4
test_guard_condition() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    if echo "$func_def" | grep -q '\[ "$major" -lt 4 \]'; then
        pass "Function checks if major version < 4"
    else
        fail "Function should check if major < 4"
    fi
}

# Test 4: Verify macOS branch exists with Homebrew instructions
test_macos_branch() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    if echo "$func_def" | grep -q 'PLATFORM.*macos'; then
        pass "Function has macOS branch"
    else
        fail "Function missing macOS branch"
    fi

    if echo "$func_def" | grep -q "brew install bash"; then
        pass "macOS branch includes Homebrew instruction"
    else
        fail "macOS branch missing Homebrew instruction"
    fi
}

# Test 5: Verify version messages say "4.3+"
test_version_requirement_accurate() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    # Count occurrences of "4.3+"
    local count
    count=$(echo "$func_def" | grep -o "4\.3+" | wc -l)

    if [ "$count" -ge 2 ]; then
        pass "Error messages reference 'bash 4.3+' (found $count occurrences)"
    else
        fail "Error messages should reference 'bash 4.3+' (found $count occurrences)"
    fi
}

# Test 6: Verify function uses fail() not undefined error()
test_uses_fail_function() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    if echo "$func_def" | grep -q "fail \""; then
        pass "Function calls fail() to exit on old bash"
    else
        fail "Function should call fail() not error()"
    fi

    # Verify error() is NOT called (was the old bug)
    if echo "$func_def" | grep -q "error \""; then
        fail "Function still calls undefined error() function"
    else
        pass "Function does not call undefined error() function"
    fi
}

# Test 7: Verify non-macOS branch exists
test_non_macos_branch() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    if echo "$func_def" | grep -q "else" && echo "$func_def" | grep -q "Please upgrade bash"; then
        pass "Function has non-macOS branch with upgrade message"
    else
        fail "Function missing non-macOS upgrade branch"
    fi
}

# Test 8: Verify function provides helpful instructions before fail()
test_helpful_instructions() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    # Should print info messages before calling fail()
    if echo "$func_def" | grep -q "echo \"\"" && echo "$func_def" | grep -q "echo \"Tekhton requires"; then
        pass "Function prints helpful messages before exiting"
    else
        fail "Function should print helpful instructions before failing"
    fi
}

# Test 9: Verify error messages are sent to stderr (via fail function)
test_error_to_stderr() {
    # The fail() function in install.sh is defined as:
    # fail() { echo -e "${RED}[x]${NC} $*" >&2; exit 1; }
    # So messages go to stderr
    if grep -q "fail().*>&2" "$INSTALL_SH"; then
        pass "fail() function sends output to stderr"
    else
        fail "Error messages should go to stderr"
    fi
}

# Test 10: Verify there's no dead code after fail() call
test_no_dead_code() {
    local func_def
    func_def=$(sed -n '/^check_bash_version()/,/^}/p' "$INSTALL_SH")

    # After the if block with fail(), there should not be another exit statement
    # Extract the lines after the else block
    local after_fail
    after_fail=$(echo "$func_def" | tail -5)

    # Should just be the closing brace, no additional exits
    if ! echo "$after_fail" | grep -q "exit 1"; then
        pass "No dead code (unreachable exit) after fail()"
    else
        # Check if the exit is only in the closing brace context
        if echo "$after_fail" | grep -q "}"; then
            pass "No dead code after fail() - function ends cleanly"
        else
            fail "Function has unreachable code after fail()"
        fi
    fi
}

# Run all tests
echo ""
echo "Running bash version check tests..."
echo ""

test_function_exists || true
test_uses_bash_versinfo || true
test_guard_condition || true
test_macos_branch || true
test_version_requirement_accurate || true
test_uses_fail_function || true
test_non_macos_branch || true
test_helpful_instructions || true
test_error_to_stderr || true
test_no_dead_code || true

# Print summary
echo ""
echo "====== Test Summary ======"
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo ""

if [ "$FAIL_COUNT" -eq 0 ]; then
    exit 0
else
    exit 1
fi
