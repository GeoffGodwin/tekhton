#!/usr/bin/env bash
# Test: lib/replan.sh — _apply_brownfield_delta preserves [DONE] milestones
# Feeds a CLAUDE.md with [DONE] milestones through _apply_brownfield_delta and
# asserts that COMPLETED_MILESTONES captures the correct content.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Setup ---

TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Source required libraries
export TEKHTON_TEST_MODE=1
DESIGN_FILE="${TEKHTON_DIR:-.tekhton}/DESIGN.md"
REPLAN_DELTA_FILE="${TEKHTON_DIR:-.tekhton}/REPLAN_DELTA.md"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/prompts.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/plan.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/replan.sh"

# Define mock run_plan_generate so _apply_brownfield_delta doesn't invoke claude.
# The function just writes a minimal CLAUDE.md from DESIGN_CONTENT.
run_plan_generate() {
    # Write COMPLETED_MILESTONES into a mock CLAUDE.md so the output is verifiable.
    {
        echo "# Mock Project"
        echo ""
        if [[ -n "${COMPLETED_MILESTONES:-}" ]]; then
            echo "${COMPLETED_MILESTONES}"
        fi
        echo ""
        echo "## Mock Section"
        echo "Content."
    } > "${PROJECT_DIR}/CLAUDE.md"
    return 0
}
export -f run_plan_generate

# Helper: create a fresh project dir for each test
new_project_dir() {
    local d
    d=$(mktemp -d "${TMPDIR_BASE}/proj_XXXXXX")
    mkdir -p "${d}/.claude/logs/archive"
    echo "$d"
}

# Helper: write a CLAUDE.md with [DONE] and pending milestones
write_claude_md() {
    local dir="$1"
    cat > "${dir}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

## Implementation Milestones

#### [DONE] Milestone 1: Setup
Initial scaffolding complete.
Key files created.

#### [DONE] Milestone 2: Core Logic
Core algorithm implemented.
Tests passing.

#### Milestone 3: Polish
Not yet started.

#### Milestone 4: Deploy
Future work.
CLAUDE_EOF
}

# ---------------------------------------------------------------------------
echo "=== Test: single [DONE] milestone extraction ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### [DONE] Milestone 1: Setup
Initial scaffolding complete.

#### Milestone 2: Pending
Not done yet.
CLAUDE_EOF

# Create DESIGN.md and delta file
mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Existing Design" > "${proj}/${DESIGN_FILE}"
echo "Delta content here." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

if [[ "${COMPLETED_MILESTONES}" == *"[DONE] Milestone 1"* ]]; then
    pass "COMPLETED_MILESTONES contains the [DONE] heading"
else
    fail "COMPLETED_MILESTONES missing [DONE] heading; got: '${COMPLETED_MILESTONES}'"
fi

if [[ "${COMPLETED_MILESTONES}" == *"Initial scaffolding complete."* ]]; then
    pass "COMPLETED_MILESTONES contains milestone body text"
else
    fail "COMPLETED_MILESTONES missing milestone body; got: '${COMPLETED_MILESTONES}'"
fi

if [[ "${COMPLETED_MILESTONES}" == *"Milestone 2"* ]]; then
    fail "COMPLETED_MILESTONES should NOT contain non-DONE Milestone 2"
else
    pass "COMPLETED_MILESTONES does not contain non-DONE milestone"
fi

# ---------------------------------------------------------------------------
echo "=== Test: multiple [DONE] milestones ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"
write_claude_md "$proj"
mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Existing Design" > "${proj}/${DESIGN_FILE}"
echo "Delta content." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

if [[ "${COMPLETED_MILESTONES}" == *"[DONE] Milestone 1"* ]]; then
    pass "COMPLETED_MILESTONES contains first [DONE] milestone"
else
    fail "COMPLETED_MILESTONES missing first [DONE] milestone; got: '${COMPLETED_MILESTONES}'"
fi

if [[ "${COMPLETED_MILESTONES}" == *"[DONE] Milestone 2"* ]]; then
    pass "COMPLETED_MILESTONES contains second [DONE] milestone"
else
    fail "COMPLETED_MILESTONES missing second [DONE] milestone; got: '${COMPLETED_MILESTONES}'"
fi

if [[ "${COMPLETED_MILESTONES}" == *"Milestone 3"* ]]; then
    fail "COMPLETED_MILESTONES should NOT contain non-DONE Milestone 3"
else
    pass "COMPLETED_MILESTONES excludes non-DONE Milestone 3"
fi

if [[ "${COMPLETED_MILESTONES}" == *"Milestone 4"* ]]; then
    fail "COMPLETED_MILESTONES should NOT contain non-DONE Milestone 4"
else
    pass "COMPLETED_MILESTONES excludes non-DONE Milestone 4"
fi

# ---------------------------------------------------------------------------
echo "=== Test: no [DONE] milestones produces empty COMPLETED_MILESTONES ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### Milestone 1: Pending
Not done.

