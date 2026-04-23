#!/usr/bin/env bash
# Test: run_plan_generate() post-processing path
#
# Verifies that after run_plan_generate() writes CLAUDE.md:
# - When MILESTONE_DAG_ENABLED=true and CLAUDE.md has inline milestones,
#   migrate_inline_milestones() is called → MANIFEST.cfg created
# - _insert_milestone_pointer() is called → pointer comment in CLAUDE.md
# - Milestone content removed from CLAUDE.md
# - When _call_planning_batch returns empty, CLAUDE.md is not written
# - When MILESTONE_DAG_ENABLED=false, post-processing is skipped
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"
export TEKHTON_DIR=".tekhton"
export DESIGN_FILE="${TEKHTON_DIR}/DESIGN.md"

mkdir -p "${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/${TEKHTON_DIR}"

source "${TEKHTON_HOME}/lib/common.sh"

# --- Stubs -------------------------------------------------------------------

# render_prompt: just return a stub prompt string
render_prompt() { echo "stub prompt for ${1:-plan_generate}"; }

# PLAN_GENERATION_MODEL / MAX_TURNS
PLAN_GENERATION_MODEL="claude-test"
PLAN_GENERATION_MAX_TURNS=5

MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_DIR=".claude/milestones"
export MILESTONE_MANIFEST MILESTONE_DIR

run_build_gate() { return 0; }

# Source DAG libraries needed by plan_generate.sh's post-processing
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

# Source plan_batch.sh for _trim_document_preamble helper used by plan_generate.sh
source "${TEKHTON_HOME}/lib/plan_batch.sh"

# M121: Stub _assert_design_file_usable (normally provided by lib/plan.sh).
# DESIGN_FILE is set to a valid path above, so the stub just returns 0.
_assert_design_file_usable() { return 0; }

# Source plan_generate.sh itself (defines run_plan_generate and _insert_milestone_pointer)
source "${TEKHTON_HOME}/stages/plan_generate.sh"

cd "$TMPDIR"

PASS=0
FAIL=0

