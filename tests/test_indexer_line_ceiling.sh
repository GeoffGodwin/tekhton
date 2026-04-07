#!/usr/bin/env bash
# =============================================================================
# test_indexer_line_ceiling.sh — Verify lib/indexer.sh is under 300-line
# ceiling after comment trim
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

INDEXER_FILE="${TEKHTON_HOME}/lib/indexer.sh"

echo "=== test_indexer_line_ceiling.sh ==="

# Test 1: Verify line count is under 300
line_count=$(wc -l < "$INDEXER_FILE")
if [[ $line_count -lt 300 ]]; then
    pass "lib/indexer.sh is under 300-line ceiling (${line_count} lines)"
else
    fail "lib/indexer.sh exceeds 300-line ceiling (${line_count} lines)"
fi

# Test 2: Verify the last comment block is a pointer (not a full block)
last_lines=$(tail -5 "$INDEXER_FILE")
if echo "$last_lines" | grep -q "Intra-run cache functions"; then
    pass "Last comment block is a pointer to external cache functions"
else
    fail "Last comment block structure unexpected"
fi

# Test 3: Verify file ends with comment about cache functions (M61)
if tail -3 "$INDEXER_FILE" | grep -q "Intra-run cache"; then
    pass "File ends with proper cache functions reference"
else
    fail "File ending reference missing"
fi

# Test 4: Verify indexer_cache.sh reference exists (M61)
if grep -q "indexer_cache.sh" "$INDEXER_FILE"; then
    pass "Reference to lib/indexer_cache.sh (M61) present"
else
    fail "Reference to lib/indexer_cache.sh missing"
fi

echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[[ $FAIL -eq 0 ]]
