#!/usr/bin/env bash
# Test: find_next_milestone() DAG-aware ordering
#
# Verifies that find_next_milestone() in milestone_ops.sh uses DAG dependency
# edges (via dag_find_next) when a manifest exists, and falls back to inline
# sequential ordering when no manifest is present.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export TEKHTON_HOME
export PROJECT_DIR="$TMPDIR"

source "${TEKHTON_HOME}/lib/common.sh"

# Config stubs
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
TEST_CMD=""
ANALYZE_CMD=""
LOG_DIR="${TMPDIR}/.claude/logs"
MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_MANIFEST="MANIFEST.cfg"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"

export MILESTONE_MANIFEST MILESTONE_DAG_ENABLED MILESTONE_DIR
export MILESTONE_STATE_FILE

mkdir -p "${TMPDIR}/.claude/logs"

source "${TEKHTON_HOME}/lib/state.sh"

run_build_gate() { return 0; }

source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_dag_helpers.sh"
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

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc — expected '$expected', got '$actual'"
        FAIL=$((FAIL + 1))
    fi
}

_reset_dag() {
    _DAG_IDS=()
    _DAG_TITLES=()
    _DAG_STATUSES=()
    _DAG_DEPS=()
    _DAG_FILES=()
    _DAG_GROUPS=()
    _DAG_IDX=()
    _DAG_LOADED=false
}

# =============================================================================
echo "--- Test: DAG path — linear chain respects sequential order ---"

MILESTONE_DIR_ABS="${TMPDIR}/test1/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"
MILESTONE_DIR="${TMPDIR}/test1/.claude/milestones"
export MILESTONE_DIR

# Write milestone files
cat > "${MILESTONE_DIR_ABS}/m01-first.md" << 'EOF'
#### Milestone 1: First
First milestone.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS}/m02-second.md" << 'EOF'
#### Milestone 2: Second
Second milestone.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS}/m03-third.md" << 'EOF'
#### Milestone 3: Third
Third milestone.

Acceptance criteria:
- Works
EOF

# Manifest: m01 → m02 → m03
cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|done||m01-first.md|
m02|Second|pending|m01|m02-second.md|
m03|Third|pending|m02|m03-third.md|
EOF

_reset_dag
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

# After m01 is done, next should be m02 (number 2)
next=$(find_next_milestone "1" "CLAUDE.md")
assert_eq "DAG linear: after m01 done, next is 2" "2" "$next"

# After m02 is done, next should be m03 (number 3) — mark m02 done first
dag_set_status "m02" "done"
save_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"
_reset_dag
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

next=$(find_next_milestone "2" "CLAUDE.md")
assert_eq "DAG linear: after m02 done, next is 3" "3" "$next"

# After m03 is done, no more milestones
dag_set_status "m03" "done"
save_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"
_reset_dag
load_manifest "${MILESTONE_DIR_ABS}/MANIFEST.cfg"

next=$(find_next_milestone "3" "CLAUDE.md")
assert_eq "DAG linear: after m03 done, next is empty" "" "$next"

# =============================================================================
echo "--- Test: DAG path — dependency not satisfied blocks advancement ---"

MILESTONE_DIR_ABS2="${TMPDIR}/test2/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS2"
MILESTONE_DIR="${TMPDIR}/test2/.claude/milestones"
export MILESTONE_DIR

cat > "${MILESTONE_DIR_ABS2}/m01-alpha.md" << 'EOF'
#### Milestone 1: Alpha
Alpha.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS2}/m02-beta.md" << 'EOF'
#### Milestone 2: Beta
Beta.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS2}/m03-gamma.md" << 'EOF'
#### Milestone 3: Gamma
Gamma depends on both alpha and beta.

Acceptance criteria:
- Works
EOF

# m03 depends on BOTH m01 and m02; m02 is still pending
cat > "${MILESTONE_DIR_ABS2}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Alpha|done||m01-alpha.md|
m02|Beta|pending||m02-beta.md|
m03|Gamma|pending|m01,m02|m03-gamma.md|
EOF