assert() {
    local desc="$1"
    local result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# Shared CLAUDE.md content with inline milestones (what the agent would output)
GENERATED_CLAUDE_MD='# Project Rules

## Architecture Philosophy
Keep it simple.

### Milestone Plan

#### Milestone 1: First Feature
Implement the first feature.

Acceptance criteria:
- Feature works correctly
- Tests pass

#### Milestone 2: Second Feature
Depends on Milestone 1.

Implement the second feature.

Acceptance criteria:
- Second feature works

## Code Conventions
Follow bash conventions.
'

# =============================================================================
echo "--- Test: Happy path — DAG enabled, milestones extracted after generation ---"

# Set up DESIGN.md
echo "# Design Document" > "${TMPDIR}/${DESIGN_FILE}"
echo "This is the design." >> "${TMPDIR}/${DESIGN_FILE}"

# Stub _call_planning_batch to return CLAUDE.md content with inline milestones
_call_planning_batch() {
    # Ignore model/turns/prompt/logfile args
    printf '%s' "$GENERATED_CLAUDE_MD"
}

MILESTONE_DAG_ENABLED=true
export MILESTONE_DAG_ENABLED

# Reset DAG state
_DAG_IDS=()
_DAG_TITLES=()
_DAG_STATUSES=()
_DAG_DEPS=()
_DAG_FILES=()
_DAG_GROUPS=()
_DAG_IDX=()
_DAG_LOADED=false

result=0
run_plan_generate >/dev/null 2>&1 || result=$?
assert "run_plan_generate returns 0 on success" "$result"

# CLAUDE.md should be written
result=0
[[ -f "${TMPDIR}/CLAUDE.md" ]] && result=0 || result=1
assert "CLAUDE.md written to PROJECT_DIR" "$result"

# MANIFEST.cfg should be created by post-processing
MANIFEST_PATH="${TMPDIR}/.claude/milestones/MANIFEST.cfg"
result=0
[[ -f "$MANIFEST_PATH" ]] && result=0 || result=1
assert "MANIFEST.cfg created by post-processing" "$result"

# Load manifest and verify milestone count
if [[ -f "$MANIFEST_PATH" ]]; then
    _DAG_IDS=(); _DAG_TITLES=(); _DAG_STATUSES=(); _DAG_DEPS=(); _DAG_FILES=(); _DAG_GROUPS=(); _DAG_IDX=(); _DAG_LOADED=false
    load_manifest "$MANIFEST_PATH"
    count=$(dag_get_count)
    result=0
    [[ "$count" -eq 2 ]] && result=0 || result=1
    assert "2 milestones extracted into manifest (got: $count)" "$result"
fi

# Pointer comment should be in CLAUDE.md
result=0
grep -q "Milestones are managed as individual files" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "milestone pointer comment inserted in CLAUDE.md" "$result"

# Milestone content should be removed from CLAUDE.md
result=0
grep -q "First Feature" "${TMPDIR}/CLAUDE.md" && result=1 || result=0
assert "inline milestone content removed from CLAUDE.md" "$result"

# Non-milestone content preserved
result=0
grep -q "Architecture Philosophy" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "architecture content preserved in CLAUDE.md" "$result"

result=0
grep -q "Code Conventions" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "code conventions preserved in CLAUDE.md" "$result"

# =============================================================================
echo "--- Test: MILESTONE_DAG_ENABLED=false — post-processing skipped ---"

# Clean state
rm -rf "${TMPDIR}/.claude/milestones"
rm -f "${TMPDIR}/CLAUDE.md"

_call_planning_batch() {
    printf '%s' "$GENERATED_CLAUDE_MD"
}

MILESTONE_DAG_ENABLED=false
export MILESTONE_DAG_ENABLED

result=0
run_plan_generate >/dev/null 2>&1 || result=$?
assert "run_plan_generate returns 0 with DAG disabled" "$result"

# MANIFEST.cfg should NOT be created
result=0
[[ ! -f "${TMPDIR}/.claude/milestones/MANIFEST.cfg" ]] && result=0 || result=1
assert "no manifest when MILESTONE_DAG_ENABLED=false" "$result"

# Inline milestone content should remain in CLAUDE.md
result=0
grep -q "First Feature" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "inline milestone content preserved when DAG disabled" "$result"

# =============================================================================
echo "--- Test: Empty batch output — CLAUDE.md not written ---"

# Clean state
rm -f "${TMPDIR}/CLAUDE.md"

_call_planning_batch() {
    # Return empty string (simulates agent producing no output)
    printf ''
    return 0
}

MILESTONE_DAG_ENABLED=true
export MILESTONE_DAG_ENABLED

result=0
run_plan_generate >/dev/null 2>&1 && result=1 || result=0
assert "run_plan_generate returns non-zero when batch produces no output" "$result"

result=0
[[ ! -f "${TMPDIR}/CLAUDE.md" ]] && result=0 || result=1
assert "CLAUDE.md not written when batch output is empty" "$result"

# =============================================================================
echo "--- Test: CLAUDE.md with no milestones — extraction skipped gracefully ---"

# Clean state
rm -rf "${TMPDIR}/.claude/milestones"
rm -f "${TMPDIR}/CLAUDE.md"

_call_planning_batch() {
    printf '# Project Rules\n\nNo milestones here.\n\n## Code Conventions\nFollow patterns.\n'
}

MILESTONE_DAG_ENABLED=true
export MILESTONE_DAG_ENABLED

result=0
run_plan_generate >/dev/null 2>&1 || result=$?
assert "run_plan_generate succeeds even with no milestones in output" "$result"

result=0
[[ -f "${TMPDIR}/CLAUDE.md" ]] && result=0 || result=1
assert "CLAUDE.md written even when no milestones in output" "$result"

# No manifest should be created
result=0
[[ ! -f "${TMPDIR}/.claude/milestones/MANIFEST.cfg" ]] && result=0 || result=1
assert "no manifest created when output has no milestones" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
