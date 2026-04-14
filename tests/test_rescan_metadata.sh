#!/usr/bin/env bash
# Test: M67 — _record_scan_metadata reads file_count/total_lines from inventory.jsonl
#       (spec §12 fix), and rescan_project full-crawl fallback correctly updates
#       meta.json when .claude/index/ already exists from a prior M67 crawl.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
TEKHTON_SESSION_DIR="$TEST_TMPDIR"
export TEKHTON_SESSION_DIR
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions required by sourced libraries
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# M84: Variable defaults (normally set by common.sh / config_defaults.sh)
: "${TEKHTON_DIR:=.tekhton}"
: "${SCOUT_REPORT_FILE:=${TEKHTON_DIR}/SCOUT_REPORT.md}"
: "${ARCHITECT_PLAN_FILE:=${TEKHTON_DIR}/ARCHITECT_PLAN.md}"
: "${CLEANUP_REPORT_FILE:=${TEKHTON_DIR}/CLEANUP_REPORT.md}"
: "${DRIFT_ARCHIVE_FILE:=${TEKHTON_DIR}/DRIFT_ARCHIVE.md}"
: "${PROJECT_INDEX_FILE:=${TEKHTON_DIR}/PROJECT_INDEX.md}"
: "${REPLAN_DELTA_FILE:=${TEKHTON_DIR}/REPLAN_DELTA.md}"
: "${MERGE_CONTEXT_FILE:=${TEKHTON_DIR}/MERGE_CONTEXT.md}"
: "${DESIGN_FILE:=${TEKHTON_DIR}/DESIGN.md}"

# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"
# shellcheck source=../lib/index_reader.sh
source "${TEKHTON_HOME}/lib/index_reader.sh"
# shellcheck source=../lib/index_view.sh
source "${TEKHTON_HOME}/lib/index_view.sh"
# shellcheck source=../lib/rescan.sh
source "${TEKHTON_HOME}/lib/rescan.sh"

# Helper: extract a numeric field from meta.json
# Args: $1=field_name, $2=meta.json_path
_meta_field() {
    local field="$1" path="$2"
    awk -F"\"${field}\":" 'NF>1{split($2,a,/[,}]/); gsub(/[^0-9]/,"",a[1]); print a[1]}' \
        "$path" 2>/dev/null || echo "0"
}

# =============================================================================
# Section 1: _record_scan_metadata reads file_count / total_lines from inventory.jsonl
#            NOT via per-file wc -l (spec §12 fix)
# =============================================================================
echo "=== _record_scan_metadata reads from inventory.jsonl (not per-file wc -l) ==="

PROJ1="${TEST_TMPDIR}/meta_from_jsonl"
mkdir -p "${PROJ1}/.claude/index"
git -C "$PROJ1" init -q
git -C "$PROJ1" config user.email "test@test"
git -C "$PROJ1" config user.name "Test"

# Actual project: 1 committed file with exactly 3 lines
printf 'line1\nline2\nline3\n' > "${PROJ1}/real.sh"
git -C "$PROJ1" add -A && git -C "$PROJ1" commit -q -m "init"

# inventory.jsonl: claims 2 files with 100 + 200 = 300 lines
# Deliberately contradicts actual file content (1 file, 3 lines) to expose which
# code path _record_scan_metadata takes.
printf '{"path":"real.sh","dir":".","lines":100,"size":"small"}\n' \
    > "${PROJ1}/.claude/index/inventory.jsonl"
printf '{"path":"phantom.sh","dir":".","lines":200,"size":"small"}\n' \
    >> "${PROJ1}/.claude/index/inventory.jsonl"

# tree.txt required for tree_lines computation
printf 'root\n  real.sh\n  phantom.sh\n' > "${PROJ1}/.claude/index/tree.txt"

# meta.json with zeroed placeholder values (will be overwritten by _record_scan_metadata)
printf '{\n  "schema_version": 1,\n  "project_name": "meta_from_jsonl",\n  "scan_date": "2025-01-01T00:00:00Z",\n  "scan_commit": "000000",\n  "file_count": 0,\n  "total_lines": 0,\n  "tree_lines": 0,\n  "doc_quality_score": 0\n}\n' \
    > "${PROJ1}/.claude/index/meta.json"

# PROJECT_INDEX.md with the replaceable HTML comment placeholders that
# _record_scan_metadata rewrites via sed -i
cat > "${PROJ1}/PROJECT_INDEX.md" << 'INDEXEOF'
# PROJECT_INDEX.md — meta_from_jsonl

<!-- Last-Scan: 2025-01-01T00:00:00Z -->
<!-- Scan-Commit: 000000 -->
<!-- File-Count: 0 -->
<!-- Total-Lines: 0 -->

**Project:** meta_from_jsonl
**Scanned:** 2025-01-01T00:00:00Z
**Files:** 0 | **Lines:** 0
INDEXEOF

_record_scan_metadata "${PROJ1}/PROJECT_INDEX.md" "$PROJ1"

