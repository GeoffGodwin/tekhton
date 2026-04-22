#!/usr/bin/env bash
# Test: Milestone DAG archival (archive_completed_milestone DAG path) and
# emit_milestone_metadata DAG path — coverage gaps from Milestone 1 review
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs required by sourced libraries
LOG_DIR="${TMPDIR}/.claude/logs"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
TEST_CMD=""
ANALYZE_CMD=""

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate (required by milestones.sh)
run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"
source "${TEKHTON_HOME}/lib/milestone_metadata.sh"

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

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

# =============================================================================
echo "--- Test: archive_completed_milestone() DAG path ---"

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|done||m01-dag-infra.md|foundation
EOF

cat > "${MILESTONE_DIR_ABS}/m01-dag-infra.md" << 'EOF'
# M1 — DAG Infrastructure

Implement the DAG-based milestone storage system.

Acceptance criteria:
- has_milestone_manifest() returns 0 when MANIFEST.cfg exists
- load_manifest() correctly parses a multi-line manifest
EOF

load_manifest

result=0
archive_completed_milestone "1" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "archive_completed_milestone returns 0 for a done milestone" "$result"

result=0
[[ -f "${MILESTONE_ARCHIVE_FILE}" ]] && result=0 || result=1
assert "MILESTONE_ARCHIVE.md is created after archival" "$result"

result=0
grep -q "DAG Infrastructure" "${MILESTONE_ARCHIVE_FILE}" 2>/dev/null && result=0 || result=1
assert "MILESTONE_ARCHIVE.md contains milestone file content" "$result"

# Idempotency: calling again should return 1 (already archived)
result=0
archive_completed_milestone "1" "${TMPDIR}/CLAUDE.md" && result=1 || result=0
assert "archive_completed_milestone returns 1 when already archived (idempotent)" "$result"

# Non-done milestone: should return 1
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|done||m01-dag-infra.md|foundation
m02|Sliding Window|pending|m01|m02-sliding-window.md|foundation
EOF

cat > "${MILESTONE_DIR_ABS}/m02-sliding-window.md" << 'EOF'
#### Milestone 2: Sliding Window

Implement sliding window context.

Acceptance criteria:
- build_milestone_window() returns budgeted context
EOF

load_manifest

rm -f "${MILESTONE_ARCHIVE_FILE}"

result=0
archive_completed_milestone "2" "${TMPDIR}/CLAUDE.md" && result=1 || result=0
assert "archive_completed_milestone returns 1 for a non-done (pending) milestone" "$result"

result=0
[[ ! -f "${MILESTONE_ARCHIVE_FILE}" ]] && result=0 || result=1
assert "MILESTONE_ARCHIVE.md not created for a non-done milestone" "$result"

# =============================================================================
echo "--- Test: emit_milestone_metadata() DAG path ---"

# Reset: fresh manifest with one pending milestone
rm -f "${MILESTONE_ARCHIVE_FILE}"

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Test Feature|pending||m01-test-feature.md|foundation
EOF

cat > "${MILESTONE_DIR_ABS}/m01-test-feature.md" << 'EOF'
#### Milestone 1: Test Feature

Implement the test feature.

Acceptance criteria:
- Works correctly
EOF

load_manifest

# (a) metadata is written into the milestone file
result=0
emit_milestone_metadata "1" "in_progress" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "emit_milestone_metadata returns 0 for a DAG milestone" "$result"

result=0
grep -q '^<!-- milestone-meta' "${MILESTONE_DIR_ABS}/m01-test-feature.md" && result=0 || result=1
assert "emit_milestone_metadata writes metadata block into the milestone file" "$result"

result=0
grep -q 'status: "in_progress"' "${MILESTONE_DIR_ABS}/m01-test-feature.md" && result=0 || result=1
assert "milestone file contains the correct status in the metadata block" "$result"

# (b) manifest status is updated
load_manifest
result=0
status=$(dag_get_status "m01")
[[ "$status" == "in_progress" ]] && result=0 || result=1
assert "emit_milestone_metadata updates manifest status to in_progress (got: '$status')" "$result"

# (c) existing block is replaced rather than duplicated
result=0
emit_milestone_metadata "1" "done" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "emit_milestone_metadata returns 0 on second call (update)" "$result"

result=0
meta_count=$(grep -c '^<!-- milestone-meta' "${MILESTONE_DIR_ABS}/m01-test-feature.md" || true)
[[ "$meta_count" -eq 1 ]] && result=0 || result=1
assert "milestone file has exactly one meta block after replacement (got: $meta_count)" "$result"

result=0
grep -q 'status: "done"' "${MILESTONE_DIR_ABS}/m01-test-feature.md" && result=0 || result=1
assert "milestone file contains updated status 'done' after replacement" "$result"

result=0
grep -q 'status: "in_progress"' "${MILESTONE_DIR_ABS}/m01-test-feature.md" && result=1 || result=0
assert "old status 'in_progress' is removed after meta block replacement" "$result"

# Manifest status updated to done after second call
load_manifest
result=0
status_done=$(dag_get_status "m01")
[[ "$status_done" == "done" ]] && result=0 || result=1
assert "emit_milestone_metadata updates manifest status to done on second call (got: '$status_done')" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
