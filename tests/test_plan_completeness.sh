#!/usr/bin/env bash
# Test: Planning phase completeness check logic
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# Create a temporary project dir
TEST_TMPDIR=$(mktemp -d)
PROJECT_DIR="$TEST_TMPDIR"
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Source the required libraries (stubs for logging)
log()     { :; }
success() { :; }
warn()    { :; }
error()   { :; }
header()  { :; }

# Source plan.sh (constants and config defaults) and plan_completeness.sh (check functions)
# shellcheck source=../lib/plan.sh
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=../lib/plan_completeness.sh
source "${TEKHTON_HOME}/lib/plan_completeness.sh"

# --- Test template with REQUIRED markers ---
PLAN_TEMPLATE_FILE="${TEST_TMPDIR}/template.md"
cat > "$PLAN_TEMPLATE_FILE" << 'EOF'
# Design Document — Test

## Project Overview
<!-- REQUIRED -->
<!-- What does this do? -->

## Tech Stack
<!-- REQUIRED -->
<!-- Language, framework -->

## Optional Section
<!-- Some guidance -->

## Core Features
<!-- REQUIRED -->
<!-- List features -->
EOF

echo "=== _extract_required_sections ==="

required=$(_extract_required_sections "$PLAN_TEMPLATE_FILE")

if echo "$required" | grep -q "Project Overview"; then
    pass "Finds 'Project Overview' as required"
else
    fail "Missing 'Project Overview' in required list"
fi

if echo "$required" | grep -q "Tech Stack"; then
    pass "Finds 'Tech Stack' as required"
else
    fail "Missing 'Tech Stack' in required list"
fi

if echo "$required" | grep -q "Core Features"; then
    pass "Finds 'Core Features' as required"
else
    fail "Missing 'Core Features' in required list"
fi

if echo "$required" | grep -q "Optional Section"; then
    fail "'Optional Section' should NOT be in required list"
else
    pass "'Optional Section' not in required list"
fi

count=$(echo "$required" | grep -c '.' || true)
if [ "$count" -eq 3 ]; then
    pass "Exactly 3 required sections found"
else
    fail "Expected 3 required sections, got ${count}"
fi

echo
echo "=== _is_section_incomplete ==="

# Empty content
if _is_section_incomplete ""; then
    pass "Empty string is incomplete"
else
    fail "Empty string should be incomplete"
fi

# Whitespace only
if _is_section_incomplete "
  "; then
    pass "Whitespace-only is incomplete"
else
    fail "Whitespace-only should be incomplete"
fi

# Guidance comments only
if _is_section_incomplete "<!-- What does this do? -->"; then
    pass "Guidance comment only is incomplete"
else
    fail "Guidance comment only should be incomplete"
fi

# Placeholder TBD
if _is_section_incomplete "TBD"; then
    pass "'TBD' placeholder is incomplete"
else
    fail "'TBD' should be incomplete"
fi

# Placeholder TODO (case insensitive)
if _is_section_incomplete "todo"; then
    pass "'todo' placeholder is incomplete"
else
    fail "'todo' should be incomplete"
fi

# Real content
if _is_section_incomplete "A web application for managing tasks."; then
    fail "Real content should be complete"
else
    pass "Real content is complete"
fi

# Content with leftover guidance comment
if _is_section_incomplete "React and Node.js <!-- add more detail -->"; then
    pass "Content with leftover guidance comment is incomplete"
else
    fail "Content with leftover guidance comment should be incomplete"
fi

echo
echo "=== check_design_completeness ==="

# --- Complete DESIGN.md ---
cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document — Test

## Project Overview
A task management web application for small teams.

## Tech Stack
React, Node.js, PostgreSQL, deployed on AWS.

## Optional Section
Skipped.

## Core Features
- Create and assign tasks
- Due date tracking
- Team dashboard
EOF

if check_design_completeness; then
    pass "Complete DESIGN.md passes check"
else
    fail "Complete DESIGN.md should pass check"
fi

# --- Incomplete DESIGN.md (empty section) ---
cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document — Test

## Project Overview
A task management web application.

## Tech Stack

## Core Features
- Create tasks
EOF

if check_design_completeness; then
    fail "DESIGN.md with empty Tech Stack should fail"
else
    pass "DESIGN.md with empty Tech Stack fails check"
fi

if echo "$PLAN_INCOMPLETE_SECTIONS" | grep -q "Tech Stack"; then
    pass "Tech Stack listed as incomplete"
else
    fail "Tech Stack should be listed as incomplete"
fi

# --- Missing section entirely ---
cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document — Test

## Project Overview
A task management web application.

## Core Features
- Create tasks
EOF

if check_design_completeness; then
    fail "DESIGN.md with missing Tech Stack should fail"
else
    pass "DESIGN.md with missing section fails check"
fi

if echo "$PLAN_INCOMPLETE_SECTIONS" | grep -q "Tech Stack"; then
    pass "Missing Tech Stack listed as incomplete"
else
    fail "Missing Tech Stack should be listed as incomplete"
fi

# --- Section with only guidance comments ---
cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document — Test

## Project Overview
A task management web application.

## Tech Stack
<!-- Language, framework -->

## Core Features
- Create tasks
EOF

if check_design_completeness; then
    fail "DESIGN.md with guidance-only Tech Stack should fail"
else
    pass "DESIGN.md with guidance-only section fails check"
fi

# --- Section with TBD placeholder ---
cat > "${TEST_TMPDIR}/DESIGN.md" << 'EOF'
# Design Document — Test

## Project Overview
A task management web application.

## Tech Stack
TBD

## Core Features
- Create tasks
EOF

if check_design_completeness; then
    fail "DESIGN.md with TBD Tech Stack should fail"
else
    pass "DESIGN.md with TBD section fails check"
fi

# --- Determinism: same input always same result ---
PLAN_INCOMPLETE_SECTIONS=""
check_design_completeness || true
result1="$PLAN_INCOMPLETE_SECTIONS"

PLAN_INCOMPLETE_SECTIONS=""
check_design_completeness || true
result2="$PLAN_INCOMPLETE_SECTIONS"

if [ "$result1" = "$result2" ]; then
    pass "Deterministic: same DESIGN.md produces same result"
else
    fail "Non-deterministic: got different results for same input"
fi

echo
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
