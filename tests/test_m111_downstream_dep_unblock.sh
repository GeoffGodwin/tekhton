#!/usr/bin/env bash
# Test: M111 coverage gap — downstream milestone dep-unblock contract after DAG split
#
# Documents the behavioral contract when a downstream milestone's depends_on
# references a parent that has been marked "split".
#
# Current behavior (known limitation, M111 drift observation):
#   dag_deps_satisfied() requires dep status == "done"; "split" does not satisfy it.
#   _split_apply_dag() does NOT rewrite downstream dep references to the last sub.
#   Therefore a downstream milestone remains permanently blocked even after all
#   sub-milestones complete, because its dep (the parent) is never marked "done".
#
# The fix requires either:
#   (a) _split_apply_dag rewrites downstream dep references from parent_id to last_sub_id
#   (b) dag_deps_satisfied treats "split" as equivalent to "done"
# Option (a) is correct; neither is implemented yet.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

PROJECT_DIR="$TMPDIR"
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
export TEKHTON_HOME PROJECT_DIR TEKHTON_DIR

source "${TEKHTON_HOME}/lib/common.sh"

LOG_DIR="${TMPDIR}/.claude/logs"
PIPELINE_STATE_FILE="${TMPDIR}/.claude/PIPELINE_STATE.md"
MILESTONE_STATE_FILE="${TMPDIR}/.claude/MILESTONE_STATE.md"
MILESTONE_ARCHIVE_FILE="${TMPDIR}/MILESTONE_ARCHIVE.md"
CODER_SUMMARY_FILE="${TMPDIR}/${TEKHTON_DIR}/CODER_SUMMARY.md"
SCOUT_REPORT_FILE="${TMPDIR}/${TEKHTON_DIR}/SCOUT_REPORT.md"
MILESTONE_DAG_ENABLED=true
MILESTONE_DIR=".claude/milestones"
MILESTONE_MANIFEST="MANIFEST.cfg"

export MILESTONE_DAG_ENABLED MILESTONE_DIR MILESTONE_MANIFEST
export MILESTONE_ARCHIVE_FILE CODER_SUMMARY_FILE SCOUT_REPORT_FILE

mkdir -p "${TMPDIR}/.claude" "${LOG_DIR}" "${TMPDIR}/${TEKHTON_DIR}"

source "${TEKHTON_HOME}/lib/state.sh"
run_build_gate() { return 0; }
source "${TEKHTON_HOME}/lib/milestones.sh"
source "${TEKHTON_HOME}/lib/milestone_dag.sh"
source "${TEKHTON_HOME}/lib/milestone_query.sh"
source "${TEKHTON_HOME}/lib/milestone_archival_helpers.sh"
source "${TEKHTON_HOME}/lib/milestone_archival.sh"

render_prompt() { echo "dummy prompt"; return 0; }
_call_planning_batch() {
    printf '#### Milestone 2.1: Sub Task Alpha\nContent alpha.\n\n'
    printf '#### Milestone 2.2: Sub Task Beta\nContent beta.\n\n'
    return 0
}

source "${TEKHTON_HOME}/lib/milestone_split.sh"

cd "$TMPDIR"

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

PASS=0
FAIL=0

