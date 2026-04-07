#!/usr/bin/env bash
# Test: lib/indexer_helpers.sh — extract_files_from_coder_summary()
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

warn() { echo "[WARN] $*" >&2; }
log()  { echo "[LOG] $*" >&2; }

PROJECT_DIR="/tmp"
export PROJECT_DIR

# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/indexer_helpers.sh"

TMPDIR_EF="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_EF"' EXIT

# =============================================================================
# missing file returns empty with exit 0
# =============================================================================

echo "=== extract_files_from_coder_summary: missing file ==="

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/nonexistent.md")
exit_status=$?

if [ $exit_status -eq 0 ]; then
    pass "missing file returns exit 0"
else
    fail "missing file should return exit 0, got: ${exit_status}"
fi

if [ -z "$result" ]; then
    pass "missing file returns empty output"
else
    fail "missing file should return empty output, got: '${result}'"
fi

# =============================================================================
# ## Files Modified section — bare path
# =============================================================================

echo "=== extract_files_from_coder_summary: Files Modified bare path ==="

cat > "${TMPDIR_EF}/coder1.md" <<'EOF'
## Status: COMPLETE

## Files Modified
- lib/indexer.sh
- stages/coder.sh

## Architecture Decisions
- some decision
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder1.md")

if echo "$result" | grep -q "lib/indexer.sh"; then
    pass "extracts bare path from Files Modified"
else
    fail "should extract 'lib/indexer.sh', got: '${result}'"
fi

if echo "$result" | grep -q "stages/coder.sh"; then
    pass "extracts second bare path from Files Modified"
else
    fail "should extract 'stages/coder.sh', got: '${result}'"
fi

# =============================================================================
# ## Files Modified section — backtick-wrapped paths
# =============================================================================

echo "=== extract_files_from_coder_summary: Files Modified backtick paths ==="

cat > "${TMPDIR_EF}/coder2.md" <<'EOF'
## Files Modified
- `lib/indexer.sh` — Added get_repo_map_slice
- `lib/indexer_helpers.sh` — New file
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder2.md")

if echo "$result" | grep -q "lib/indexer.sh"; then
    pass "extracts backtick-wrapped path"
else
    fail "should extract 'lib/indexer.sh' from backtick-wrapped entry, got: '${result}'"
fi

if echo "$result" | grep -q "lib/indexer_helpers.sh"; then
    pass "extracts second backtick-wrapped path"
else
    fail "should extract 'lib/indexer_helpers.sh', got: '${result}'"
fi

# Ensure the description after " —" is NOT included
if echo "$result" | grep -q "Added\|New file"; then
    fail "result should not include the description after dash, got: '${result}'"
else
    pass "descriptions after em-dash are stripped"
fi

# =============================================================================
# ## Files Created or Modified section header variant
# =============================================================================

echo "=== extract_files_from_coder_summary: Files Created or Modified ==="

cat > "${TMPDIR_EF}/coder3.md" <<'EOF'
## Files Created or Modified
- `stages/tester.sh`
- `prompts/tester.prompt.md`

## Human Notes Status
N/A
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder3.md")

if echo "$result" | grep -q "stages/tester.sh"; then
    pass "parses 'Files Created or Modified' section header"
else
    fail "should parse 'Files Created or Modified', got: '${result}'"
fi

if echo "$result" | grep -q "prompts/tester.prompt.md"; then
    pass "extracts second file from 'Files Created or Modified'"
else
    fail "should extract both files, got: '${result}'"
fi

# =============================================================================
# Stops at next ## heading
# =============================================================================

echo "=== extract_files_from_coder_summary: stops at next heading ==="

cat > "${TMPDIR_EF}/coder4.md" <<'EOF'
## Files Modified
- `lib/foo.sh`

## Architecture Decisions
- `lib/bar.sh`
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder4.md")

if echo "$result" | grep -q "lib/foo.sh"; then
    pass "includes file from Files Modified section"
else
    fail "should include 'lib/foo.sh', got: '${result}'"
fi

if ! echo "$result" | grep -q "lib/bar.sh"; then
    pass "does not include file from Architecture Decisions section (stops at next ##)"
else
    fail "should stop at next ## heading, got: '${result}'"
fi

# =============================================================================
# None entry is filtered out
# =============================================================================

echo "=== extract_files_from_coder_summary: None entry filtered ==="

cat > "${TMPDIR_EF}/coder5.md" <<'EOF'
## Files Modified
- None
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder5.md")

if [ -z "$result" ]; then
    pass "'None' entry produces empty result"
else
    fail "'None' should be filtered out, got: '${result}'"
fi

# =============================================================================
# No Files section returns empty
# =============================================================================

echo "=== extract_files_from_coder_summary: no Files section ==="

cat > "${TMPDIR_EF}/coder6.md" <<'EOF'
## Status: COMPLETE

## What Was Implemented
- Something useful
EOF

result=$(extract_files_from_coder_summary "${TMPDIR_EF}/coder6.md")

if [ -z "$result" ]; then
    pass "no Files section returns empty output"
else
    fail "no Files section should return empty, got: '${result}'"
fi

# =============================================================================
# Summary
# =============================================================================

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
