#!/usr/bin/env bash
# =============================================================================
# test_coder_placeholder_detection.sh — Integration tests for placeholder detection
#
# Tests that when CODER_SUMMARY.md contains unfilled placeholders and substantive
# work was done, the detection in stages/coder.sh triggers _reconstruct_coder_summary.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Initialize test directory as a git repository
cd "$TMPDIR_TEST"
mkdir -p "${TEKHTON_DIR:-.tekhton}"
CODER_SUMMARY_FILE="${TEKHTON_DIR}/CODER_SUMMARY.md"
export CODER_SUMMARY_FILE
git init -q
git config user.email "test@example.com"
git config user.name "Test User"

# Source required libraries
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/agent_helpers.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/stages/coder.sh"

# Initialize with a base commit
echo "# Test project" > README.md
git add README.md
git commit -q -m "Initial commit"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# =============================================================================
# Test 1: Placeholder detection triggers reconstruction with substantive work
# =============================================================================
echo "=== Test 1: Placeholder + substantive work triggers reconstruction ==="

# Create a large placeholder summary (20+ lines to trigger is_substantive_work)
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
(fill in as you go)
## Root Cause (bugs only)
(fill in after diagnosis)
## Files Modified
(fill in as you go)
## Remaining Work
(fill in as you go)
## Notes
(fill in as you go)
## Additional Context
(fill in as you go)
## Testing Status
(fill in as you go)
## Performance Considerations
(fill in as you go)
## Breaking Changes
None
## Migration Path
(fill in as you go)
## Next Steps
(fill in as you go)
EOF

# Add actual code file to create substantive work (don't commit yet)
mkdir -p src
echo "function test() { return 42; }" > src/test.ts

# Simulate the detection logic from stages/coder.sh:768-773
if [[ -f "${CODER_SUMMARY_FILE}" ]] && grep -q 'fill in as you go\|update as you go' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    if is_substantive_work; then
        _reconstruct_coder_summary
    fi
fi

# Verify reconstruction happened: file should no longer contain placeholder text
if ! grep -q 'fill in as you go\|update as you go' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    pass "1.1: Placeholder text removed after reconstruction"
else
    fail "1.1: Placeholder text should be removed after reconstruction"
fi

# Verify reconstructed summary contains "reconstructed by the pipeline"
if grep -q 'reconstructed by the pipeline' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    pass "1.2: Reconstructed summary contains reconstruction marker"
else
    fail "1.2: Reconstructed summary should contain reconstruction marker"
fi

# Verify actual file changes are listed
if grep -q 'src/test.ts' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    pass "1.3: Modified files are listed in reconstructed summary"
else
    fail "1.3: Modified files should be listed in reconstructed summary"
fi

rm -f "${CODER_SUMMARY_FILE}" src/test.ts

# =============================================================================
# Test 2: Placeholder with "update as you go" variant also triggers reconstruction
# =============================================================================
echo "=== Test 2: 'update as you go' variant triggers reconstruction ==="

# Create a larger placeholder (20+ lines to trigger is_substantive_work)
cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
(update as you go)
## Root Cause (bugs only)
(update after diagnosis)
## Files Modified
(update as you go)
## Remaining Work
(update as you go)
## Notes
(update as you go)
## Additional Context
(update as you go)
## Testing Status
(update as you go)
## Performance Considerations
(update as you go)
## Breaking Changes
None
## Migration Path
(update as you go)
## Next Steps
(update as you go)
EOF

# Add actual work (don't commit yet)
echo "const x = 1;" > index.ts

# Trigger detection
if [[ -f "${CODER_SUMMARY_FILE}" ]] && grep -q 'fill in as you go\|update as you go' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    if is_substantive_work; then
        _reconstruct_coder_summary
    fi
fi

if ! grep -q 'fill in as you go\|update as you go' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    pass "2.1: 'update as you go' variant triggers reconstruction"
else
    fail "2.1: 'update as you go' variant should trigger reconstruction"
fi

rm -f "${CODER_SUMMARY_FILE}" index.ts

# =============================================================================
# Test 3: Properly filled summary is NOT reconstructed
# =============================================================================
echo "=== Test 3: Properly filled summary is not reconstructed ==="

cat > "${CODER_SUMMARY_FILE}" << 'EOF'
## Status: IN PROGRESS
## What Was Implemented
- Added input validation
- Fixed timezone handling
## Files Modified
- src/auth.ts
- src/utils.ts
EOF

# Add some work
echo "test" > another.ts
git add another.ts
git commit -q -m "Add another"

# Trigger detection logic
original_content=$(cat "${CODER_SUMMARY_FILE}")
if [[ -f "${CODER_SUMMARY_FILE}" ]] && grep -q 'fill in as you go\|update as you go' "${CODER_SUMMARY_FILE}" 2>/dev/null; then
    if is_substantive_work; then
        _reconstruct_coder_summary
    fi
fi
new_content=$(cat "${CODER_SUMMARY_FILE}")

if [[ "$original_content" == "$new_content" ]]; then
    pass "3.1: Properly filled summary is not modified"
else
    fail "3.1: Properly filled summary should not be modified"
fi

rm -f "${CODER_SUMMARY_FILE}" another.ts

# =============================================================================
# Summary
# =============================================================================
echo
echo "══════════════════════════════════════"
echo "Passed: $PASS  Failed: $FAIL"
echo "══════════════════════════════════════"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
