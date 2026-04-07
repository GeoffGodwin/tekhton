#!/usr/bin/env bash
# Test: Verify relaxed grep pattern correctly detects stub CLAUDE.md files
# Tests the fix from lib/init_report.sh:130

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $1"
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $1"
    exit 1
}

# Test 1: Relaxed pattern matches actual stub text
test_pattern_matches_stub_text() {
    local claude_md
    claude_md=$(mktemp)
    trap "rm -f '$claude_md'" RETURN

    # Actual stub text injected by init_helpers.sh:252
    cat > "$claude_md" << 'EOF'
# CLAUDE.md

## Milestones

#### Milestone

<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->
EOF

    # The relaxed pattern should match this
    if grep -q '<!-- TODO:.*--plan' "$claude_md"; then
        pass "Relaxed pattern matches actual stub text format"
    else
        fail "Relaxed pattern did not match actual stub text"
    fi
}

# Test 2: Old strict pattern does NOT match (demonstrating the bug)
test_old_pattern_fails() {
    local claude_md
    claude_md=$(mktemp)
    trap "rm -f '$claude_md'" RETURN

    cat > "$claude_md" << 'EOF'
# CLAUDE.md

#### Milestone

<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->
EOF

    # The old strict pattern should NOT match this (the bug)
    if grep -q '<!-- TODO:.*--plan -->' "$claude_md"; then
        fail "Old strict pattern should not match actual stub text (it does — old bug)"
    else
        pass "Old strict pattern correctly does not match stub text (confirms the bug existed)"
    fi
}

# Test 3: Relaxed pattern doesn't match non-stub content
test_pattern_no_false_positive_on_real_milestones() {
    local claude_md
    claude_md=$(mktemp)
    trap "rm -f '$claude_md'" RETURN

    # Real milestone content (not a stub)
    cat > "$claude_md" << 'EOF'
# CLAUDE.md

## Milestones

#### Milestone 1: Add User Auth

Implementation details here...
EOF

    # Should NOT match because there's no TODO comment
    if grep -q '<!-- TODO:.*--plan' "$claude_md"; then
        fail "Pattern should not match real milestone content (no TODO)"
    else
        pass "Pattern correctly does not match real milestone content"
    fi
}

# Test 4: Pattern matches stub with alternate whitespace
test_pattern_with_variations() {
    local claude_md
    claude_md=$(mktemp)
    trap "rm -f '$claude_md'" RETURN

    # Stub with extra spaces
    cat > "$claude_md" << 'EOF'
<!-- TODO:  Add milestones here, or run tekhton --plan  to generate them -->
EOF

    if grep -q '<!-- TODO:.*--plan' "$claude_md"; then
        pass "Pattern matches stub with whitespace variations"
    else
        fail "Pattern should match stub with whitespace variations"
    fi
}

# Test 5: Full detection logic (from init_report.sh:126-133)
test_full_detection_logic() {
    local project_dir
    project_dir=$(mktemp -d)
    trap "rm -rf '$project_dir'" RETURN

    mkdir -p "$project_dir/.claude/milestones"

    local _claude_md="${project_dir}/CLAUDE.md"

    # Case 1: Stub file (has TODO with --plan)
    cat > "$_claude_md" << 'EOF'
# CLAUDE.md
<!-- TODO: Add milestones here, or run tekhton --plan to generate them -->
#### Milestone
EOF

    local _has_milestones=false
    if [[ -f "${project_dir}/.claude/milestones/MANIFEST.cfg" ]] \
        && grep -q '|' "${project_dir}/.claude/milestones/MANIFEST.cfg" 2>/dev/null; then
        _has_milestones=true
    elif [[ -f "$_claude_md" ]] \
        && ! grep -q '<!-- TODO:.*--plan' "$_claude_md" 2>/dev/null \
        && grep -q '^#### Milestone' "$_claude_md" 2>/dev/null; then
        _has_milestones=true
    fi

    if [[ "$_has_milestones" == "false" ]]; then
        pass "Detection correctly identifies stub file (has TODO --plan, so not real milestones)"
    else
        fail "Detection should identify stub file (not count as real milestones)"
    fi

    # Case 2: Real milestone file (no TODO comment)
    cat > "$_claude_md" << 'EOF'
# CLAUDE.md
#### Milestone 1: Real Implementation
EOF

    _has_milestones=false
    if [[ -f "${project_dir}/.claude/milestones/MANIFEST.cfg" ]] \
        && grep -q '|' "${project_dir}/.claude/milestones/MANIFEST.cfg" 2>/dev/null; then
        _has_milestones=true
    elif [[ -f "$_claude_md" ]] \
        && ! grep -q '<!-- TODO:.*--plan' "$_claude_md" 2>/dev/null \
        && grep -q '^#### Milestone' "$_claude_md" 2>/dev/null; then
        _has_milestones=true
    fi

    if [[ "$_has_milestones" == "true" ]]; then
        pass "Detection correctly identifies real milestones (no TODO, has #### Milestone)"
    else
        fail "Detection should identify real milestones"
    fi
}

# Run all tests
test_pattern_matches_stub_text
test_old_pattern_fails
test_pattern_no_false_positive_on_real_milestones
test_pattern_with_variations
test_full_detection_logic

echo
echo -e "${GREEN}All tests passed!${NC}"
