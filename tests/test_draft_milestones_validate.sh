#!/usr/bin/env bash
# =============================================================================
# test_draft_milestones_validate.sh — Tests draft_milestones_validate_output()
#
# Tests:
#   1. Well-formed milestone file → passes
#   2. Missing Acceptance Criteria section → fails with message
#   3. Missing milestone-meta block → fails
#   4. Missing H1 heading → fails
#   5. Acceptance Criteria with fewer than 5 items → fails
#   6. Non-existent file → fails
#   7. Missing multiple sections → reports all errors
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# Minimal stubs
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source just the validation function
export PROJECT_DIR="$TMPDIR"
export MILESTONE_DIR=".claude/milestones"
export MILESTONE_MANIFEST="MANIFEST.cfg"
# shellcheck source=lib/draft_milestones_write.sh
source "${TEKHTON_HOME}/lib/draft_milestones_write.sh"

# --- Helper: write a well-formed milestone file ---
_write_good_milestone() {
    local file="$1"
    cat > "$file" << 'EOF'
# Milestone 99: Test Milestone Title
<!-- milestone-meta
id: "99"
status: "pending"
-->

## Overview

This is a test milestone for validation testing.

## Design Decisions

### 1. Decision One

We decided to do X because Y.

## Scope Summary

| Area | Count | Notes |
|------|-------|-------|
| Tests | 1 | Validation test |

## Implementation Plan

### Step 1 — Do the thing

Write the code.

## Files Touched

### Added
- tests/test_example.sh

### Modified
- lib/example.sh

## Negative Space

No exclusions for this test milestone.

## Acceptance Criteria

- [ ] First criterion
- [ ] Second criterion
- [ ] Third criterion
- [ ] Fourth criterion
- [ ] Fifth criterion
EOF
}

# =============================================================================
# Test 1: Well-formed milestone file → passes
# =============================================================================
_write_good_milestone "$TMPDIR/good.md"

if draft_milestones_validate_output "$TMPDIR/good.md" 2>/dev/null; then
    pass "Well-formed milestone file passes validation"
else
    fail "Well-formed milestone file should pass validation"
fi

# =============================================================================
# Test 2: Missing Acceptance Criteria section → fails
# =============================================================================
sed '/^## Acceptance Criteria/,$ d' "$TMPDIR/good.md" > "$TMPDIR/no_ac.md"

if draft_milestones_validate_output "$TMPDIR/no_ac.md" 2>/dev/null; then
    fail "Missing Acceptance Criteria should fail"
else
    pass "Missing Acceptance Criteria → fails"
fi

# Check the error message mentions Acceptance Criteria
err_output=$(draft_milestones_validate_output "$TMPDIR/no_ac.md" 2>&1 || true)
if echo "$err_output" | grep -q "Acceptance Criteria"; then
    pass "Error message mentions 'Acceptance Criteria'"
else
    fail "Error message should mention 'Acceptance Criteria', got: ${err_output}"
fi

# =============================================================================
# Test 3: Missing milestone-meta block → fails
# =============================================================================
grep -v 'milestone-meta\|^id:\|^status:\|^-->' "$TMPDIR/good.md" > "$TMPDIR/no_meta.md"

if draft_milestones_validate_output "$TMPDIR/no_meta.md" 2>/dev/null; then
    fail "Missing milestone-meta should fail"
else
    pass "Missing milestone-meta → fails"
fi

# =============================================================================
# Test 4: Missing H1 heading → fails
# =============================================================================
sed '1 s/^# Milestone/## Milestone/' "$TMPDIR/good.md" > "$TMPDIR/no_h1.md"

if draft_milestones_validate_output "$TMPDIR/no_h1.md" 2>/dev/null; then
    fail "Missing H1 heading should fail"
else
    pass "Missing H1 heading → fails"
fi

# =============================================================================
# Test 5: Acceptance Criteria with fewer than 5 items → fails
# =============================================================================
cat > "$TMPDIR/few_ac.md" << 'EOF'
# Milestone 99: Test
<!-- milestone-meta
id: "99"
status: "pending"
-->

## Overview

Test.

## Design Decisions

### 1. One

Decision.

## Scope Summary

| Area | Count |
|------|-------|
| Test | 1 |

## Implementation Plan

### Step 1

Do it.

## Files Touched

### Added
- file.sh

## Negative Space

None.

## Acceptance Criteria

- [ ] Only one criterion
- [ ] And a second
EOF

if draft_milestones_validate_output "$TMPDIR/few_ac.md" 2>/dev/null; then
    fail "Fewer than 5 AC items should fail"
else
    pass "Fewer than 5 AC items → fails"
fi

# =============================================================================
# Test 6: Non-existent file → fails
# =============================================================================
if draft_milestones_validate_output "$TMPDIR/nonexistent.md" 2>/dev/null; then
    fail "Non-existent file should fail"
else
    pass "Non-existent file → fails"
fi

# =============================================================================
# Test 7: Missing multiple sections → reports all errors
# =============================================================================
cat > "$TMPDIR/minimal.md" << 'EOF'
# Milestone 99: Test
<!-- milestone-meta
id: "99"
status: "pending"
-->

## Overview

Test.
EOF

err_output=$(draft_milestones_validate_output "$TMPDIR/minimal.md" 2>&1 || true)
err_count=$(echo "$err_output" | grep -c "ERROR:" || true)
if [[ "$err_count" -ge 5 ]]; then
    pass "Missing multiple sections → reports ${err_count} errors"
else
    fail "Expected at least 5 errors for minimal file, got ${err_count}"
fi

# =============================================================================
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} test(s)"
    exit 1
fi
echo "All draft_milestones_validate tests passed."
