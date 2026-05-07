#!/usr/bin/env bash
# Test: M111 bug-fix verification
#   Bug 3 — dag_get_frontier() must skip "split" milestones (same as "done")
#   Bug 2 — sub-milestones must be inserted immediately after parent in manifest
#   Nullrun — handle_null_run_split() must detect substantive partial work before splitting
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
TEST_CMD=""
ANALYZE_CMD=""

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

# Stubs must exist before sourcing milestone_split.sh (declare -f check at call time,
# but _call_planning_batch is checked before invoke, so define here for safety)
render_prompt() { echo "dummy prompt"; return 0; }
_call_planning_batch() {
    cat << 'SPLIT_OUTPUT'
#### Milestone 1.1: Sub Task Alpha
Implement the alpha portion of the big feature.

Acceptance criteria:
- Alpha works correctly

#### Milestone 1.2: Sub Task Beta
Implement the beta portion of the big feature.

Acceptance criteria:
- Beta works correctly
SPLIT_OUTPUT
    return 0
}

source "${TEKHTON_HOME}/lib/milestone_split.sh"

cd "$TMPDIR"

MILESTONE_DIR_ABS="${TMPDIR}/.claude/milestones"
mkdir -p "$MILESTONE_DIR_ABS"

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

# rc CMD ARGS... — runs CMD suppressing all output, returns exit code
rc() {
    local _r=0
    "$@" > /dev/null 2>&1 || _r=$?
    return $_r
}

# =============================================================================
echo "--- Test: dag_get_frontier() skips 'split' status (Bug 3 fix) ---"
# =============================================================================
# Before Bug 3 fix: dag_get_frontier() only skipped "done" milestones.
# A "split" parent would re-enter the frontier, causing an infinite loop.
# After fix: "split" is treated as terminal (same as "done") in frontier logic.

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Done Feature|done||m01-done.md|
m02|Split Feature|split||m02-split.md|
m01.1|Sub Task Alpha|pending||m01.1-sub-alpha.md|
m01.2|Sub Task Beta|pending|m01.1|m01.2-sub-beta.md|
m03|Downstream After Split|pending|m02|m03-downstream.md|
m04|Independent Pending|pending||m04-independent.md|
EOF

for f in m01-done.md m02-split.md m01.1-sub-alpha.md m01.2-sub-beta.md m03-downstream.md m04-independent.md; do
    echo "stub" > "${MILESTONE_DIR_ABS}/${f}"
done

load_manifest
frontier=$(dag_get_frontier)

result=0; echo "$frontier" | grep -q "m02"     && result=1 || true
assert "dag_get_frontier: 'split' milestone m02 NOT in frontier (Bug 3 fix)" "$result"

result=0; echo "$frontier" | grep -qE "^m01$"  && result=1 || true
assert "dag_get_frontier: 'done' milestone m01 NOT in frontier" "$result"

# m03 depends on m02 (split ≠ done) — dep not satisfied → blocked
result=0; echo "$frontier" | grep -q "m03"     && result=1 || true
assert "dag_get_frontier: m03 NOT in frontier (dep m02 is 'split', not 'done')" "$result"

# m04 is pending with no deps — IS in frontier
result=0; echo "$frontier" | grep -q "m04"     && result=0 || result=1
assert "dag_get_frontier: m04 IS in frontier (pending, no deps)" "$result"

# m01.1 is pending with no deps — IS in frontier (sub-milestone replaces split parent)
result=0; echo "$frontier" | grep -q "m01\.1"  && result=0 || result=1
assert "dag_get_frontier: m01.1 IS in frontier (pending sub-milestone, no unmet deps)" "$result"

# m01.2 depends on m01.1 (pending) — NOT in frontier
result=0; echo "$frontier" | grep -q "m01\.2"  && result=1 || true
assert "dag_get_frontier: m01.2 NOT in frontier (dep m01.1 pending)" "$result"

