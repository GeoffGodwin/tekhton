#!/usr/bin/env bash
# Test: Milestone DAG infrastructure — manifest parsing, DAG queries,
# frontier detection, cycle detection, migration, status updates
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
export TEKHTON_HOME PROJECT_DIR

source "${TEKHTON_HOME}/lib/common.sh"

# Provide stubs for config values needed by milestones.sh
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}"

MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_AUTO_MIGRATE=true
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST

source "${TEKHTON_HOME}/lib/state.sh"

# Stub run_build_gate
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

# =============================================================================
echo "--- Test: has_milestone_manifest (no manifest) ---"
result=0
has_milestone_manifest && result=1 || result=0
assert "returns 1 when no manifest exists" "$result"

# =============================================================================
echo "--- Test: Manifest parsing ---"

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|DAG Infrastructure|pending||m01-dag-infra.md|foundation
m02|Sliding Window|pending|m01|m02-sliding-window.md|foundation
m03|Indexer Setup|done|m01|m03-indexer-setup.md|indexer
m04|Repo Map Generator|pending|m03|m04-repo-map.md|indexer
EOF

# Create stub milestone files
for f in m01-dag-infra.md m02-sliding-window.md m03-indexer-setup.md m04-repo-map.md; do
    echo "#### Milestone stub" > "${MILESTONE_DIR_ABS}/${f}"
done

echo "--- Test: has_milestone_manifest (with manifest) ---"
result=0
has_milestone_manifest && result=0 || result=1
assert "returns 0 when manifest exists" "$result"

echo "--- Test: load_manifest ---"
result=0
load_manifest && result=0 || result=1
assert "load_manifest succeeds" "$result"

result=0
count=$(dag_get_count)
[[ "$count" -eq 4 ]] && result=0 || result=1
assert "manifest has 4 milestones (got: $count)" "$result"

echo "--- Test: dag_get_status ---"
result=0
status=$(dag_get_status "m01")
[[ "$status" == "pending" ]] && result=0 || result=1
assert "m01 status is pending (got: $status)" "$result"

result=0
status=$(dag_get_status "m03")
[[ "$status" == "done" ]] && result=0 || result=1
assert "m03 status is done (got: $status)" "$result"

echo "--- Test: dag_get_title ---"
result=0
title=$(dag_get_title "m02")
[[ "$title" == "Sliding Window" ]] && result=0 || result=1
assert "m02 title is 'Sliding Window' (got: '$title')" "$result"

echo "--- Test: dag_get_file ---"
result=0
file=$(dag_get_file "m01")
[[ "$file" == "m01-dag-infra.md" ]] && result=0 || result=1
assert "m01 file is m01-dag-infra.md (got: '$file')" "$result"

# =============================================================================
echo "--- Test: dag_deps_satisfied ---"

result=0
dag_deps_satisfied "m01" && result=0 || result=1
assert "m01 (no deps) is satisfied" "$result"

result=0
dag_deps_satisfied "m02" && result=1 || result=0
assert "m02 (depends on pending m01) is NOT satisfied" "$result"

result=0
dag_deps_satisfied "m04" && result=0 || result=1
assert "m04 (depends on done m03) IS satisfied" "$result"

# =============================================================================
echo "--- Test: dag_get_frontier ---"

frontier=$(dag_get_frontier)
result=0
echo "$frontier" | grep -q "m01" && result=0 || result=1
assert "frontier contains m01 (no deps, pending)" "$result"

result=0
echo "$frontier" | grep -q "m04" && result=0 || result=1
assert "frontier contains m04 (dep m03 is done)" "$result"

result=0
echo "$frontier" | grep -q "m02" && result=1 || result=0
assert "frontier does NOT contain m02 (dep m01 not done)" "$result"

result=0
echo "$frontier" | grep -q "m03" && result=1 || result=0
assert "frontier does NOT contain m03 (already done)" "$result"

# =============================================================================
echo "--- Test: dag_find_next ---"

next=$(dag_find_next)
result=0
[[ "$next" == "m01" ]] && result=0 || result=1
assert "dag_find_next (no current) returns m01 (got: $next)" "$result"

next=$(dag_find_next "m01")
result=0
[[ "$next" == "m04" ]] && result=0 || result=1
assert "dag_find_next after m01 returns m04 (got: $next)" "$result"

# =============================================================================
echo "--- Test: dag_set_status + save_manifest roundtrip ---"

dag_set_status "m01" "done"
save_manifest

# Reload and verify
load_manifest
result=0
status=$(dag_get_status "m01")
[[ "$status" == "done" ]] && result=0 || result=1
assert "m01 status is done after save+reload (got: $status)" "$result"

# Now m02 should be in the frontier (its dep m01 is done)
frontier=$(dag_get_frontier)
result=0
echo "$frontier" | grep -q "m02" && result=0 || result=1
assert "m02 now in frontier after m01 marked done" "$result"

# =============================================================================
echo "--- Test: dag_id_to_number ---"

result=0
num=$(dag_id_to_number "m01")
[[ "$num" == "1" ]] && result=0 || result=1
assert "m01 → 1 (got: $num)" "$result"

result=0
num=$(dag_id_to_number "m03")
[[ "$num" == "3" ]] && result=0 || result=1
assert "m03 → 3 (got: $num)" "$result"

echo "--- Test: dag_number_to_id ---"

result=0
id=$(dag_number_to_id "1")
[[ "$id" == "m01" ]] && result=0 || result=1
assert "1 → m01 (got: $id)" "$result"

result=0
id=$(dag_number_to_id "4")
[[ "$id" == "m04" ]] && result=0 || result=1
assert "4 → m04 (got: $id)" "$result"

