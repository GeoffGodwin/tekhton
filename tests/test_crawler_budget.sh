#!/usr/bin/env bash
# Test: _budget_allocator surplus redistribution and view generator budget compliance
# M69: _truncate_section removed; view generator tests added
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
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

# Source detect.sh for _DETECT_EXCLUDE_DIRS and _extract_json_keys
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"
# shellcheck source=../lib/index_reader.sh
source "${TEKHTON_HOME}/lib/index_reader.sh"
# shellcheck source=../lib/index_view.sh
source "${TEKHTON_HOME}/lib/index_view.sh"

# =============================================================================
# _budget_allocator — all sections fill allocation exactly
# Budget=100000: tree=10000, inv=15000, dep=10000, cfg=5000, test=5000
# surplus=0, sample=55000
# =============================================================================
echo "=== _budget_allocator: all sections fill allocation → sample gets base 55% ==="

result=$(_budget_allocator 100000 10000 15000 10000 5000 5000)
expected=55000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 55000 when all sections fill their allocation"
else
    fail "_budget_allocator expected ${expected}, got ${result}"
fi

# =============================================================================
# _budget_allocator — all sections are empty → full surplus added to sample
# surplus = 10000+15000+10000+5000+5000 = 45000; sample = 55000+45000 = 100000
# =============================================================================
echo "=== _budget_allocator: all sections empty → sample gets 55% + full surplus ==="

result=$(_budget_allocator 100000 0 0 0 0 0)
expected=100000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 100000 when all sections are empty (full surplus)"
else
    fail "_budget_allocator expected ${expected}, got ${result}"
fi

# =============================================================================
# _budget_allocator — partial underflow: only tree and deps empty
# tree surplus=10000, dep surplus=10000; inv/cfg/test fill exactly
# sample = 55000 + 20000 = 75000
# =============================================================================
echo "=== _budget_allocator: partial underflow (tree+dep empty) → correct surplus ==="

result=$(_budget_allocator 100000 0 15000 0 5000 5000)
expected=75000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator returns 75000 for partial underflow (tree+dep empty)"
else
    fail "_budget_allocator expected 75000, got ${result}"
fi

# =============================================================================
# _budget_allocator — sections exceed allocation (overflow) are NOT penalized
# The allocator only adds surplus from underflows; overflow sections don't reduce sample
# tree=20000 (overflows 10000 alloc), sample must still be 55000 (no penalty)
# =============================================================================
echo "=== _budget_allocator: overflow sections do not reduce sample budget ==="

result=$(_budget_allocator 100000 20000 15000 10000 5000 5000)
expected=55000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator does not penalize sample for overflow sections"
else
    fail "_budget_allocator expected 55000 for overflow sections, got ${result}"
fi

# =============================================================================
# _budget_allocator — small budget (1000 chars): proportions remain correct
# tree=100, inv=150, dep=100, cfg=50, test=50; actual all 0 → surplus=450; sample=550+450=1000
# =============================================================================
echo "=== _budget_allocator: small budget proportions correct ==="

result=$(_budget_allocator 1000 0 0 0 0 0)
expected=1000
if [[ "$result" -eq "$expected" ]]; then
    pass "_budget_allocator proportions correct for small budget (1000 chars)"
else
    fail "_budget_allocator expected 1000, got ${result}"
fi

# =============================================================================
# View generator: produces valid markdown with all section headings
# =============================================================================
echo "=== View generator: produces all 6 section headings ==="

# Create a minimal structured index fixture
VIEW_DIR="${TEST_TMPDIR}/view_proj"
mkdir -p "${VIEW_DIR}/.claude/index/samples"
# M84: generate_project_index_view writes to ${PROJECT_INDEX_FILE} = .tekhton/PROJECT_INDEX.md
mkdir -p "${VIEW_DIR}/.tekhton"

cat > "${VIEW_DIR}/.claude/index/meta.json" << 'JSON'
{
  "schema_version": 1,
  "project_name": "view-test",
  "scan_date": "2026-04-01T00:00:00Z",
  "scan_commit": "abc1234",
  "file_count": 3,
  "total_lines": 100,
  "tree_lines": 5,
  "doc_quality_score": 0
}
JSON

cat > "${VIEW_DIR}/.claude/index/tree.txt" << 'TREE'
.
├── src
│   └── main.ts
├── tests
│   └── main.test.ts
└── package.json
TREE

cat > "${VIEW_DIR}/.claude/index/inventory.jsonl" << 'JSONL'
{"path":"src/main.ts","dir":"src","lines":50,"size":"small"}
{"path":"tests/main.test.ts","dir":"tests","lines":30,"size":"tiny"}
{"path":"package.json","dir":".","lines":20,"size":"tiny"}
JSONL

cat > "${VIEW_DIR}/.claude/index/dependencies.json" << 'JSON'
{
  "manifests": [
    {"file":"package.json","manager":"npm","deps":1,"dev_deps":0}
  ],
  "key_dependencies": [
    {"name":"express","version":"^4.18.0","manifest":"package.json"}
  ]
}
JSON

cat > "${VIEW_DIR}/.claude/index/configs.json" << 'JSON'
{
  "configs": [
    {"path":"package.json","purpose":"Node.js manifest"}
  ]
}
JSON

cat > "${VIEW_DIR}/.claude/index/tests.json" << 'JSON'
{
  "test_dirs": [
    {"path":"tests/","file_count":1}
  ],
  "test_file_count": 1,
  "frameworks": ["jest"],
  "coverage": []
}
JSON