# meta.json file_count must be 2 (inventory.jsonl has 2 lines), NOT 1 (actual git-tracked file)
meta_fc=$(_meta_field "file_count" "${PROJ1}/.claude/index/meta.json")
if [[ "$meta_fc" == "2" ]]; then
    pass "meta.json file_count=2 from inventory.jsonl line count (actual git-tracked count is 1)"
else
    fail "meta.json file_count=${meta_fc}, expected 2 from inventory.jsonl (not per-file scan)"
fi

# meta.json total_lines must be 300 (100+200 from JSONL), NOT 3 (actual wc -l of real.sh)
meta_tl=$(_meta_field "total_lines" "${PROJ1}/.claude/index/meta.json")
if [[ "$meta_tl" == "300" ]]; then
    pass "meta.json total_lines=300 from inventory.jsonl sum (actual file has 3 lines)"
else
    fail "meta.json total_lines=${meta_tl}, expected 300 from inventory.jsonl (not per-file wc -l)"
fi

# M69: _record_scan_metadata only updates meta.json now.
# PROJECT_INDEX.md HTML comments are rendered by the view generator.
# Verify meta.json has correct scan_commit (proves _emit_meta_json was called)
meta_sc=$(grep '"scan_commit"' "${PROJ1}/.claude/index/meta.json" | \
    sed 's/.*"scan_commit": *"\([^"]*\)".*/\1/' | tr -d '[:space:]')
expected_commit=$(git -C "$PROJ1" rev-parse --short HEAD 2>/dev/null)
if [[ "$meta_sc" == "$expected_commit" ]]; then
    pass "meta.json scan_commit updated to HEAD (${meta_sc})"
else
    fail "meta.json scan_commit=${meta_sc}, expected ${expected_commit}"
fi

# meta.json scan_date should be updated (not the stale 2025 date)
meta_sd=$(grep '"scan_date"' "${PROJ1}/.claude/index/meta.json" | \
    sed 's/.*"scan_date": *"\([^"]*\)".*/\1/' | tr -d '[:space:]')
if [[ "$meta_sd" != "2025-01-01T00:00:00Z" ]]; then
    pass "meta.json scan_date updated from stale value"
else
    fail "meta.json scan_date still stale (2025-01-01T00:00:00Z)"
fi

# =============================================================================
# Section 2: _record_scan_metadata fallback — no inventory.jsonl present
# =============================================================================
echo "=== _record_scan_metadata fallback path (no inventory.jsonl) ==="

PROJ2="${TEST_TMPDIR}/meta_fallback"
mkdir -p "${PROJ2}/.claude/index"
git -C "$PROJ2" init -q
git -C "$PROJ2" config user.email "test@test"
git -C "$PROJ2" config user.name "Test"

# 2 committed files, 5 lines each
printf 'a\nb\nc\nd\ne\n' > "${PROJ2}/file1.sh"
printf 'f\ng\nh\ni\nj\n' > "${PROJ2}/file2.sh"
git -C "$PROJ2" add -A && git -C "$PROJ2" commit -q -m "init"

# No inventory.jsonl — forces fallback path in _record_scan_metadata
printf 'root\n  file1.sh\n  file2.sh\n' > "${PROJ2}/.claude/index/tree.txt"

# meta.json with stale values — should be overwritten
printf '{\n  "schema_version": 1,\n  "project_name": "meta_fallback",\n  "scan_date": "2025-01-01T00:00:00Z",\n  "scan_commit": "000000",\n  "file_count": 99,\n  "total_lines": 999,\n  "tree_lines": 0,\n  "doc_quality_score": 0\n}\n' \
    > "${PROJ2}/.claude/index/meta.json"

cat > "${PROJ2}/PROJECT_INDEX.md" << 'INDEXEOF'
# PROJECT_INDEX.md — meta_fallback

<!-- Last-Scan: 2025-01-01T00:00:00Z -->
<!-- Scan-Commit: 000000 -->
<!-- File-Count: 99 -->
<!-- Total-Lines: 999 -->

**Project:** meta_fallback
**Scanned:** 2025-01-01T00:00:00Z
**Files:** 99 | **Lines:** 999
INDEXEOF

_record_scan_metadata "${PROJ2}/PROJECT_INDEX.md" "$PROJ2"
pass "_record_scan_metadata completes without crash when inventory.jsonl absent"

# M69: _record_scan_metadata delegates to _emit_meta_json which reads from
# inventory.jsonl.  Without inventory.jsonl, file_count and total_lines are 0
# (the old git ls-files fallback was removed).  Key test: stale value (99) is
# overwritten, proving _emit_meta_json was called.
meta_fc2=$(_meta_field "file_count" "${PROJ2}/.claude/index/meta.json")
if [[ "$meta_fc2" == "0" ]]; then
    pass "fallback path: meta.json file_count=0 (no inventory.jsonl, stale 99 overwritten)"
else
    fail "fallback path: meta.json file_count=${meta_fc2}, expected 0 (no inventory.jsonl)"
fi

meta_tl2=$(_meta_field "total_lines" "${PROJ2}/.claude/index/meta.json")
if [[ "$meta_tl2" == "0" ]]; then
    pass "fallback path: meta.json total_lines=0 (no inventory.jsonl, stale 999 overwritten)"