# =============================================================================
echo "--- Test: validate_manifest (valid) ---"

result=0
validate_manifest && result=0 || result=1
assert "valid manifest passes validation" "$result"

# =============================================================================
echo "--- Test: validate_manifest (missing dep) ---"

# Add a milestone with a nonexistent dependency
_DAG_IDS+=("m99")
_DAG_TITLES+=("Bad Dep")
_DAG_STATUSES+=("pending")
_DAG_DEPS+=("m_nonexistent")
_DAG_FILES+=("")
_DAG_GROUPS+=("")
_DAG_IDX["m99"]=$(( ${#_DAG_IDS[@]} - 1 ))

result=0
validate_manifest 2>/dev/null && result=1 || result=0
assert "manifest with missing dep fails validation" "$result"

# Reload clean manifest
load_manifest

# =============================================================================
echo "--- Test: validate_manifest (circular dep) ---"

# Create a circular manifest
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|pending|m02|m01-dag-infra.md|
m02|Second|pending|m01|m02-sliding-window.md|
EOF

load_manifest
result=0
validate_manifest 2>/dev/null && result=1 || result=0
assert "circular dependency detected" "$result"

# =============================================================================
echo "--- Test: Migration from inline CLAUDE.md ---"

# Restore a clean state
rm -rf "${MILESTONE_DIR_ABS}"
mkdir -p "${MILESTONE_DIR_ABS}"
# Remove manifest to allow migration
rm -f "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

cat > "${TMPDIR}/CLAUDE.md" << 'CLAUDE_EOF'
# Project Rules

## Current Initiative: Test Project

### Milestone Plan

#### Milestone 1: First Feature
Implement the first feature.

Acceptance criteria:
- Feature works correctly
- Tests pass

#### [DONE] Milestone 2: Second Feature
Implement the second feature.

Acceptance criteria:
- Second feature works
- All tests pass

#### Milestone 3: Third Feature
Depends on Milestone 1.

Implement the third feature.

Acceptance criteria:
- Third feature works
CLAUDE_EOF

# Reset DAG state
MILESTONE_DAG_ENABLED=true
_DAG_LOADED=false

result=0
migrate_inline_milestones "${TMPDIR}/CLAUDE.md" "${MILESTONE_DIR_ABS}" && result=0 || result=1
assert "migration succeeds" "$result"

result=0
[[ -f "${MILESTONE_DIR_ABS}/MANIFEST.cfg" ]] && result=0 || result=1
assert "MANIFEST.cfg created" "$result"

# Load and verify
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

result=0
count=$(dag_get_count)
[[ "$count" -eq 3 ]] && result=0 || result=1
assert "3 milestones migrated (got: $count)" "$result"

result=0
status=$(dag_get_status "m02")
[[ "$status" == "done" ]] && result=0 || result=1
assert "m02 status is done (was [DONE] inline)" "$result"

result=0
status=$(dag_get_status "m01")
[[ "$status" == "pending" ]] && result=0 || result=1
assert "m01 status is pending" "$result"

# Check milestone file exists
result=0
file=$(dag_get_file "m01")
[[ -f "${MILESTONE_DIR_ABS}/${file}" ]] && result=0 || result=1
assert "milestone file for m01 exists" "$result"

# Check explicit dependency detection (m03 depends on m01)
result=0
deps="${_DAG_DEPS[${_DAG_IDX[m03]}]}"
[[ "$deps" == *"m01"* ]] && result=0 || result=1
assert "m03 depends on m01 (explicit reference detected, got: '$deps')" "$result"

# =============================================================================
echo "--- Test: Migration idempotency ---"

result=0
migrate_inline_milestones "${TMPDIR}/CLAUDE.md" "${MILESTONE_DIR_ABS}" && result=0 || result=1
assert "re-migration skips (idempotent)" "$result"

# =============================================================================
echo "--- Test: parse_milestones_auto (DAG path) ---"

auto_output=$(parse_milestones_auto "${TMPDIR}/CLAUDE.md")
result=0
echo "$auto_output" | grep -q "1|First Feature" && result=0 || result=1
assert "parse_milestones_auto returns m01 data" "$result"

result=0
echo "$auto_output" | grep -q "3|Third Feature" && result=0 || result=1
assert "parse_milestones_auto returns m03 data" "$result"

# =============================================================================
echo "--- Test: find_next_milestone (DAG-aware) ---"

# m01 is pending with no deps — it's first
next=$(find_next_milestone "0" "${TMPDIR}/CLAUDE.md")
result=0
[[ "$next" == "1" ]] && result=0 || result=1
assert "find_next_milestone returns 1 (got: '$next')" "$result"

# =============================================================================
echo "--- Test: mark_milestone_done (DAG-aware) ---"

mark_milestone_done "1" "${TMPDIR}/CLAUDE.md"
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

result=0
status=$(dag_get_status "m01")
[[ "$status" == "done" ]] && result=0 || result=1
assert "mark_milestone_done updates manifest (got: $status)" "$result"

# =============================================================================
echo "--- Test: Fallback to v2 when DAG disabled ---"

MILESTONE_DAG_ENABLED=false
_DAG_LOADED=false

# is_milestone_done should fall back to CLAUDE.md
result=0
is_milestone_done "2" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "is_milestone_done falls back to inline [DONE] check" "$result"

# find_next_milestone should fall back to inline
next=$(find_next_milestone "1" "${TMPDIR}/CLAUDE.md")
result=0
[[ "$next" == "3" ]] && result=0 || result=1
assert "find_next_milestone falls back to inline (got: '$next')" "$result"

# Restore
MILESTONE_DAG_ENABLED=true

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
