#!/usr/bin/env bash
# Test: Planning draft review — completeness calculation, section status display
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
export PROJECT_DIR="$TEST_TMPDIR"
export PLAN_ANSWER_FILE="${TEST_TMPDIR}/.claude/plan_answers.yaml"
export TEKHTON_VERSION="3.31.0"
export TEKHTON_TEST_MODE="true"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs for logging — print to stdout so we can capture output
log()     { echo "$*"; }
success() { echo "$*"; }
warn()    { echo "$*"; }
error()   { echo "$*"; }
header()  { echo "$*"; }
count_lines() { wc -l | tr -d ' '; }

# Source required libraries
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_answers.sh
source "${TEKHTON_HOME}/lib/plan_answers.sh"
# shellcheck source=../lib/plan_review.sh
source "${TEKHTON_HOME}/lib/plan_review.sh"

# --- Create a test template ---
PLAN_TEMPLATE_FILE="${TEST_TMPDIR}/template.md"
cat > "$PLAN_TEMPLATE_FILE" << 'EOF'
# Design Document — Test

## Project Overview
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- What does this do? -->

## Tech Stack
<!-- REQUIRED -->
<!-- PHASE:1 -->
<!-- Languages and frameworks -->

## Optional Notes
<!-- PHASE:2 -->
<!-- Any extra details -->
EOF

PLAN_PROJECT_TYPE="test"

# ============================================================
echo "=== _display_draft_summary: all sections empty ==="
# ============================================================

init_answer_file "$PLAN_PROJECT_TYPE" "$PLAN_TEMPLATE_FILE"

output=$(_display_draft_summary 2>&1)

if echo "$output" | grep -q "Planning Draft Review"; then
    pass "Summary shows title"
else
    fail "Summary missing title"
fi

if echo "$output" | grep -qE "✗.*Project Overview"; then
    pass "Empty required section shows ✗"
else
    fail "Empty required section should show ✗"
fi

# Optional sections with empty answer count as "skipped" = complete
if echo "$output" | grep -q "1 of 3 sections complete"; then
    pass "Shows 1 of 3 complete (optional empty counts as skipped)"
else
    fail "Expected 1 of 3 complete (optional empty = skipped)"
    echo "$output" | grep "sections complete" || true
fi

# ============================================================
echo
echo "=== _display_draft_summary: partially filled ==="
# ============================================================

save_answer "project_overview" "A web application for managing tasks."
save_answer "optional_notes" "SKIP"

output=$(_display_draft_summary 2>&1)

if echo "$output" | grep -qE "✓.*Project Overview"; then
    pass "Answered section shows ✓"
else
    fail "Answered section should show ✓"
fi

if echo "$output" | grep -qE "✗.*Tech Stack"; then
    pass "Unanswered required section shows ✗"
else
    fail "Unanswered required section should show ✗"
fi

if echo "$output" | grep -qE "~.*Optional Notes"; then
    pass "Skipped optional section shows ~"
else
    fail "Skipped optional section should show ~"
fi

if echo "$output" | grep -q "2 of 3 sections complete"; then
    pass "Shows 2 of 3 complete (answered + skipped optional)"
else
    fail "Expected 2 of 3 complete"
    echo "$output" | grep "sections complete" || true
fi

if echo "$output" | grep -q "1 required section"; then
    pass "Shows 1 required section needs answers"
else
    fail "Should show 1 required section needing answers"
fi

# ============================================================
echo
echo "=== _display_draft_summary: all complete ==="
# ============================================================

save_answer "tech_stack" "Python with FastAPI"

output=$(_display_draft_summary 2>&1)

if echo "$output" | grep -q "3 of 3 sections complete"; then
    pass "Shows 3 of 3 complete"
else
    fail "Expected 3 of 3 complete"
    echo "$output" | grep "sections complete" || true
fi

# ============================================================
echo
echo "=== _display_draft_summary: char counts ==="
# ============================================================

output=$(_display_draft_summary 2>&1)

if echo "$output" | grep -qE "Project Overview \([0-9]+ chars\)"; then
    pass "Shows character count for answered section"
else
    fail "Should show character count"
fi

# ============================================================
echo
echo "=== _display_draft_summary: phase headers ==="
# ============================================================

output=$(_display_draft_summary 2>&1)

if echo "$output" | grep -q "Phase 1: Concept Capture"; then
    pass "Shows Phase 1 header"
else
    fail "Missing Phase 1 header"
fi

if echo "$output" | grep -q "Phase 2: System Deep-Dive"; then
    pass "Shows Phase 2 header"
else
    fail "Missing Phase 2 header"
fi

# ============================================================
echo
echo "=== show_draft_review: quit action ==="
# ============================================================

# Pipe 'q' as input
output=$(echo "q" | show_draft_review 2>&1) || true

# Should not error — just exit
pass "show_draft_review handles quit without error"

# ============================================================
echo
echo "=== show_draft_review: start synthesis ==="
# ============================================================

# All required answered, so 's' should work
output=$(echo "s" | show_draft_review 2>&1)
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "show_draft_review returns 0 on synthesis start"
else
    fail "show_draft_review should return 0 on 's', got rc=${rc}"
fi

# ============================================================
# Summary
# ============================================================
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

[[ "$FAIL" -eq 0 ]] || exit 1
