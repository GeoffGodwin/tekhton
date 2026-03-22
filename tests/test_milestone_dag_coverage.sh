#!/usr/bin/env bash
# Test: Milestone DAG coverage gaps —
#   1. validate_manifest() missing-file branch
#   2. dag_get_active() in_progress status path
#   3. split_milestone() DAG path
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
source "${TEKHTON_HOME}/lib/milestone_dag_migrate.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"
source "${TEKHTON_HOME}/lib/milestone_ops.sh"

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
echo "--- Test: validate_manifest() missing-file branch ---"

# Manifest has m01 (file exists) and m02 (file does NOT exist)
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Feature|pending||m01-first-feature.md|
m02|Second Feature|pending|m01|m02-missing-file.md|
EOF

# Create only m01's file — m02's file intentionally absent
echo "#### Milestone 1: First Feature" > "${MILESTONE_DIR_ABS}/m01-first-feature.md"

load_manifest

result=0
validate_manifest 2>/dev/null && result=1 || result=0
assert "validate_manifest returns non-zero when a milestone file is missing" "$result"

# Confirm the valid entry (m01 has its file) is not falsely flagged —
# validation should report exactly 1 error (missing m02 file)
error_count=$(validate_manifest 2>&1 1>/dev/null | grep -c "does not exist" || true)
result=0
[[ "$error_count" -eq 1 ]] && result=0 || result=1
assert "validate_manifest reports exactly 1 missing-file error (got: $error_count)" "$result"

# A manifest where ALL files exist must still pass
echo "#### Milestone 2: Second Feature" > "${MILESTONE_DIR_ABS}/m02-missing-file.md"
result=0
validate_manifest 2>/dev/null && result=0 || result=1
assert "validate_manifest passes when all referenced files exist" "$result"

# =============================================================================
echo "--- Test: dag_get_active() in_progress status path ---"

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Feature|done||m01-first-feature.md|
m02|Second Feature|in_progress|m01|m02-second-feature.md|
m03|Third Feature|pending|m02|m03-third-feature.md|
EOF

for f in m01-first-feature.md m02-second-feature.md m03-third-feature.md; do
    echo "#### Milestone stub" > "${MILESTONE_DIR_ABS}/${f}"
done

load_manifest

active=$(dag_get_active)

result=0
[[ "$active" == "m02" ]] && result=0 || result=1
assert "dag_get_active returns the in_progress milestone (got: '$active')" "$result"

result=0
echo "$active" | grep -q "m01" && result=1 || result=0
assert "dag_get_active does NOT return done milestone m01" "$result"

result=0
echo "$active" | grep -q "m03" && result=1 || result=0
assert "dag_get_active does NOT return pending milestone m03" "$result"

# Test: multiple in_progress milestones are all returned
dag_set_status "m03" "in_progress"
active_multi=$(dag_get_active)
result=0
echo "$active_multi" | grep -q "m02" && result=0 || result=1
assert "dag_get_active returns m02 when multiple in_progress" "$result"
result=0
echo "$active_multi" | grep -q "m03" && result=0 || result=1
assert "dag_get_active returns m03 when multiple in_progress" "$result"

# Test: no in_progress milestones → output is empty
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Feature|done||m01-first-feature.md|
m02|Second Feature|pending|m01|m02-second-feature.md|
EOF

load_manifest
active_none=$(dag_get_active)
result=0
[[ -z "$active_none" ]] && result=0 || result=1
assert "dag_get_active returns empty output when no in_progress milestones" "$result"

# =============================================================================
echo "--- Test: split_milestone() DAG path ---"

# Reset: set up a manifest with a single pending milestone
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Big Feature|pending||m01-big-feature.md|
EOF

echo "#### Milestone 1: Big Feature" > "${MILESTONE_DIR_ABS}/m01-big-feature.md"
echo "This is a large milestone that needs splitting." >> "${MILESTONE_DIR_ABS}/m01-big-feature.md"

# CLAUDE.md with milestone 1 block (needed by _extract_milestone_block)
cat > "${TMPDIR}/CLAUDE.md" << 'EOF'
# Project

## Milestone Plan

#### Milestone 1: Big Feature
This is a large milestone that needs splitting.

Acceptance criteria:
- Works correctly
EOF

load_manifest

# Stub render_prompt so split_milestone does not try to read prompt templates
render_prompt() { echo "dummy split prompt"; return 0; }

# Stub _call_planning_batch to return synthetic split output with 2 sub-milestones
_call_planning_batch() {
    cat << 'SPLIT_OUTPUT'
#### Milestone 1.1: Sub Task Alpha
Implement the alpha portion of the big feature.

Acceptance criteria:
- Alpha works

#### Milestone 1.2: Sub Task Beta
Implement the beta portion of the big feature.

Acceptance criteria:
- Beta works
SPLIT_OUTPUT
    return 0
}

# Source milestone_split.sh after stubs are defined (bash resolves at call time,
# but _call_planning_batch stub must exist before the declare -f check inside
# split_milestone runs, so defining it here is sufficient)
source "${TEKHTON_HOME}/lib/milestone_split.sh"

MILESTONE_SPLIT_ENABLED=true
MILESTONE_MAX_SPLIT_DEPTH=3
ADJUSTED_CODER_TURNS=200
MILESTONE_SPLIT_THRESHOLD_PCT=120
MILESTONE_SPLIT_MODEL="claude-test-model"
MILESTONE_SPLIT_MAX_TURNS=15

result=0
split_milestone "1" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "split_milestone succeeds in DAG mode" "$result"

# Reload manifest from disk to verify the atomic save
load_manifest

result=0
parent_status=$(dag_get_status "m01")
[[ "$parent_status" == "split" ]] && result=0 || result=1
assert "parent m01 status is 'split' after DAG split (got: '$parent_status')" "$result"

# Verify sub-milestone files were created in the milestone directory
result=0
ls "${MILESTONE_DIR_ABS}"/m01.1-*.md 2>/dev/null | grep -q . && result=0 || result=1
assert "sub-milestone file for 1.1 created in milestone_dir" "$result"

result=0
ls "${MILESTONE_DIR_ABS}"/m01.2-*.md 2>/dev/null | grep -q . && result=0 || result=1
assert "sub-milestone file for 1.2 created in milestone_dir" "$result"

# Verify manifest has 3 entries (m01 + m01.1 + m01.2)
result=0
count=$(dag_get_count)
[[ "$count" -ge 3 ]] && result=0 || result=1
assert "manifest has at least 3 entries after split (got: $count)" "$result"

# Verify sub-milestones exist and have correct statuses
result=0
status_11=$(dag_get_status "m01.1" 2>/dev/null || echo "MISSING")
[[ "$status_11" == "pending" ]] && result=0 || result=1
assert "m01.1 has pending status after split (got: '$status_11')" "$result"

result=0
status_12=$(dag_get_status "m01.2" 2>/dev/null || echo "MISSING")
[[ "$status_12" == "pending" ]] && result=0 || result=1
assert "m01.2 has pending status after split (got: '$status_12')" "$result"

# Verify chained dependency: m01.2 should depend on m01.1
result=0
deps_12="${_DAG_DEPS[${_DAG_IDX[m01.2]}]:-MISSING}"
[[ "$deps_12" == *"m01.1"* ]] && result=0 || result=1
assert "m01.2 depends on m01.1 (got: '$deps_12')" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
