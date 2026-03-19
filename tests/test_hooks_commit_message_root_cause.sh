#!/usr/bin/env bash
# =============================================================================
# test_hooks_commit_message_root_cause.sh
#
# Tests that generate_commit_message() extracts the root cause from
# CODER_SUMMARY.md and includes it in the commit body when:
#   - the task contains "fix" or "bug" (case-insensitive), AND
#   - the root cause in CODER_SUMMARY.md is non-empty and not N/A/none
#
# Verifies:
#   1. task "fix: ..." + real root cause → "Root cause:" in commit message
#   2. task "bug in ..." + real root cause → "Root cause:" in commit message
#   3. task "feat: ..." (no fix/bug) → "Root cause:" NOT in commit message
#   4. root cause = "N/A" → NOT included
#   5. root cause = "none" → NOT included
#   6. root cause = "(fill in)" → NOT included (matches "^(fill" pattern)
#   7. no CODER_SUMMARY.md → no "Root cause:" section
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Set up a git repo in TMPDIR (generate_commit_message calls git diff --stat)
cd "$TMPDIR"
git init -q
git config user.email "test@tekhton.test"
git config user.name "Tekhton Test"

# Source dependencies (same pattern as test_hooks_diff_stat_portability.sh)
source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"
source "${TEKHTON_HOME}/lib/drift_cleanup.sh"

# Stub milestone functions
get_milestone_commit_prefix() { echo ""; }
get_milestone_commit_body() { echo ""; }

source "${TEKHTON_HOME}/lib/hooks.sh"

FAIL=0

assert_contains() {
    local name="$1" pattern="$2" actual="$3"
    if ! echo "$actual" | grep -qF "$pattern"; then
        echo "FAIL: $name — pattern '$pattern' not found in output"
        echo "  output: $(echo "$actual" | head -20)"
        FAIL=1
    fi
}

assert_not_contains() {
    local name="$1" pattern="$2" actual="$3"
    if echo "$actual" | grep -qF "$pattern"; then
        echo "FAIL: $name — unexpected pattern '$pattern' found in output"
        echo "  output: $(echo "$actual" | head -20)"
        FAIL=1
    fi
}

write_coder_summary() {
    local root_cause="$1"
    cat > CODER_SUMMARY.md << EOF
## What Was Implemented
- Fixed the null pointer dereference in the login handler

## Root Cause
${root_cause}

## Files Modified
- lib/auth.sh
EOF
}

# =============================================================================
# Test 1: task contains "fix" + real root cause → "Root cause:" included
# =============================================================================

write_coder_summary "Null pointer dereference when session token is missing"
MSG=$(generate_commit_message "fix: null pointer in login handler")

assert_contains "fix-task: Root cause section present" "Root cause:" "$MSG"
assert_contains "fix-task: root cause text included" "Null pointer dereference" "$MSG"

echo "✓ Test 1: fix task + real root cause → Root cause section included"

# =============================================================================
# Test 2: task contains "bug" + real root cause → "Root cause:" included
# =============================================================================

write_coder_summary "Race condition in concurrent session writes"
MSG=$(generate_commit_message "bug in session manager causes data corruption")

assert_contains "bug-task: Root cause section present" "Root cause:" "$MSG"
assert_contains "bug-task: root cause text included" "Race condition" "$MSG"

echo "✓ Test 2: bug task + real root cause → Root cause section included"

# =============================================================================
# Test 3: task does NOT contain "fix" or "bug" → "Root cause:" NOT included
# =============================================================================

write_coder_summary "This would be a root cause if included"
MSG=$(generate_commit_message "feat: add user profile page")

assert_not_contains "feat-task: Root cause NOT present" "Root cause:" "$MSG"

echo "✓ Test 3: feat task → Root cause section not included"

# =============================================================================
# Test 4: root cause = "N/A" → NOT included
# =============================================================================

write_coder_summary "N/A"
MSG=$(generate_commit_message "fix: improve error handling")

assert_not_contains "na-root-cause: Root cause NOT present" "Root cause:" "$MSG"

echo "✓ Test 4: root cause = 'N/A' → not included"

# =============================================================================
# Test 5: root cause = "none" → NOT included
# =============================================================================

write_coder_summary "none"
MSG=$(generate_commit_message "fix: update dependencies")

assert_not_contains "none-root-cause: Root cause NOT present" "Root cause:" "$MSG"

echo "✓ Test 5: root cause = 'none' → not included"

# =============================================================================
# Test 6: root cause = "(fill in)" → NOT included (matches "^(fill" pattern)
# =============================================================================

write_coder_summary "(fill in root cause here)"
MSG=$(generate_commit_message "fix: patch security vulnerability")

assert_not_contains "fill-root-cause: Root cause NOT present" "Root cause:" "$MSG"

echo "✓ Test 6: root cause = '(fill in...)' → not included"

# =============================================================================
# Test 7: no CODER_SUMMARY.md → no "Root cause:" section
# =============================================================================

rm -f CODER_SUMMARY.md
MSG=$(generate_commit_message "fix: missing summary file")

assert_not_contains "no-summary: Root cause NOT present" "Root cause:" "$MSG"

echo "✓ Test 7: no CODER_SUMMARY.md → no Root cause section"

# =============================================================================
# Test 8: task "Fix: ..." (capital F) + real root cause → "Root cause:" included
#         (verifies -qi case-insensitive matching)
# =============================================================================

write_coder_summary "Off-by-one error in pagination calculation"
MSG=$(generate_commit_message "Fix: pagination shows wrong page count")

assert_contains "fix-capital: Root cause section present" "Root cause:" "$MSG"
assert_contains "fix-capital: root cause text included" "Off-by-one" "$MSG"

echo "✓ Test 8: Fix (capital) task + real root cause → Root cause section included"

# =============================================================================
# Summary
# =============================================================================
if [ "$FAIL" -eq 0 ]; then
    echo "PASS"
else
    exit 1
fi