printf 'console.log("hello");\n' > "${VIEW_DIR}/.claude/index/samples/src__main.ts.txt"
cat > "${VIEW_DIR}/.claude/index/samples/manifest.json" << 'JSON'
{
  "samples": [
    {"original":"src/main.ts","stored":"src__main.ts.txt","chars":24}
  ],
  "total_chars": 24,
  "budget_chars": 66000
}
JSON

generate_project_index_view "$VIEW_DIR" 120000

if [[ -f "${VIEW_DIR}/${PROJECT_INDEX_FILE}" ]]; then
    pass "View generator creates PROJECT_INDEX.md"
else
    fail "View generator did not create PROJECT_INDEX.md"
fi

VIEW_CONTENT=$(cat "${VIEW_DIR}/${PROJECT_INDEX_FILE}")

for heading in "Directory Tree" "File Inventory" "Key Dependencies" \
               "Configuration Files" "Test Infrastructure" "Sampled File Content"; do
    if echo "$VIEW_CONTENT" | grep -q "## ${heading}"; then
        pass "View contains ## ${heading}"
    else
        fail "View missing ## ${heading}"
    fi
done

# =============================================================================
# View generator: output fits within budget
# =============================================================================
echo "=== View generator: output fits within budget ==="

for budget in 1000 10000 50000 120000; do
    generate_project_index_view "$VIEW_DIR" "$budget"
    local_size=$(wc -c < "${VIEW_DIR}/${PROJECT_INDEX_FILE}" | tr -d '[:space:]')
    if [[ "$local_size" -le "$budget" ]]; then
        pass "View fits within ${budget}-char budget (actual: ${local_size})"
    else
        fail "View exceeds ${budget}-char budget (actual: ${local_size})"
    fi
done

# =============================================================================
# View generator: no truncation markers
# =============================================================================
echo "=== View generator: no truncation markers ==="

generate_project_index_view "$VIEW_DIR" 120000
if grep -q "truncated to fit budget" "${VIEW_DIR}/${PROJECT_INDEX_FILE}"; then
    fail "View contains legacy truncation marker"
else
    pass "View does not contain legacy truncation markers"
fi

# =============================================================================
# View generator: selection indicators present for large inventory
# =============================================================================
echo "=== View generator: selection indicators for large data ==="

# Create large inventory (100 files)
LARGE_DIR="${TEST_TMPDIR}/large_proj"
mkdir -p "${LARGE_DIR}/.claude/index/samples"
mkdir -p "${LARGE_DIR}/.tekhton"
cp "${VIEW_DIR}/.claude/index/meta.json" "${LARGE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/tree.txt" "${LARGE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/dependencies.json" "${LARGE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/configs.json" "${LARGE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/tests.json" "${LARGE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/samples/manifest.json" "${LARGE_DIR}/.claude/index/samples/"
cp "${VIEW_DIR}/.claude/index/samples/src__main.ts.txt" "${LARGE_DIR}/.claude/index/samples/"

# Generate 100 inventory records
{
    for i in $(seq 1 100); do
        printf '{"path":"src/file_%03d.ts","dir":"src","lines":200,"size":"small"}\n' "$i"
    done
} > "${LARGE_DIR}/.claude/index/inventory.jsonl"

# Use tiny budget to force selection
generate_project_index_view "$LARGE_DIR" 2000
if grep -q "more files" "${LARGE_DIR}/${PROJECT_INDEX_FILE}"; then
    pass "View shows selection indicator for large inventory"
else
    fail "View missing selection indicator for large inventory"
fi

# =============================================================================
# View generator: tree capped at 300 lines
# =============================================================================
echo "=== View generator: tree capped at 300 lines ==="

TREE_DIR="${TEST_TMPDIR}/tree_proj"
mkdir -p "${TREE_DIR}/.claude/index/samples"
mkdir -p "${TREE_DIR}/.tekhton"
cp "${VIEW_DIR}/.claude/index/meta.json" "${TREE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/inventory.jsonl" "${TREE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/dependencies.json" "${TREE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/configs.json" "${TREE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/tests.json" "${TREE_DIR}/.claude/index/"
cp "${VIEW_DIR}/.claude/index/samples/manifest.json" "${TREE_DIR}/.claude/index/samples/"
cp "${VIEW_DIR}/.claude/index/samples/src__main.ts.txt" "${TREE_DIR}/.claude/index/samples/"

# Generate 400-line tree
{
    for i in $(seq 1 400); do
        printf '├── dir_%03d\n' "$i"
    done
} > "${TREE_DIR}/.claude/index/tree.txt"

generate_project_index_view "$TREE_DIR" 120000
if grep -q "more lines" "${TREE_DIR}/${PROJECT_INDEX_FILE}"; then
    pass "View shows indicator for deep tree"
else
    fail "View missing indicator for deep tree"
fi

# =============================================================================
# View generator: samples section includes only complete samples
# =============================================================================
echo "=== View generator: samples are complete (no mid-file cuts) ==="

generate_project_index_view "$VIEW_DIR" 120000
VIEW_CONTENT=$(cat "${VIEW_DIR}/${PROJECT_INDEX_FILE}")
if echo "$VIEW_CONTENT" | grep -q 'console.log("hello")'; then
    pass "View includes complete sample content"
else
    fail "View missing or truncated sample content"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
