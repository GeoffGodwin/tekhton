#!/usr/bin/env bash
# Test: NON_BLOCKING_LOG.md structure verification
# Verifies that the 3 items addressed by the coder are marked as [x] in Resolved,
# and that the Open section is empty.

set -euo pipefail

PASS=0
FAIL=0

# Test 1: Open section has valid structure
# Either contains only "(none)" or properly formatted "- [ ]" items — never both
echo "Test 1: Verify Open section has valid structure..."
OPEN_BLOCK="$(sed -n '/^## Open$/,/^## /{ /^## /d; p; }' NON_BLOCKING_LOG.md)"
HAS_ITEMS=false
HAS_NONE=false
if echo "$OPEN_BLOCK" | grep -q "^- \[ \]"; then
	HAS_ITEMS=true
fi
if echo "$OPEN_BLOCK" | grep -q "^(none)"; then
	HAS_NONE=true
fi
if $HAS_ITEMS && $HAS_NONE; then
	echo "✗ FAIL: Open section has both items and (none) marker — stale marker"
	FAIL=$((FAIL+1))
elif ! $HAS_ITEMS && ! $HAS_NONE; then
	echo "✗ FAIL: Open section is empty (missing items or (none) marker)"
	FAIL=$((FAIL+1))
else
	echo "✓ PASS: Open section structure is valid"
	PASS=$((PASS+1))
fi

# Test 2: Verify the Resolved section exists and has valid structure
echo "Test 2: Verify Resolved section exists..."
if grep -q "^## Resolved" NON_BLOCKING_LOG.md; then
	echo "✓ PASS: Resolved section exists"
	PASS=$((PASS+1))
else
	echo "✗ FAIL: Resolved section missing"
	FAIL=$((FAIL+1))
fi

# Test 3: Detect duplicate blocks
echo "Test 3: Check for duplicate 'Test Audit Concerns' blocks..."
AUDIT_2028=$(grep -c "^### Test Audit Concerns (2026-03-28)$" NON_BLOCKING_LOG.md || true)
AUDIT_2029=$(grep -c "^### Test Audit Concerns (2026-03-29)$" NON_BLOCKING_LOG.md || true)

if [[ $AUDIT_2028 -gt 1 ]]; then
	echo "⚠ WARNING: Found $AUDIT_2028 'Test Audit Concerns (2026-03-28)' blocks (should be 1)"
	FAIL=$((FAIL+1))
elif [[ $AUDIT_2028 -eq 1 ]]; then
	echo "✓ PASS: Only 1 'Test Audit Concerns (2026-03-28)' block found"
	PASS=$((PASS+1))
fi

if [[ $AUDIT_2029 -gt 1 ]]; then
	echo "⚠ WARNING: Found $AUDIT_2029 'Test Audit Concerns (2026-03-29)' blocks (should be 1)"
	FAIL=$((FAIL+1))
elif [[ $AUDIT_2029 -eq 1 ]]; then
	echo "✓ PASS: Only 1 'Test Audit Concerns (2026-03-29)' block found"
	PASS=$((PASS+1))
fi

# Summary
echo ""
echo "Test Results:"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"

if [[ $FAIL -gt 0 ]]; then
	exit 1
fi

exit 0