# Sanity: once m01.1 is marked done, m01.2 enters frontier
dag_set_status "m01.1" "done"
frontier2=$(dag_get_frontier)
result=0; echo "$frontier2" | grep -q "m01\.2" && result=0 || result=1
assert "dag_get_frontier: m01.2 enters frontier once m01.1 is done" "$result"

result=0; echo "$frontier2" | grep -q "m01\.1" && result=1 || true
assert "dag_get_frontier: m01.1 no longer in frontier after being marked done" "$result"

# =============================================================================
echo "--- Test: sub-milestone insertion position (Bug 2 fix) ---"
# =============================================================================
# Before Bug 2 fix: _split_apply_dag appended sub-milestones at end of arrays.
# After fix: sub-milestones are spliced immediately after parent's position.

cat > "${MILESTONE_DIR_ABS}/MANIFEST.cfg" << 'EOF'
# Tekhton Milestone Manifest v1
# id|title|status|depends_on|file|parallel_group
m01|Big Feature|pending||m01-big-feature.md|
m02|Downstream Feature|pending|m01|m02-downstream.md|
EOF

echo "#### Milestone 1: Big Feature" > "${MILESTONE_DIR_ABS}/m01-big-feature.md"
echo "stub" > "${MILESTONE_DIR_ABS}/m02-downstream.md"

load_manifest

MILESTONE_SPLIT_ENABLED=true
MILESTONE_MAX_SPLIT_DEPTH=3
ADJUSTED_CODER_TURNS=200
MILESTONE_SPLIT_THRESHOLD_PCT=120
MILESTONE_SPLIT_MODEL="claude-test-model"
MILESTONE_SPLIT_MAX_TURNS=15

result=0; rc split_milestone "1" "${TMPDIR}/CLAUDE.md" && result=0 || result=1
assert "split_milestone succeeds with 2-entry manifest (m01 + m02)" "$result"

load_manifest  # reload from the atomically saved manifest

count=$(dag_get_count)
result=0; [[ "$count" -eq 4 ]] && result=0 || result=1
assert "manifest has exactly 4 entries after split: m01, m01.1, m01.2, m02 (got: $count)" "$result"

idx_01="${_DAG_IDX[m01]:-MISSING}"
idx_01_1="${_DAG_IDX[m01.1]:-MISSING}"
idx_01_2="${_DAG_IDX[m01.2]:-MISSING}"
idx_02="${_DAG_IDX[m02]:-MISSING}"

result=0; [[ "$idx_01" == "0" ]] && result=0 || result=1
assert "m01 is at array index 0 (got: $idx_01)" "$result"

result=0; [[ "$idx_01_1" == "1" ]] && result=0 || result=1
assert "m01.1 is at index 1 — immediately after parent m01, not appended at end (got: $idx_01_1)" "$result"

result=0; [[ "$idx_01_2" == "2" ]] && result=0 || result=1
assert "m01.2 is at index 2 (got: $idx_01_2)" "$result"

result=0; [[ "$idx_02" == "3" ]] && result=0 || result=1
assert "m02 is at index 3 — pushed back by inserted sub-milestones (got: $idx_02)" "$result"

# Verify order in the written MANIFEST.cfg file on disk
line_01_1=$(grep -n "^m01\.1|" "${MILESTONE_DIR_ABS}/MANIFEST.cfg" | cut -d: -f1)
line_01_2=$(grep -n "^m01\.2|" "${MILESTONE_DIR_ABS}/MANIFEST.cfg" | cut -d: -f1)
line_02=$(grep -n "^m02|" "${MILESTONE_DIR_ABS}/MANIFEST.cfg" | cut -d: -f1)

result=0; [[ "$line_01_1" -lt "$line_02" ]] && result=0 || result=1
assert "MANIFEST.cfg: m01.1 (line $line_01_1) appears before m02 (line $line_02)" "$result"

result=0; [[ "$line_01_2" -lt "$line_02" ]] && result=0 || result=1
assert "MANIFEST.cfg: m01.2 (line $line_01_2) appears before m02 (line $line_02)" "$result"

result=0; [[ "$line_01_1" -lt "$line_01_2" ]] && result=0 || result=1
assert "MANIFEST.cfg: m01.1 appears before m01.2" "$result"