else
    fail "fallback path: meta.json total_lines=${meta_tl2}, expected 0 (no inventory.jsonl)"
fi

# =============================================================================
# Section 3: rescan_project full-crawl fallback after M67 structured files exist
#            ensures meta.json is correctly updated on subsequent rescans
# =============================================================================
echo "=== rescan_project full-crawl fallback updates meta.json after M67 index exists ==="

PROJ3="${TEST_TMPDIR}/rescan_fullcrawl"
mkdir -p "${PROJ3}/src" "${PROJ3}/.claude"
git -C "$PROJ3" init -q
git -C "$PROJ3" config user.email "test@test"
git -C "$PROJ3" config user.name "Test"

# Initial state: 4 tracked files
printf 'function a() { return 0; }\n' > "${PROJ3}/src/a.sh"
printf 'function b() { return 0; }\n' > "${PROJ3}/src/b.sh"
printf 'function c() { return 0; }\n' > "${PROJ3}/src/c.sh"
printf '# Test Project\nDescription here.\n' > "${PROJ3}/README.md"
git -C "$PROJ3" add -A && git -C "$PROJ3" commit -q -m "initial commit"

# Run initial crawl — creates .claude/index/ with meta.json, inventory.jsonl, etc.
crawl_project "$PROJ3" 120000

initial_fc=$(_meta_field "file_count" "${PROJ3}/.claude/index/meta.json")
if [[ "$initial_fc" -ge 1 ]]; then
    pass "initial crawl_project creates meta.json with file_count=${initial_fc}"
else
    fail "initial crawl_project meta.json file_count=${initial_fc}, expected >= 1"
fi

# inventory.jsonl line count must match meta.json file_count after initial crawl
initial_inv_lines=$(wc -l < "${PROJ3}/.claude/index/inventory.jsonl" | tr -d '[:space:]')
if [[ "$initial_inv_lines" == "$initial_fc" ]]; then
    pass "initial: inventory.jsonl line count (${initial_inv_lines}) matches meta.json file_count"
else
    fail "initial: inventory.jsonl lines (${initial_inv_lines}) != meta.json file_count (${initial_fc})"
fi

# Add 3 more source files and commit
printf 'function d() { return 0; }\n' > "${PROJ3}/src/d.sh"
printf 'function e() { return 0; }\n' > "${PROJ3}/src/e.sh"
printf 'function f() { return 0; }\n' > "${PROJ3}/src/f.sh"
git -C "$PROJ3" add -A && git -C "$PROJ3" commit -q -m "add three more files"
new_head=$(git -C "$PROJ3" rev-parse --short HEAD 2>/dev/null)

# Force full-crawl rescan — exercises the path where .claude/index/ already exists
# and must be fully refreshed
rescan_project "$PROJ3" 120000 "full"

# meta.json file_count must have increased by at least 3
new_fc=$(_meta_field "file_count" "${PROJ3}/.claude/index/meta.json")
expected_min=$(( initial_fc + 3 ))
if [[ "$new_fc" -ge "$expected_min" ]]; then
    pass "after full-crawl rescan, meta.json file_count=${new_fc} (initial=${initial_fc}, added 3)"
else
    fail "meta.json file_count=${new_fc} after rescan, expected >= ${expected_min}"
fi

# meta.json scan_commit must be updated to the new HEAD commit
meta_commit=$(grep '"scan_commit"' "${PROJ3}/.claude/index/meta.json" | \
    sed 's/.*"scan_commit": *"\([^"]*\)".*/\1/' | tr -d '[:space:]')
if [[ "$meta_commit" == "$new_head" ]]; then
    pass "meta.json scan_commit=${meta_commit} updated to new HEAD after full-crawl rescan"
else
    fail "meta.json scan_commit=${meta_commit}, expected ${new_head}"
fi

# inventory.jsonl line count must match updated meta.json file_count
new_inv_lines=$(wc -l < "${PROJ3}/.claude/index/inventory.jsonl" | tr -d '[:space:]')
if [[ "$new_inv_lines" == "$new_fc" ]]; then
    pass "inventory.jsonl line count (${new_inv_lines}) matches meta.json file_count (${new_fc}) after rescan"
else
    fail "inventory.jsonl lines (${new_inv_lines}) != meta.json file_count (${new_fc}) after rescan"
fi

# meta.json total_lines must match inventory.jsonl lines field sum (proves _emit_meta_json
# reads from inventory.jsonl, not per-file wc -l, after the full-crawl rescan)
inv_total=$(awk -F'"lines":' '{split($2,a,/[,}]/); s+=a[1]} END {print s+0}' \
    "${PROJ3}/.claude/index/inventory.jsonl")
meta_tl3=$(_meta_field "total_lines" "${PROJ3}/.claude/index/meta.json")
if [[ "$meta_tl3" == "$inv_total" ]]; then
    pass "meta.json total_lines=${meta_tl3} matches inventory.jsonl lines sum after rescan"
else
    fail "meta.json total_lines=${meta_tl3} != inventory.jsonl sum=${inv_total} after rescan"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "--------------------------------------------"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "--------------------------------------------"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
