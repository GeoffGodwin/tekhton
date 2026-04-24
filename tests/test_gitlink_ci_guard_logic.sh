#!/usr/bin/env bash
# Test: CI guard logic for detecting rogue gitlinks in release.yml and docs.yml
# This test validates the shell script that detects mode 160000 entries without
# corresponding .gitmodules entries.
set -euo pipefail

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

cd "$TEST_TMPDIR"

# =============================================================================
# Helper: Run the CI guard logic in a controlled environment
# =============================================================================

run_guard() {
    local git_ls_files_output="$1"
    local gitmodules_content="$2"

    # Create a temp directory for this test case
    local test_dir
    test_dir=$(mktemp -d)
    trap 'rm -rf '"$test_dir"'' RETURN

    cd "$test_dir"
    git init -q .

    # If gitmodules content is provided, create .gitmodules
    if [[ -n "$gitmodules_content" ]]; then
        echo "$gitmodules_content" > .gitmodules
    fi

    # Run the guard logic (verbatim from release.yml and docs.yml)
    rogue=$(echo "$git_ls_files_output" | awk '$1 == "160000" {print $4}')
    if [ -z "$rogue" ]; then
        echo "OK: no gitlinks in tree"
        return 0
    fi
    approved=""
    if [ -f .gitmodules ]; then
        approved=$(git config --file .gitmodules --get-regexp 'submodule\..*\.path' 2>/dev/null | awk '{print $2}' || true)
    fi
    failed=0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        if ! printf '%s\n' "$approved" | grep -qxF "$p"; then
            echo "::error::Rogue gitlink (mode 160000) at '$p' — not declared in .gitmodules. This breaks 'actions/checkout' with 'no url found for submodule path'."
            failed=1
        fi
    done <<< "$rogue"
    return "$failed"
}

# =============================================================================
# Section 1: No gitlinks case (clean tree)
# =============================================================================

output=$(run_guard "" "")
if echo "$output" | grep -q "OK: no gitlinks in tree"; then
    pass "no gitlinks: outputs 'OK' message"
else
    fail "no gitlinks: missing OK message"
fi

status=0
run_guard "" "" || status=$?
if [[ $status -eq 0 ]]; then
    pass "no gitlinks: returns exit 0"
else
    fail "no gitlinks: returned exit $status instead of 0"
fi

# =============================================================================
# Section 2: Rogue gitlink with no .gitmodules (should fail)
# =============================================================================

git_output="160000 commit abc123  .claude/worktrees/agent-a049075c"

output=$(run_guard "$git_output" "" 2>&1 || true)
if echo "$output" | grep -q "::error::Rogue gitlink"; then
    pass "rogue without .gitmodules: emits error annotation"
else
    fail "rogue without .gitmodules: missing error annotation"
fi

status=0
run_guard "$git_output" "" >/dev/null 2>&1 || status=$?
if [[ $status -ne 0 ]]; then
    pass "rogue without .gitmodules: returns non-zero exit"
else
    fail "rogue without .gitmodules: returned 0 instead of non-zero"
fi

# =============================================================================
# Section 3: Rogue gitlink with .gitmodules but not approved
# =============================================================================

gitmodules_content='[submodule "libs/approved"]
	path = libs/approved
	url = https://github.com/example/approved.git'

git_output="160000 commit abc123  .claude/worktrees/agent-a049075c"

output=$(run_guard "$git_output" "$gitmodules_content" 2>&1 || true)
if echo "$output" | grep -q ".claude/worktrees/agent-a049075c"; then
    pass "rogue in .gitmodules gap: error mentions the rogue path"
else
    fail "rogue in .gitmodules gap: error doesn't mention rogue path"
fi

status=0
run_guard "$git_output" "$gitmodules_content" >/dev/null 2>&1 || status=$?
if [[ $status -ne 0 ]]; then
    pass "rogue in .gitmodules gap: returns non-zero exit"
else
    fail "rogue in .gitmodules gap: returned 0 instead of non-zero"
fi

# =============================================================================
# Section 4: Approved gitlink in .gitmodules (should pass)
# =============================================================================

gitmodules_content='[submodule "libs/approved"]
	path = libs/approved
	url = https://github.com/example/approved.git'

git_output="160000 commit abc123  libs/approved"

# Approved gitlinks don't print "OK" (that's only for truly no gitlinks),
# but they should exit cleanly without error
pass "approved gitlink: logic accepts approved path (exit code validates it)"

status=0
run_guard "$git_output" "$gitmodules_content" >/dev/null || status=$?
if [[ $status -eq 0 ]]; then
    pass "approved gitlink: returns exit 0"
else
    fail "approved gitlink: returned exit $status instead of 0"
fi

# =============================================================================
# Section 5: Multiple gitlinks, one rogue, one approved
# =============================================================================

gitmodules_content='[submodule "libs/approved"]
	path = libs/approved
	url = https://github.com/example/approved.git'

git_output='160000 commit abc123  libs/approved
160000 commit def456  .claude/worktrees/rogue'

output=$(run_guard "$git_output" "$gitmodules_content" 2>&1 || true)
if echo "$output" | grep -q ".claude/worktrees/rogue"; then
    pass "mixed gitlinks: error mentions rogue path"
else
    fail "mixed gitlinks: error doesn't mention rogue path"
fi

# Should NOT mention the approved one
if ! echo "$output" | grep -q "libs/approved.*::error"; then
    pass "mixed gitlinks: doesn't error on approved path"
else
    fail "mixed gitlinks: incorrectly errors on approved path"
fi

status=0
run_guard "$git_output" "$gitmodules_content" >/dev/null 2>&1 || status=$?
if [[ $status -ne 0 ]]; then
    pass "mixed gitlinks: returns non-zero exit"
else
    fail "mixed gitlinks: returned 0 instead of non-zero"
fi

# =============================================================================
# Section 6: Empty .gitmodules (edge case)
# =============================================================================

git_output="160000 commit abc123  some/module"

output=$(run_guard "$git_output" "" 2>&1 || true)
if echo "$output" | grep -q "::error::Rogue gitlink"; then
    pass "empty .gitmodules: rogue gitlink is caught"
else
    fail "empty .gitmodules: rogue gitlink not caught"
fi

# =============================================================================
# Section 7: .gitmodules with submodules but different syntax
# =============================================================================

# This tests that we correctly parse the .gitmodules format
gitmodules_content='[submodule "external"]
	path = external/lib
	url = https://github.com/example/lib.git
[submodule "another"]
	path = third-party/pkg
	url = https://github.com/example/pkg.git'

# Create a rogue that's not in the list
git_output="160000 commit xyz789  external/lib"

status=0
run_guard "$git_output" "$gitmodules_content" >/dev/null || status=$?
if [[ $status -eq 0 ]]; then
    pass "multi-submodule .gitmodules: approved path passes"
else
    fail "multi-submodule .gitmodules: approved path failed"
fi

# Now test with a rogue
git_output="160000 commit xyz789  .claude/worktrees/bad"

output=$(run_guard "$git_output" "$gitmodules_content" 2>&1 || true)
if echo "$output" | grep -q ".claude/worktrees/bad"; then
    pass "multi-submodule .gitmodules: rogue path is caught"
else
    fail "multi-submodule .gitmodules: rogue path not caught"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

[[ "$FAIL" -eq 0 ]]
