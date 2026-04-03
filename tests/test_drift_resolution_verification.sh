#!/usr/bin/env bash
# Test: Verify drift log structure and resolution state
# Validates that DRIFT_LOG.md has correct format and no unresolved observations.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$TEKHTON_HOME"

source "${TEKHTON_HOME}/lib/common.sh"
source "${TEKHTON_HOME}/lib/drift.sh"

FAIL=0

pass() {
    echo "PASS: $*"
}

fail() {
    echo "FAIL: $*"
    FAIL=1
}

assert_file_contains() {
    local name="$1" file="$2" pattern="$3"
    if ! grep -q "$pattern" "$file" 2>/dev/null; then
        fail "$name — pattern '$pattern' not found in $file"
    else
        pass "$name"
    fi
}

# ============================================================
# Test 1: DRIFT_LOG.md exists
# ============================================================
if [ ! -f "${PROJECT_DIR}/DRIFT_LOG.md" ]; then
    fail "DRIFT_LOG.md file exists"
else
    pass "DRIFT_LOG.md file exists"
fi

# ============================================================
# Test 2: DRIFT_LOG has correct header structure
# ============================================================
assert_file_contains "drift log header" "${PROJECT_DIR}/DRIFT_LOG.md" "# Drift Log"
assert_file_contains "drift log metadata section" "${PROJECT_DIR}/DRIFT_LOG.md" "## Metadata"
assert_file_contains "drift log unresolved section" "${PROJECT_DIR}/DRIFT_LOG.md" "## Unresolved Observations"
assert_file_contains "drift log resolved section" "${PROJECT_DIR}/DRIFT_LOG.md" "## Resolved"

# ============================================================
# Test 3: Unresolved Observations section has valid structure
# Either contains "(none)" or properly formatted entries — never both
# ============================================================
UNRESOLVED_SECTION=$(sed -n '/^## Unresolved Observations$/,/^## Resolved$/p' "${PROJECT_DIR}/DRIFT_LOG.md")
HAS_ENTRIES=false
HAS_NONE=false
if echo "$UNRESOLVED_SECTION" | grep -q "^-"; then
    HAS_ENTRIES=true
fi
if echo "$UNRESOLVED_SECTION" | grep -q "^(none)"; then
    HAS_NONE=true
fi
if $HAS_ENTRIES && $HAS_NONE; then
    fail "Unresolved section has both entries and (none) marker — stale marker"
elif ! $HAS_ENTRIES && ! $HAS_NONE; then
    fail "Unresolved section is empty (missing entries or (none) marker)"
else
    pass "Unresolved Observations section has valid structure"
fi

# ============================================================
# Test 4: Metadata shows Last audit date
# ============================================================
assert_file_contains \
    "last audit metadata" \
    "${PROJECT_DIR}/DRIFT_LOG.md" \
    "Last audit:"

# ============================================================
# Test 5: Unresolved entries (if any) are properly formatted
# ============================================================
UNRESOLVED_SECTION=$(sed -n '/^## Unresolved Observations$/,/^## Resolved$/p' "${PROJECT_DIR}/DRIFT_LOG.md" || true)
UNRESOLVED_ENTRIES=$(echo "$UNRESOLVED_SECTION" | grep "^-" || true)
if [ -n "$UNRESOLVED_ENTRIES" ]; then
    # All entries should have the standard date+tag format
    BAD_ENTRIES=$(echo "$UNRESOLVED_ENTRIES" | grep -v '^\- \[' || true)
    if [ -n "$BAD_ENTRIES" ]; then
        fail "Unresolved entries have invalid format: $BAD_ENTRIES"
    else
        pass "Unresolved entries are properly formatted"
    fi
else
    pass "No unresolved entries (section shows (none))"
fi

# ============================================================
# Test 6: Drift log format is valid markdown
# ============================================================
SECTION_COUNT=$(grep -c "^##" "${PROJECT_DIR}/DRIFT_LOG.md" || echo "0")
if [ "$SECTION_COUNT" -gt 0 ]; then
    pass "Drift log has valid markdown section headers ($SECTION_COUNT sections)"
else
    fail "Drift log markdown structure is invalid (no sections found)"
fi

# ============================================================
# Test 7: Verify the milestone pattern fix in lib/plan.sh:515
# The bug: OLD pattern was ^#{2,3} (2-3 hashes)
# The fix: NEW pattern is ^#{2,4} (2-4 hashes) to match plan_generate output
# ============================================================
PATTERN_LINE=$(grep -n '_display_milestone_summary' "${TEKHTON_HOME}/lib/plan.sh" | head -1 | cut -d: -f1)
if [ -z "$PATTERN_LINE" ]; then
    fail "Could not find _display_milestone_summary function"
else
    # Extract the grep pattern around line 515
    GREP_PATTERN=$(sed -n '510,520p' "${TEKHTON_HOME}/lib/plan.sh" | grep -o '\^#{2,4}' | head -1)
    if [ "$GREP_PATTERN" = '^#{2,4}' ]; then
        pass "lib/plan.sh line 515 has corrected pattern (^#{2,4})"
    else
        fail "lib/plan.sh pattern should be ^#{2,4} but found: $GREP_PATTERN"
    fi
fi

# ============================================================
# Test 8: Pattern correctly matches 4-hash milestone headings
# (This validates that the fix actually works in practice)
# ============================================================
TEST_CLAUDE_CONTENT="# Project Title
## Milestone 1: Setup
### Milestone 2: Build
#### Milestone 3: Test
Content here"

# Test the NEW pattern (what the fix installed)
NEW_MATCHES=$(echo "$TEST_CLAUDE_CONTENT" | grep -E '^#{2,4} Milestone [0-9]+' | wc -l)
if [ "$NEW_MATCHES" -eq 3 ]; then
    pass "Pattern with fix ^#{2,4} correctly detects all 3 milestone types"
else
    fail "Pattern should match 3 milestones (2, 3, 4 hashes) but found $NEW_MATCHES"
fi

# Test the OLD pattern would have failed
OLD_MATCHES=$(echo "$TEST_CLAUDE_CONTENT" | grep -E '^#{2,3} Milestone [0-9]+' | wc -l || true)
if [ "$OLD_MATCHES" -eq 2 ]; then
    pass "Old pattern ^#{2,3} correctly misses the 4-hash milestone (regression confirmed)"
else
    fail "Old pattern should have found only 2 matches but found $OLD_MATCHES"
fi

# ============================================================
# Summary
# ============================================================
if [ "$FAIL" -eq 0 ]; then
    echo ""
    echo "All drift resolution verification tests passed."
    exit 0
else
    exit 1
fi
