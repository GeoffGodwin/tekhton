#!/usr/bin/env bash
# Regression test: DAG mode must not re-archive milestones originally archived
# under older initiative names.
#
# Bug: archive_completed_milestone() passed the current-initiative name (from
# _get_initiative_name, which always returns the initiative containing the DAG
# pointer comment) to _milestone_in_archive().  That scoped the search to the
# current initiative only — milestones archived under "Planning Phase Quality
# Overhaul" or "Adaptive Pipeline 2.0" were not found, so they were appended
# to the archive again on every run.
#
# Fix: when DAG mode is active, pass archive_initiative="" so that
# _milestone_in_archive() performs a global (unscoped) search.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
LOG_DIR="${TMPDIR_TEST}/.claude/logs"
PIPELINE_STATE_FILE="${TMPDIR_TEST}/.claude/PIPELINE_STATE.md"
MILESTONE_STATE_FILE="${TMPDIR_TEST}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR_TEST}/MILESTONE_ARCHIVE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
TEST_CMD=""
ANALYZE_CMD=""
export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST MILESTONE_ARCHIVE_FILE

mkdir -p "${TMPDIR_TEST}/.claude" "${LOG_DIR}"

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"

cd "$TMPDIR_TEST"

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

MILESTONE_DIR_ABS="${TMPDIR_TEST}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

# =============================================================================
# Scenario: milestones archived under older initiatives, current DAG initiative
# differs.  Reproduces the original bug exactly.
# =============================================================================
echo "--- Regression: no re-archival of cross-initiative milestones ---"

# MILESTONE_ARCHIVE.md already contains milestones from two older initiatives.
cat > "${MILESTONE_ARCHIVE_FILE}" << 'EOF'
# Milestone Archive

Completed milestone definitions archived from CLAUDE.md.
See git history for the commit that completed each milestone.

---

## Archived: 2026-01-10 — Planning Phase Quality Overhaul

#### Milestone 1: Model Default
Set default planning model to opus.

Acceptance criteria:
- PLAN_INTERVIEW_MODEL defaults to opus

---

## Archived: 2026-02-05 — Adaptive Pipeline 2.0

#### Milestone 2: Context Measurement
Add token accounting infrastructure.

Acceptance criteria:
- measure_context_size() returns counts
EOF

# MANIFEST.cfg: milestones m01 and m02 are "done", under the current V3 initiative
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Model Default|done||m01-model-default.md|foundation
m02|Context Measurement|done||m02-context-measurement.md|foundation
EOF

cat > "${MILESTONE_DIR_ABS}/m01-model-default.md" << 'EOF'
#### Milestone 1: Model Default
Set default planning model to opus.

Acceptance criteria:
- PLAN_INTERVIEW_MODEL defaults to opus
EOF

cat > "${MILESTONE_DIR_ABS}/m02-context-measurement.md" << 'EOF'
#### Milestone 2: Context Measurement
Add token accounting infrastructure.

Acceptance criteria:
- measure_context_size() returns counts
EOF

# CLAUDE.md: DAG pointer comment lives under the current V3 initiative.
# _get_initiative_name() will return this initiative for both milestones.
cat > "${TMPDIR_TEST}/CLAUDE.md" << 'EOF'
# Project Rules

## Current Initiative: Tekhton 3.0 — Milestone DAG, Intelligent Indexing & Cost Reduction

### Milestone Plan
<!-- Milestones are managed as individual files in .claude/milestones/ -->
<!-- See MILESTONE_ARCHIVE.md for completed milestones -->

EOF

load_manifest

archive_lines_before=$(wc -l < "${MILESTONE_ARCHIVE_FILE}")

# Test 1: archive_completed_milestone returns 1 for m01 (already archived globally)
result=0
archive_completed_milestone "1" "${TMPDIR_TEST}/CLAUDE.md" && result=1 || result=0
assert "archive_completed_milestone returns 1 for m01 already archived under old initiative" "$result"

# Test 2: archive does not grow after the call for m01
archive_lines_after_m01=$(wc -l < "${MILESTONE_ARCHIVE_FILE}")
assert "archive file does not grow when m01 is already archived under a different initiative" \
    "$([ "$archive_lines_after_m01" -eq "$archive_lines_before" ] && echo 0 || echo 1)"

# Test 3: archive_completed_milestone returns 1 for m02 (already archived globally)
result=0
archive_completed_milestone "2" "${TMPDIR_TEST}/CLAUDE.md" && result=1 || result=0
assert "archive_completed_milestone returns 1 for m02 already archived under old initiative" "$result"

# Test 4: archive does not grow after the call for m02
archive_lines_after_m02=$(wc -l < "${MILESTONE_ARCHIVE_FILE}")
assert "archive file does not grow when m02 is already archived under a different initiative" \
    "$([ "$archive_lines_after_m02" -eq "$archive_lines_before" ] && echo 0 || echo 1)"

# Test 5: archive still contains exactly the original entries (no duplicates)
m1_count=$(grep -c "#### Milestone 1: Model Default" "${MILESTONE_ARCHIVE_FILE}" || true)
assert "no duplicate entry for Milestone 1 in archive (count should be 1, got: $m1_count)" \
    "$([ "$m1_count" -eq 1 ] && echo 0 || echo 1)"

m2_count=$(grep -c "#### Milestone 2: Context Measurement" "${MILESTONE_ARCHIVE_FILE}" || true)
assert "no duplicate entry for Milestone 2 in archive (count should be 1, got: $m2_count)" \
    "$([ "$m2_count" -eq 1 ] && echo 0 || echo 1)"

# =============================================================================
# Scenario: fresh milestone (not yet archived) — DAG mode must still archive it
# =============================================================================
echo "--- DAG mode still archives new milestones correctly ---"

cat >> "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
m03|New Milestone|done||m03-new-milestone.md|foundation
EOF

cat > "${MILESTONE_DIR_ABS}/m03-new-milestone.md" << 'EOF'
#### Milestone 3: New Milestone
A milestone not yet in the archive.

Acceptance criteria:
- Works correctly
EOF

load_manifest

# Test 6: a truly new done milestone IS archived
result=0
archive_completed_milestone "3" "${TMPDIR_TEST}/CLAUDE.md" && result=0 || result=1
assert "archive_completed_milestone returns 0 for a genuinely new done milestone" "$result"

# Test 7: archive grows for the new milestone
archive_lines_after_new=$(wc -l < "${MILESTONE_ARCHIVE_FILE}")
assert "archive file grows when a new milestone is archived" \
    "$([ "$archive_lines_after_new" -gt "$archive_lines_after_m02" ] && echo 0 || echo 1)"

# Test 8: archive contains the new milestone content
assert "archive contains content of new milestone" \
    "$(grep -q "New Milestone" "${MILESTONE_ARCHIVE_FILE}" && echo 0 || echo 1)"

# Test 9: second call for the new milestone is idempotent (returns 1, archive unchanged)
result=0
archive_completed_milestone "3" "${TMPDIR_TEST}/CLAUDE.md" && result=1 || result=0
assert "archive_completed_milestone is idempotent for new milestone on second call" "$result"

archive_lines_after_second=$(wc -l < "${MILESTONE_ARCHIVE_FILE}")
assert "archive does not grow on second call for new milestone" \
    "$([ "$archive_lines_after_second" -eq "$archive_lines_after_new" ] && echo 0 || echo 1)"

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