_reset_dag
load_manifest "${MILESTONE_DIR_ABS2}/MANIFEST.cfg"

# m02 is pending, so dag_find_next after m01 should return m02 (which has no deps of its own)
# or nothing if m03's deps aren't satisfied. Let's verify m03 doesn't come up before m02 is done.
next=$(find_next_milestone "1" "CLAUDE.md")
# m02 has no deps and is pending → should be found as frontier
assert_eq "DAG: m02 (no deps, pending) found as next after m01" "2" "$next"

# Now mark m02 done: m03's deps are all satisfied
dag_set_status "m02" "done"
save_manifest "${MILESTONE_DIR_ABS2}/MANIFEST.cfg"
_reset_dag
load_manifest "${MILESTONE_DIR_ABS2}/MANIFEST.cfg"

next=$(find_next_milestone "2" "CLAUDE.md")
assert_eq "DAG: after m02 done, m03 (all deps satisfied) is next" "3" "$next"

# =============================================================================
echo "--- Test: DAG disabled — falls back to inline sequential ordering ---"

MILESTONE_DIR_ABS3="${TMPDIR}/test3/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS3"
MILESTONE_DIR="${TMPDIR}/test3/.claude/milestones"
export MILESTONE_DIR

MILESTONE_DAG_ENABLED=false
export MILESTONE_DAG_ENABLED

# CLAUDE.md with inline milestones (sequential)
cat > "${TMPDIR}/test3_claude.md" << 'EOF'
# Project

### Milestone Plan

#### Milestone 1: Alpha
Alpha.

Acceptance criteria:
- Works

#### [DONE] Milestone 2: Beta
Beta done.

Acceptance criteria:
- Works

#### Milestone 3: Gamma
Gamma.

Acceptance criteria:
- Works
EOF

_reset_dag

# With DAG disabled, find_next_milestone uses inline parse
# After milestone 1, it should skip done milestone 2 and return 3
next=$(find_next_milestone "1" "${TMPDIR}/test3_claude.md")
assert_eq "Inline fallback: after 1, skip done m02, find m03" "3" "$next"

# After milestone 2, return 3
next=$(find_next_milestone "2" "${TMPDIR}/test3_claude.md")
assert_eq "Inline fallback: after 2, find m03" "3" "$next"

# After milestone 3 (last), return empty
next=$(find_next_milestone "3" "${TMPDIR}/test3_claude.md")
assert_eq "Inline fallback: after last milestone, return empty" "" "$next"

MILESTONE_DAG_ENABLED=true
export MILESTONE_DAG_ENABLED

# =============================================================================
echo "--- Test: DAG path — first milestone (no current) returns frontier ---"

# Restore MILESTONE_DIR to test1 (m01 done, m02/m03 pending after m02 was done)
# Use fresh manifest where only m01 is done
MILESTONE_DIR_ABS4="${TMPDIR}/test4/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS4"
MILESTONE_DIR="${TMPDIR}/test4/.claude/milestones"
export MILESTONE_DIR

cat > "${MILESTONE_DIR_ABS4}/m01-first.md" << 'EOF'
#### Milestone 1: First
First.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS4}/m02-second.md" << 'EOF'
#### Milestone 2: Second
Second.

Acceptance criteria:
- Works
EOF

cat > "${MILESTONE_DIR_ABS4}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|First|pending||m01-first.md|
m02|Second|pending|m01|m02-second.md|
EOF

_reset_dag
load_manifest "${MILESTONE_DIR_ABS4}/MANIFEST.cfg"

# find_next_milestone with empty current — dag_number_to_id("") → ""
# dag_find_next("") should return the first frontier milestone
next=$(find_next_milestone "" "CLAUDE.md")
# m01 has no deps so it's the frontier when nothing is done
assert_eq "DAG: with no current, first frontier milestone is 1" "1" "$next"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
