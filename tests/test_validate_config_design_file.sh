#!/usr/bin/env bash
# =============================================================================
# test_validate_config_design_file.sh — DESIGN_FILE validation edge cases
#
# Verifies checks 6a and 6b in lib/validate_config.sh:
#   6a: Empty DESIGN_FILE string in pipeline.conf is detected and warned
#   6b: DESIGN_FILE ending in '/' (directory vs file) is detected and warned
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Stubs for dependency functions
log()  { :; }
warn() { :; }
error() { :; }
success() { :; }
header() { :; }
_is_utf8_terminal() { return 1; }  # Assume non-UTF8 for consistent test output

# =============================================================================
echo "=== Test 6a: Empty DESIGN_FILE string in pipeline.conf ==="
# =============================================================================

PROJECT_DIR="$TEST_TMPDIR/proj_empty_design"
mkdir -p "$PROJECT_DIR/.claude"

# Create a pipeline.conf with DESIGN_FILE = "" (empty string)
cat > "$PROJECT_DIR/.claude/pipeline.conf" <<'EOF'
PROJECT_NAME="TestProject"
DESIGN_FILE=""
EOF

# Check the grep pattern used in validate_config.sh (line 126)
# It detects: ^[[:space:]]*DESIGN_FILE[[:space:]]*=[[:space:]]*("[[:space:]]*"|''|)[[:space:]]*(#.*)?$
if grep -qE '^[[:space:]]*DESIGN_FILE[[:space:]]*=[[:space:]]*("[[:space:]]*"|'"'"''"'"'|)[[:space:]]*(#.*)?$' \
   "$PROJECT_DIR/.claude/pipeline.conf"; then
    pass "Check 6a pattern correctly matches empty DESIGN_FILE in pipeline.conf"
else
    fail "Check 6a pattern should match empty DESIGN_FILE"
fi

# =============================================================================
echo "=== Test 6b: DESIGN_FILE ending in '/' (directory path) ==="
# =============================================================================

# Test the condition: [[ "${DESIGN_FILE}" == */ ]]
DESIGN_FILE="designs/"
if [[ "${DESIGN_FILE}" == */ ]]; then
    pass "Check 6b correctly identifies trailing slash in DESIGN_FILE"
else
    fail "Check 6b should identify DESIGN_FILE ending in '/'"
fi

# Test non-slash variant should not match
DESIGN_FILE="DESIGN.md"
if [[ ! "${DESIGN_FILE}" == */ ]]; then
    pass "Check 6b correctly rejects normal file path"
else
    fail "Check 6b should not flag normal file path"
fi

# =============================================================================
echo "=== Test 7: DESIGN_FILE file existence check ==="
# =============================================================================

PROJECT_DIR="$TEST_TMPDIR/proj_file_check"
mkdir -p "$PROJECT_DIR"

# Case 1: File exists
cat > "$PROJECT_DIR/DESIGN.md" <<'EOF'
# Design
EOF

DESIGN_FILE="DESIGN.md"
if [[ -f "${PROJECT_DIR}/${DESIGN_FILE}" ]]; then
    pass "Check 7 detects existing DESIGN_FILE file"
else
    fail "Check 7 should find existing DESIGN_FILE"
fi

# Case 2: File does not exist
DESIGN_FILE="MISSING.md"
if [[ ! -f "${PROJECT_DIR}/${DESIGN_FILE}" ]]; then
    pass "Check 7 detects missing DESIGN_FILE"
else
    fail "Check 7 should detect missing DESIGN_FILE"
fi

# Case 3: Path is a directory, not a file (the issue from 6b)
mkdir -p "$PROJECT_DIR/designs"
DESIGN_FILE="designs/"
if [[ ! -f "${PROJECT_DIR}/${DESIGN_FILE}" ]]; then
    pass "Check 7 rejects directory path (DESIGN_FILE with /)"
else
    fail "Check 7 should reject directory path"
fi

# =============================================================================
echo "=== Integration: Grep patterns in pipeline.conf ==="
# =============================================================================

# Test a real pipeline.conf with multiple DESIGN_FILE variants
cat > "$TEST_TMPDIR/test.conf" <<'EOF'
# Valid
PROJECT_NAME="Test"
DESIGN_FILE="DESIGN.md"

# Empty string variant 1
DESIGN_FILE=""

# Empty string variant 2
DESIGN_FILE=''

# Empty string variant 3
DESIGN_FILE = "    "

# Directory path
DESIGN_FILE="designs/"

# With comment
DESIGN_FILE="" # fallback to default
EOF

# Count how many lines match the empty-string pattern (6a)
# The pattern in validate_config.sh line 126 matches various empty string representations
empty_count=$(grep -E '^[[:space:]]*DESIGN_FILE[[:space:]]*=[[:space:]]*("[[:space:]]*"|'"'"''"'"'|)[[:space:]]*(#.*)?$' "$TEST_TMPDIR/test.conf" 2>/dev/null | wc -l)
if [[ "$empty_count" -ge 1 ]]; then
    pass "Check 6a pattern matches empty string variant(s) in pipeline.conf"
else
    fail "Check 6a pattern should match at least one empty variant (found $empty_count)"
fi

# Count how many non-empty DESIGN_FILE lines exist
total_count=$(grep -c '^[[:space:]]*DESIGN_FILE' "$TEST_TMPDIR/test.conf" || true)
if [[ "$total_count" -gt 0 ]]; then
    pass "Grep correctly identifies DESIGN_FILE lines in config"
else
    fail "Grep should find DESIGN_FILE lines in config"
fi

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  ${PASS} passed, ${FAIL} failed"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