#### Milestone 2: Also Pending
Also not done.
CLAUDE_EOF

mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Design" > "${proj}/${DESIGN_FILE}"
echo "Delta." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

if [[ -z "${COMPLETED_MILESTONES}" ]]; then
    pass "COMPLETED_MILESTONES is empty when no [DONE] milestones exist"
else
    fail "COMPLETED_MILESTONES should be empty; got: '${COMPLETED_MILESTONES}'"
fi

# ---------------------------------------------------------------------------
echo "=== Test: [DONE] milestone body stops at next non-DONE #### heading ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### [DONE] Milestone 1: First
Body of milestone one.
Some more text.

#### Milestone 2: Not Done
This should not appear.
CLAUDE_EOF

mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Design" > "${proj}/${DESIGN_FILE}"
echo "Delta." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

if [[ "${COMPLETED_MILESTONES}" == *"Body of milestone one."* ]]; then
    pass "[DONE] milestone body is captured"
else
    fail "[DONE] milestone body not captured; got: '${COMPLETED_MILESTONES}'"
fi

if [[ "${COMPLETED_MILESTONES}" == *"This should not appear."* ]]; then
    fail "non-DONE milestone body leaked into COMPLETED_MILESTONES"
else
    pass "non-DONE milestone body is excluded"
fi

# ---------------------------------------------------------------------------
echo "=== Test: delta is appended to DESIGN.md ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### [DONE] Milestone 1: Done
Complete.
CLAUDE_EOF

mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Original Design Content" > "${proj}/${DESIGN_FILE}"
echo "New delta information." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

design_content=$(cat "${proj}/${DESIGN_FILE}")

if [[ "$design_content" == *"# Original Design Content"* ]]; then
    pass "original DESIGN.md content is preserved"
else
    fail "original DESIGN.md content was lost"
fi

if [[ "$design_content" == *"New delta information."* ]]; then
    pass "delta content was appended to DESIGN.md"
else
    fail "delta content not found in DESIGN.md"
fi

if [[ "$design_content" == *"## Replan Delta"* ]]; then
    pass "Replan Delta section heading added to DESIGN.md"
else
    fail "Replan Delta heading missing from DESIGN.md"
fi

# ---------------------------------------------------------------------------
echo "=== Test: delta archived after apply ==="

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### [DONE] Milestone 1: Done
Complete.
CLAUDE_EOF

mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Design" > "${proj}/${DESIGN_FILE}"
echo "Delta to archive." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

# Delta file should have been moved to archive
if [[ ! -f "${proj}/REPLAN_DELTA.md" ]]; then
    pass "REPLAN_DELTA.md was removed from project root after apply"
else
    fail "REPLAN_DELTA.md still exists at project root after apply"
fi

archive_count=$(find "${proj}/.claude/logs/archive" -name "*REPLAN_DELTA*" 2>/dev/null | wc -l)
if [[ "$archive_count" -gt 0 ]]; then
    pass "REPLAN_DELTA.md was moved to archive directory"
else
    fail "REPLAN_DELTA.md not found in archive directory"
fi

# ---------------------------------------------------------------------------
echo "=== Test: regenerated CLAUDE.md contains [DONE] milestones ==="
# This validates the end-to-end: COMPLETED_MILESTONES injected into mock
# run_plan_generate, resulting CLAUDE.md contains the [DONE] milestone text.

proj=$(new_project_dir)
export PROJECT_DIR="$proj"

cat > "${proj}/CLAUDE.md" << 'CLAUDE_EOF'
# Test Project

#### [DONE] Milestone 1: Foundation
Foundation is complete.
This milestone laid the groundwork.

#### Milestone 2: Extensions
Not yet implemented.
CLAUDE_EOF

mkdir -p "${proj}/${TEKHTON_DIR:-.tekhton}"
echo "# Design" > "${proj}/${DESIGN_FILE}"
echo "Delta content for regeneration test." > "${proj}/REPLAN_DELTA.md"

_apply_brownfield_delta "${proj}/REPLAN_DELTA.md"

# The mock run_plan_generate writes COMPLETED_MILESTONES into CLAUDE.md
regen_content=$(cat "${proj}/CLAUDE.md" 2>/dev/null || true)

if [[ "$regen_content" == *"[DONE] Milestone 1"* ]]; then
    pass "regenerated CLAUDE.md contains [DONE] milestone heading"
else
    fail "regenerated CLAUDE.md missing [DONE] milestone; content: '${regen_content}'"
fi

if [[ "$regen_content" == *"Foundation is complete."* ]]; then
    pass "regenerated CLAUDE.md contains [DONE] milestone body text"
else
    fail "regenerated CLAUDE.md missing [DONE] body; content: '${regen_content}'"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
echo "  Passed: ${PASS}  Failed: ${FAIL}"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