assert() {
    local desc="$1" result="$2"
    if [ "$result" = "0" ]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

# rc CMD ARGS... — runs CMD suppressing output, returns its exit code
rc() { local r=0; "$@" > /dev/null 2>&1 || r=$?; return $r; }

# ============================================================================
echo "--- Section 1: m03 blocked immediately after parent is split ---"
# ============================================================================
# Manifest after _split_apply_dag: m02 is "split", m02.1/m02.2 are pending.
# m03's depends_on still references m02 (not rewritten).

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Foundation|done||m01-foundation.md|
m02|Big Feature|split||m02-big-feature.md|
m02.1|Sub Task Alpha|pending||m02.1-sub-alpha.md|
m02.2|Sub Task Beta|pending|m02.1|m02.2-sub-beta.md|
m03|Downstream Feature|pending|m02|m03-downstream.md|
EOF

for f in m01-foundation.md m02-big-feature.md m02.1-sub-alpha.md \
          m02.2-sub-beta.md m03-downstream.md; do
    echo "stub" > "${MILESTONE_DIR_ABS}/${f}"
done

load_manifest
frontier=$(dag_get_frontier)

# m03 depends on m02 which is split — NOT in frontier
result=0; echo "$frontier" | grep -q "^m03$" && result=1 || true
assert "m03 NOT in frontier: dep m02 is 'split', not 'done'" "$result"

# m02.1 (no unmet deps) IS in frontier — sub-milestones can proceed
result=0; echo "$frontier" | grep -q "^m02\.1$" && result=0 || result=1
assert "m02.1 IS in frontier: pending sub-milestone, no unmet deps" "$result"

# dag_deps_satisfied returns false for m03 (dep m02 = split)
result=0; rc dag_deps_satisfied "m03" && result=1 || true
assert "dag_deps_satisfied(m03) returns false: m02 status is 'split'" "$result"

# ============================================================================
echo "--- Section 2: m03 still blocked after m02.1 done ---"
# ============================================================================

dag_set_status "m02.1" "done"
frontier2=$(dag_get_frontier)

result=0; echo "$frontier2" | grep -q "^m03$" && result=1 || true
assert "m03 NOT in frontier after m02.1 done (m02 still 'split')" "$result"

result=0; echo "$frontier2" | grep -q "^m02\.2$" && result=0 || result=1
assert "m02.2 IS in frontier once m02.1 is done" "$result"

# ============================================================================
echo "--- Section 3: m03 permanently blocked after ALL sub-milestones done ---"
# ============================================================================
# This is the core contract: even when m02.1 and m02.2 are both "done",
# m03 cannot enter the frontier because its dep (m02) is "split", not "done".

dag_set_status "m02.2" "done"
frontier3=$(dag_get_frontier)

result=0; echo "$frontier3" | grep -q "^m03$" && result=1 || true
assert "m03 NOT in frontier: dep m02='split' even after both sub-milestones done" "$result"

result=0; rc dag_deps_satisfied "m03" && result=1 || true
assert "dag_deps_satisfied(m03) returns false: m02 must be 'done', not 'split'" "$result"

# ============================================================================
echo "--- Section 4: _split_apply_dag does not rewrite downstream dep refs ---"
# ============================================================================
# Reload a fresh manifest so we can run _split_apply_dag and inspect the result.

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m02|Big Feature|pending||m02-big-feature.md|
m03|Downstream Feature|pending|m02|m03-downstream.md|
EOF

echo "#### Milestone 2: Big Feature" > "${MILESTONE_DIR_ABS}/m02-big-feature.md"
echo "stub" > "${MILESTONE_DIR_ABS}/m03-downstream.md"

load_manifest

MILESTONE_SPLIT_ENABLED=true
MILESTONE_MAX_SPLIT_DEPTH=3
ADJUSTED_CODER_TURNS=200
MILESTONE_SPLIT_THRESHOLD_PCT=120
MILESTONE_SPLIT_MODEL="claude-test-model"
MILESTONE_SPLIT_MAX_TURNS=15

rc split_milestone "2" "${TMPDIR}/CLAUDE.md" || true
load_manifest

# m03's depends_on must still be "m02" — _split_apply_dag does not rewrite it
m03_deps="${_DAG_DEPS[${_DAG_IDX[m03]}]:-MISSING}"
result=0; [[ "$m03_deps" == "m02" ]] && result=0 || result=1
assert "m03 depends_on is still 'm02' after split (not rewritten to last sub)" "$result"

# m02's status must be "split"
m02_status="${_DAG_STATUSES[${_DAG_IDX[m02]}]:-MISSING}"
result=0; [[ "$m02_status" == "split" ]] && result=0 || result=1
assert "m02 status is 'split' after _split_apply_dag" "$result"

# ============================================================================
echo "--- Section 5: marking split parent 'done' manually unblocks m03 ---"
# ============================================================================
# Verifies that dag_deps_satisfied logic is correct in principle — the only
# missing piece is that m02 is never marked "done" after being split.

dag_set_status "m02" "done"
result=0; rc dag_deps_satisfied "m03" && result=0 || result=1
assert "dag_deps_satisfied(m03) returns true when m02 is manually set to 'done'" "$result"

frontier4=$(dag_get_frontier)
result=0; echo "$frontier4" | grep -q "^m03$" && result=0 || result=1
assert "m03 enters frontier when m02 dep is 'done'" "$result"

# ============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