# =============================================================================
echo "--- Test: handle_null_run_split() substantive work detection ---"
# =============================================================================
# The function guards against splitting when the coder already made progress:
# if git diff shows changes AND CODER_SUMMARY_FILE has > 20 lines, it preserves
# the partial work for resume rather than splitting.

MILESTONE_AUTO_RETRY=true
MILESTONE_SPLIT_ENABLED=true
MILESTONE_MAX_SPLIT_DEPTH=3
rm -f "${TMPDIR}/.claude/milestone_attempts.log"

# Stub split_milestone to always succeed — we test the guard logic, not splitting
split_milestone() { return 0; }

# Path A: git changes + summary > 20 lines → substantive work → preserve (return 1)
git() {
    case "$1 $2" in
        "diff --quiet")  return 1 ;;
        "diff --cached") return 1 ;;
        "diff --stat")   echo "5 files changed, 100 insertions(+), 0 deletions(-)" ;;
        *)               command git "$@" 2>/dev/null || true ;;
    esac
}
printf 'summary line %d\n' $(seq 1 25) > "${CODER_SUMMARY_FILE}"

r=0; rc handle_null_run_split "5" "${TMPDIR}/CLAUDE.md" || r=$?
result=0; [[ "$r" -ne 0 ]] && result=0 || result=1
assert "Path A: git changes + 25-line summary → preserve, return 1 (no split)" "$result"

# Path B: no git changes → no substantive work → proceeds to split (return 0)
git() {
    case "$1 $2" in
        "diff --quiet")  return 0 ;;
        "diff --cached") return 0 ;;
        *)               command git "$@" 2>/dev/null || true ;;
    esac
}
: > "${CODER_SUMMARY_FILE}"

r=0; rc handle_null_run_split "5" "${TMPDIR}/CLAUDE.md" || r=$?
result=0; [[ "$r" -eq 0 ]] && result=0 || result=1
assert "Path B: no git changes + empty summary → proceeds to split, return 0" "$result"

# Path C: git changes + summary ≤ 20 lines → no substantive work → split proceeds
git() {
    case "$1 $2" in
        "diff --quiet")  return 1 ;;
        "diff --cached") return 1 ;;
        "diff --stat")   echo "3 files changed, 20 insertions(+)" ;;
        *)               command git "$@" 2>/dev/null || true ;;
    esac
}
printf 'line %d\n' $(seq 1 10) > "${CODER_SUMMARY_FILE}"

r=0; rc handle_null_run_split "5" "${TMPDIR}/CLAUDE.md" || r=$?
result=0; [[ "$r" -eq 0 ]] && result=0 || result=1
assert "Path C: git changes + 10-line summary (≤ 20) → proceeds to split, return 0" "$result"

# Path D: git changes + summary exactly 20 lines (boundary: NOT > 20) → split proceeds
printf 'line %d\n' $(seq 1 20) > "${CODER_SUMMARY_FILE}"

r=0; rc handle_null_run_split "5" "${TMPDIR}/CLAUDE.md" || r=$?
result=0; [[ "$r" -eq 0 ]] && result=0 || result=1
assert "Path D: git changes + exactly 20 lines (boundary, not > 20) → split proceeds" "$result"

# Path E: git changes + summary = 21 lines (just over boundary) → substantive → preserve
git() {
    case "$1 $2" in
        "diff --quiet")  return 1 ;;
        "diff --cached") return 1 ;;
        "diff --stat")   echo "3 files changed, 30 insertions(+)" ;;
        *)               command git "$@" 2>/dev/null || true ;;
    esac
}
printf 'line %d\n' $(seq 1 21) > "${CODER_SUMMARY_FILE}"

r=0; rc handle_null_run_split "5" "${TMPDIR}/CLAUDE.md" || r=$?
result=0; [[ "$r" -ne 0 ]] && result=0 || result=1
assert "Path E: git changes + 21 lines (just over boundary) → preserve, return 1" "$result"

# =============================================================================
echo
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
