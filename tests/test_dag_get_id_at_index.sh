#!/usr/bin/env bash
# Test: dag_get_id_at_index() — bounds-checking and valid-index retrieval
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
echo "--- Test: dag_get_id_at_index() with populated manifest ---"

# Create a manifest with 4 milestones
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Feature|pending||m01-first-feature.md|
m02|Second Feature|pending|m01|m02-second-feature.md|
m03|Third Feature|pending|m02|m03-third-feature.md|
m04|Fourth Feature|done|m03|m04-fourth-feature.md|
EOF

# Create all milestone files
for f in m01-first-feature.md m02-second-feature.md m03-third-feature.md m04-fourth-feature.md; do
    echo "#### Milestone stub" > "${MILESTONE_DIR_ABS}/${f}"
done

load_manifest

# Test: Valid index 0 should return m01
result=0
id=$(dag_get_id_at_index 0)
[[ "$id" == "m01" ]] && result=0 || result=1
assert "dag_get_id_at_index 0 returns m01 (got: '$id')" "$result"

# Test: Valid index 1 should return m02
result=0
id=$(dag_get_id_at_index 1)
[[ "$id" == "m02" ]] && result=0 || result=1
assert "dag_get_id_at_index 1 returns m02 (got: '$id')" "$result"

# Test: Valid index 2 should return m03
result=0
id=$(dag_get_id_at_index 2)
[[ "$id" == "m03" ]] && result=0 || result=1
assert "dag_get_id_at_index 2 returns m03 (got: '$id')" "$result"

# Test: Valid index 3 should return m04
result=0
id=$(dag_get_id_at_index 3)
[[ "$id" == "m04" ]] && result=0 || result=1
assert "dag_get_id_at_index 3 returns m04 (got: '$id')" "$result"

# =============================================================================
echo "--- Test: dag_get_id_at_index() bounds checking ---"

# Test: Negative index should return 1 (out of bounds)
result=0
dag_get_id_at_index -1 >/dev/null 2>&1 && result=1 || result=0
assert "dag_get_id_at_index -1 returns error (exit code 1)" "$result"

# Test: Index >= count should return 1
count=$(dag_get_count)
result=0
dag_get_id_at_index "$count" >/dev/null 2>&1 && result=1 || result=0
assert "dag_get_id_at_index $count (beyond array) returns error" "$result"

# Test: Index > count should return 1
result=0
dag_get_id_at_index $((count + 5)) >/dev/null 2>&1 && result=1 || result=0
assert "dag_get_id_at_index $((count + 5)) (far beyond array) returns error" "$result"

# =============================================================================
echo "--- Test: dag_get_id_at_index() edge case: single milestone ---"

# Clear and recreate manifest with just one milestone
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Only Feature|pending||m01-only-feature.md|
EOF

echo "#### Milestone stub" > "${MILESTONE_DIR_ABS}/m01-only-feature.md"

load_manifest

# Test: Index 0 should return m01
result=0
id=$(dag_get_id_at_index 0)
[[ "$id" == "m01" ]] && result=0 || result=1
assert "dag_get_id_at_index 0 with single milestone returns m01 (got: '$id')" "$result"

# Test: Index 1 should fail (out of bounds)
result=0
dag_get_id_at_index 1 >/dev/null 2>&1 && result=1 || result=0
assert "dag_get_id_at_index 1 with single milestone returns error" "$result"

# =============================================================================
echo "--- Test: dag_get_id_at_index() integration with dag_get_count() ---"

# Recreate the 4-milestone manifest
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First Feature|pending||m01-first-feature.md|
m02|Second Feature|pending|m01|m02-second-feature.md|
m03|Third Feature|pending|m02|m03-third-feature.md|
m04|Fourth Feature|done|m03|m04-fourth-feature.md|
EOF

for f in m01-first-feature.md m02-second-feature.md m03-third-feature.md m04-fourth-feature.md; do
    echo "#### Milestone stub" > "${MILESTONE_DIR_ABS}/${f}"
done

load_manifest

count=$(dag_get_count)
result=0
[[ "$count" -eq 4 ]] && result=0 || result=1
assert "dag_get_count returns 4 (got: '$count')" "$result"

# Test: Iterate through all valid indices using dag_get_count as boundary
result=0
for i in $(seq 0 $((count - 1))); do
    if ! dag_get_id_at_index "$i" >/dev/null 2>&1; then
        echo "    ERROR: dag_get_id_at_index $i failed unexpectedly"
        result=1
        break
    fi
done
assert "all indices from 0 to $((count - 1)) are valid and retrievable" "$result"

# Test: Index equal to count should fail
result=0
dag_get_id_at_index "$count" >/dev/null 2>&1 && result=1 || result=0
assert "dag_get_id_at_index $count (equal to count) returns error" "$result"

# =============================================================================
echo "--- Test: dag_get_id_at_index() output format ---"

# Verify that valid output is exactly the ID with no extra characters
result=0
id=$(dag_get_id_at_index 0)
[[ "$id" =~ ^m[0-9]+$ ]] && result=0 || result=1
assert "dag_get_id_at_index output format matches m<number> (got: '$id')" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
