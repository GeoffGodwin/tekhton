#!/usr/bin/env bash
# =============================================================================
# test_draft_milestones_next_id.sh — Tests draft_milestones_next_id()
#
# Tests:
#   1. Empty manifest → next ID is 1
#   2. Populated manifest (m01–m72) → next ID is 73
#   3. Three-milestone split starting at 73 → returns 73, 74, 75
#   4. Milestone files without manifest entries are counted
#   5. Files and manifest together — highest wins
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }

# Minimal stubs for common.sh functions used by draft_milestones.sh
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source the library under test
# shellcheck source=lib/draft_milestones_write.sh
source "${TEKHTON_HOME}/lib/draft_milestones_write.sh"
# shellcheck source=lib/draft_milestones.sh
source "${TEKHTON_HOME}/lib/draft_milestones.sh" 2>/dev/null || true

# =============================================================================
# Test 1: Empty manifest — next ID is 1
# =============================================================================
_setup_empty() {
    local dir="$TMPDIR/test1"
    mkdir -p "$dir/.claude/milestones"
    cat > "$dir/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
EOF
    echo "$dir"
}

PROJECT_DIR=$(_setup_empty)
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
export PROJECT_DIR MILESTONE_DIR MILESTONE_MANIFEST

result=$(draft_milestones_next_id 1)
if [[ "$result" == "1" ]]; then
    pass "Empty manifest → next ID is 1"
else
    fail "Empty manifest → expected 1, got '${result}'"
fi

# =============================================================================
# Test 2: Populated manifest (m01–m72) → next ID is 73
# =============================================================================
_setup_populated() {
    local dir="$TMPDIR/test2"
    mkdir -p "$dir/.claude/milestones"
    {
        echo "# Tekhton Milestone Manifest v1"
        echo "# id|title|status|depends_on|file|parallel_group"
        for i in $(seq 1 72); do
            printf 'm%02d|Milestone %d|done||m%02d-test.md|\n' "$i" "$i" "$i"
        done
    } > "$dir/.claude/milestones/MANIFEST.cfg"
    echo "$dir"
}

PROJECT_DIR=$(_setup_populated)

result=$(draft_milestones_next_id 1)
if [[ "$result" == "73" ]]; then
    pass "Populated manifest (m01–m72) → next ID is 73"
else
    fail "Populated manifest → expected 73, got '${result}'"
fi

# =============================================================================
# Test 3: Three-milestone split starting at 73 → returns 73, 74, 75
# =============================================================================
result=$(draft_milestones_next_id 3)
expected=$'73\n74\n75'
if [[ "$result" == "$expected" ]]; then
    pass "Three-milestone split → 73, 74, 75"
else
    fail "Three-milestone split → expected '73 74 75', got '${result}'"
fi

# =============================================================================
# Test 4: Milestone files without manifest entries are counted
# =============================================================================
_setup_files_only() {
    local dir="$TMPDIR/test4"
    mkdir -p "$dir/.claude/milestones"
    cat > "$dir/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Test|done||m01-test.md|
EOF
    # Create milestone files beyond manifest
    touch "$dir/.claude/milestones/m50-extra.md"
    touch "$dir/.claude/milestones/m85-bonus.md"
    echo "$dir"
}

PROJECT_DIR=$(_setup_files_only)

result=$(draft_milestones_next_id 1)
if [[ "$result" == "86" ]]; then
    pass "Files without manifest entries → next ID is 86"
else
    fail "Files without manifest → expected 86, got '${result}'"
fi

# =============================================================================
# Test 5: Files and manifest together — highest wins
# =============================================================================
_setup_mixed() {
    local dir="$TMPDIR/test5"
    mkdir -p "$dir/.claude/milestones"
    cat > "$dir/.claude/milestones/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Test|done||m01-test.md|
m10|Test|done|m01|m10-test.md|
EOF
    # File with higher ID than manifest
    touch "$dir/.claude/milestones/m20-higher.md"
    echo "$dir"
}

PROJECT_DIR=$(_setup_mixed)

result=$(draft_milestones_next_id 1)
if [[ "$result" == "21" ]]; then
    pass "Mixed files+manifest → highest wins (21)"
else
    fail "Mixed → expected 21, got '${result}'"
fi

# =============================================================================
echo
if [[ "$FAIL" -gt 0 ]]; then
    echo "FAILED: ${FAIL} test(s)"
    exit 1
fi
echo "All draft_milestones_next_id tests passed."
