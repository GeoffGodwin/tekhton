#!/usr/bin/env bash
# Test: Milestone 68 — Consumer Migration to Structured Index
# Covers: index_reader.sh API, consumer migrations, _extract_scan_metadata M68,
#         _extract_sampled_files M68, legacy fallback paths
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

# Source detect.sh first (provides _DETECT_EXCLUDE_DIRS + _extract_json_keys)
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"
# shellcheck source=../lib/index_reader.sh
source "${TEKHTON_HOME}/lib/index_reader.sh"
# shellcheck source=../lib/rescan_helpers.sh
source "${TEKHTON_HOME}/lib/rescan_helpers.sh"

# Helper: create a structured index fixture (M67 format)
make_structured_project() {
    local dir="${TEST_TMPDIR}/${1}"
    mkdir -p "${dir}/.claude/index/samples" "${dir}/src" "${dir}/tests"
    cd "$dir" && git init -q && git config user.email "test@test" && git config user.name "Test"

    # Source files
    printf 'function main() {\n  console.log("hello");\n}\n' > "${dir}/src/index.ts"
    printf 'export function add(a, b) {\n  return a + b;\n}\n' > "${dir}/src/utils.ts"
    printf 'import { add } from "../src/utils";\ntest("add", () => expect(add(1,2)).toBe(3));\n' > "${dir}/tests/utils.test.ts"

    # Config
    cat > "${dir}/package.json" << 'PKGJSON'
{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "react": "^18.2.0",
    "express": "^4.18.0"
  },
  "devDependencies": {
    "jest": "^29.0.0"
  }
}
PKGJSON
    printf '{"compilerOptions":{"strict":true}}\n' > "${dir}/tsconfig.json"
    printf '# Test Project\n\nA sample project.\n' > "${dir}/README.md"

    git -C "$dir" add -A && git -C "$dir" commit -q -m "init"

    # Write structured index files (simulating M67 output)
    local commit
    commit=$(git -C "$dir" rev-parse --short HEAD)

    # meta.json
    cat > "${dir}/.claude/index/meta.json" << METAJSON
{
  "schema_version": 1,
  "project_name": "test-project",
  "scan_date": "2026-03-01T00:00:00Z",
  "scan_commit": "${commit}",
  "file_count": 5,
  "total_lines": 42,
  "tree_lines": 10,
  "doc_quality_score": 50
}
METAJSON

    # tree.txt
    cat > "${dir}/.claude/index/tree.txt" << 'TREE'
.
├── src [source]
│   ├── index.ts
│   └── utils.ts
├── tests [tests]
│   └── utils.test.ts
├── package.json
├── tsconfig.json
└── README.md
TREE

    # inventory.jsonl
    cat > "${dir}/.claude/index/inventory.jsonl" << 'INVJSONL'
{"path":"src/index.ts","dir":"src","lines":3,"size":"tiny"}
{"path":"src/utils.ts","dir":"src","lines":3,"size":"tiny"}
{"path":"tests/utils.test.ts","dir":"tests","lines":2,"size":"tiny"}
{"path":"package.json","dir":".","lines":14,"size":"tiny"}
{"path":"tsconfig.json","dir":".","lines":1,"size":"tiny"}
INVJSONL

    # dependencies.json
    cat > "${dir}/.claude/index/dependencies.json" << 'DEPJSON'
{
  "manifests": [
    {"file":"package.json","manager":"npm","deps":2,"dev_deps":1}
  ],
  "key_dependencies": [
    {"name":"react","version":"^18.2.0","manifest":"package.json"},
    {"name":"express","version":"^4.18.0","manifest":"package.json"},
    {"name":"jest","version":"^29.0.0","manifest":"package.json"}
  ]
}
DEPJSON

    # configs.json
    cat > "${dir}/.claude/index/configs.json" << 'CFGJSON'
{
  "configs": [
    {"path":"tsconfig.json","purpose":"TypeScript config"},
    {"path":"package.json","purpose":"Node.js manifest"}
  ]
}
CFGJSON

    # tests.json
    cat > "${dir}/.claude/index/tests.json" << 'TESTJSON'
{
  "test_dirs": [
    {"path":"tests/","file_count":1}
  ],
  "test_file_count": 1,
  "frameworks": ["jest"],
  "coverage": []
}
TESTJSON

    # samples/manifest.json + sample files
    printf 'function main() {\n  console.log("hello");\n}\n' > "${dir}/.claude/index/samples/src__index.ts.txt"
    printf '# Test Project\n\nA sample project.\n' > "${dir}/.claude/index/samples/README.md.txt"
    cat > "${dir}/.claude/index/samples/manifest.json" << 'SAMPJSON'
{
  "samples": [
    {"original":"README.md","stored":"README.md.txt","chars":34},
    {"original":"src/index.ts","stored":"src__index.ts.txt","chars":45}
  ],
  "total_chars": 79,
  "budget_chars": 66000
}
SAMPJSON

    echo "$dir"
}

# Helper: create a legacy (pre-M67) project with only PROJECT_INDEX.md
make_legacy_project() {
    local dir="${TEST_TMPDIR}/${1}"
    mkdir -p "${dir}/.claude" "${dir}/src"
    cd "$dir" && git init -q && git config user.email "test@test" && git config user.name "Test"
    printf 'console.log("hello");\n' > "${dir}/src/main.js"
    git -C "$dir" add -A && git -C "$dir" commit -q -m "init"

    local commit
    commit=$(git -C "$dir" rev-parse --short HEAD)

    cat > "${dir}/PROJECT_INDEX.md" << LEGACY
# PROJECT_INDEX.md — legacy-project

<!-- Last-Scan: 2026-01-15T00:00:00Z -->
<!-- Scan-Commit: ${commit} -->
<!-- File-Count: 1 -->
<!-- Total-Lines: 1 -->

**Project:** legacy-project
**Scanned:** 2026-01-15T00:00:00Z
**Files:** 1 | **Lines:** 1

## Directory Tree

.
└── src
    └── main.js

## File Inventory

| Path | Lines | Size |
|------|-------|------|
| src/main.js | 1 | tiny |

## Key Dependencies

(none detected)

## Configuration Files

(none detected)

## Test Infrastructure

(no test directories detected)

## Sampled File Content

### src/main.js

\`\`\`js
console.log("hello");
\`\`\`
LEGACY

    echo "$dir"
}

# =============================================================================
# Tests: read_index_meta
# =============================================================================
echo "=== read_index_meta — structured data ==="

PROJ=$(make_structured_project "meta_struct")
META=$(read_index_meta "$PROJ")

if echo "$META" | grep -q 'project_name=test-project'; then
    pass "read_index_meta returns project_name from meta.json"
else
    fail "read_index_meta missing project_name"
fi

if echo "$META" | grep -q 'file_count=5'; then
    pass "read_index_meta returns file_count from meta.json"
else
    fail "read_index_meta missing file_count (got: $META)"
fi

if echo "$META" | grep -q 'scan_date=2026-03-01T00:00:00Z'; then
    pass "read_index_meta returns scan_date from meta.json"
else
    fail "read_index_meta missing scan_date"
fi

if echo "$META" | grep -q 'total_lines=42'; then
    pass "read_index_meta returns total_lines from meta.json"
else
    fail "read_index_meta missing total_lines"
fi

echo "=== read_index_meta — legacy fallback ==="

LPROJ=$(make_legacy_project "meta_legacy")
LMETA=$(read_index_meta "$LPROJ")

if echo "$LMETA" | grep -q 'project_name=legacy-project'; then
    pass "read_index_meta legacy returns project_name from HTML comments"
else
    fail "read_index_meta legacy missing project_name (got: $LMETA)"
fi

if echo "$LMETA" | grep -q 'file_count=1'; then
    pass "read_index_meta legacy returns file_count"
else
    fail "read_index_meta legacy missing file_count"
fi

if echo "$LMETA" | grep -q 'scan_date=2026-01-15T00:00:00Z'; then
    pass "read_index_meta legacy returns scan_date"
else
    fail "read_index_meta legacy missing scan_date"
fi

# =============================================================================
# Tests: read_index_tree
# =============================================================================
echo "=== read_index_tree ==="

TREE=$(read_index_tree "$PROJ")
if echo "$TREE" | grep -q 'index.ts'; then
    pass "read_index_tree returns tree content"
else
    fail "read_index_tree missing tree content"
fi

# Test max_lines truncation
TREE_SHORT=$(read_index_tree "$PROJ" 3)
LINE_COUNT=$(printf '%s\n' "$TREE_SHORT" | wc -l | tr -d '[:space:]')
if [[ "$LINE_COUNT" -le 3 ]]; then
    pass "read_index_tree respects max_lines"
else
    fail "read_index_tree max_lines not respected (got ${LINE_COUNT} lines)"
fi

# Legacy tree
LTREE=$(read_index_tree "$LPROJ")
if echo "$LTREE" | grep -q 'main.js'; then
    pass "read_index_tree legacy fallback works"
else
    fail "read_index_tree legacy fallback missing content"
fi

# =============================================================================
# Tests: read_index_inventory
# =============================================================================
echo "=== read_index_inventory ==="

INV=$(read_index_inventory "$PROJ" 0)
if echo "$INV" | grep -q 'src/index.ts'; then
    pass "read_index_inventory returns file records"
else
    fail "read_index_inventory missing records"
fi

# Test max_records
INV_LIMITED=$(read_index_inventory "$PROJ" 2)
# Header (2 lines) + 2 data lines = 4 lines max
DATA_LINES=$(printf '%s\n' "$INV_LIMITED" | grep -c '| src/\|| tests/\|| package\|| tsconfig' || true)
if [[ "$DATA_LINES" -le 2 ]]; then
    pass "read_index_inventory respects max_records"
else
    fail "read_index_inventory max_records not respected (got ${DATA_LINES} data lines)"
fi

# Test size filter
INV_TINY=$(read_index_inventory "$PROJ" 0 "size:tiny")
TINY_COUNT=$(printf '%s\n' "$INV_TINY" | grep -c '| tiny' || true)
if [[ "$TINY_COUNT" -eq 5 ]]; then
    pass "read_index_inventory size filter works"
else
    fail "read_index_inventory size filter wrong count (expected 5, got ${TINY_COUNT})"
fi

# Test dir filter
INV_SRC=$(read_index_inventory "$PROJ" 0 "dir:src")
if echo "$INV_SRC" | grep -q 'src/index.ts' && ! echo "$INV_SRC" | grep -q 'package.json'; then
    pass "read_index_inventory dir filter works"
else
    fail "read_index_inventory dir filter mismatch"
fi

# Legacy inventory
LINV=$(read_index_inventory "$LPROJ" 0)
if echo "$LINV" | grep -q 'src/main.js'; then
    pass "read_index_inventory legacy fallback works"
else
    fail "read_index_inventory legacy fallback missing records"
fi

# =============================================================================
# Tests: read_index_dependencies
# =============================================================================
echo "=== read_index_dependencies ==="

DEPS=$(read_index_dependencies "$PROJ")
if echo "$DEPS" | grep -q 'package.json'; then
    pass "read_index_dependencies returns manifest info"
else
    fail "read_index_dependencies missing manifest info"
fi

if echo "$DEPS" | grep -q 'react'; then
    pass "read_index_dependencies returns dependency names"
else
    fail "read_index_dependencies missing dependency names"
fi

# Legacy
LDEPS=$(read_index_dependencies "$LPROJ")
if echo "$LDEPS" | grep -q 'none detected'; then
    pass "read_index_dependencies legacy fallback works"
else
    fail "read_index_dependencies legacy fallback missing (got: $LDEPS)"
fi

# =============================================================================
# Tests: read_index_configs
# =============================================================================
echo "=== read_index_configs ==="

CFGS=$(read_index_configs "$PROJ")
if echo "$CFGS" | grep -q 'tsconfig.json'; then
    pass "read_index_configs returns config entries"
else
    fail "read_index_configs missing entries"
fi

# =============================================================================
# Tests: read_index_tests
# =============================================================================
echo "=== read_index_tests ==="

TESTS=$(read_index_tests "$PROJ")
if echo "$TESTS" | grep -q 'Test files.*1'; then
    pass "read_index_tests returns test file count"
else
    fail "read_index_tests missing test file count (got: $TESTS)"
fi

if echo "$TESTS" | grep -q 'jest'; then
    pass "read_index_tests returns framework names"
else
    fail "read_index_tests missing framework names"
fi

# Legacy
LTESTS=$(read_index_tests "$LPROJ")
if echo "$LTESTS" | grep -q 'no test'; then
    pass "read_index_tests legacy fallback works"
else
    fail "read_index_tests legacy fallback missing (got: $LTESTS)"
fi

# =============================================================================
# Tests: read_index_samples
# =============================================================================
echo "=== read_index_samples ==="

SAMPLES=$(read_index_samples "$PROJ")
if echo "$SAMPLES" | grep -q 'README.md'; then
    pass "read_index_samples returns sampled file content"
else
    fail "read_index_samples missing sampled content"
fi

if echo "$SAMPLES" | grep -q 'src/index.ts'; then
    pass "read_index_samples returns second sample"
else
    fail "read_index_samples missing second sample"
fi

# Test max_chars budget
SAMPLES_SMALL=$(read_index_samples "$PROJ" 50)
SAMPLE_SIZE=${#SAMPLES_SMALL}
if [[ "$SAMPLE_SIZE" -lt 200 ]]; then
    pass "read_index_samples respects max_chars budget"
else
    fail "read_index_samples budget not respected (size: ${SAMPLE_SIZE})"
fi

# Legacy
LSAMPLES=$(read_index_samples "$LPROJ")
if echo "$LSAMPLES" | grep -q 'src/main.js'; then
    pass "read_index_samples legacy fallback works"
else
    fail "read_index_samples legacy fallback missing"
fi

# =============================================================================
# Tests: read_index_summary
# =============================================================================
echo "=== read_index_summary — budget ==="

SUMMARY=$(read_index_summary "$PROJ" 8000)
SUMMARY_SIZE=${#SUMMARY}

if [[ "$SUMMARY_SIZE" -le 8000 ]]; then
    pass "read_index_summary respects budget (${SUMMARY_SIZE} <= 8000)"
else
    fail "read_index_summary exceeds budget (${SUMMARY_SIZE} > 8000)"
fi

if echo "$SUMMARY" | grep -q 'Project: test-project'; then
    pass "read_index_summary includes meta header"
else
    fail "read_index_summary missing meta header"
fi

if echo "$SUMMARY" | grep -q 'Directory Tree'; then
    pass "read_index_summary includes tree section"
else
    fail "read_index_summary missing tree section"
fi

if echo "$SUMMARY" | grep -q 'Test Infrastructure'; then
    pass "read_index_summary includes test section"
else
    fail "read_index_summary missing test section"
fi

echo "=== read_index_summary — priority fill ==="

# With a large budget, deps and inventory should be included
BIG_SUMMARY=$(read_index_summary "$PROJ" 60000)
if echo "$BIG_SUMMARY" | grep -q 'Dependencies'; then
    pass "read_index_summary includes deps with large budget"
else
    fail "read_index_summary missing deps with large budget"
fi

if echo "$BIG_SUMMARY" | grep -q 'File Inventory'; then
    pass "read_index_summary includes inventory with large budget"
else
    fail "read_index_summary missing inventory with large budget"
fi

echo "=== read_index_summary — legacy project ==="

LSUMMARY=$(read_index_summary "$LPROJ" 8000)
if echo "$LSUMMARY" | grep -q 'Project: legacy-project'; then
    pass "read_index_summary legacy includes meta"
else
    fail "read_index_summary legacy missing meta"
fi

if echo "$LSUMMARY" | grep -q 'main.js'; then
    pass "read_index_summary legacy includes file content"
else
    fail "read_index_summary legacy missing content"
fi

# =============================================================================
# Tests: _extract_scan_metadata M68 (meta.json preferred)
# =============================================================================
echo "=== _extract_scan_metadata — meta.json preferred ==="

# Create a minimal PROJECT_INDEX.md so the function has a file path to reference
# (function signature takes the index file path, meta.json is found relative to it)
if [[ ! -f "${PROJ}/PROJECT_INDEX.md" ]]; then
    printf '# placeholder\n' > "${PROJ}/PROJECT_INDEX.md"
fi

SCAN_COMMIT=$(_extract_scan_metadata "${PROJ}/PROJECT_INDEX.md" "Scan-Commit")
EXPECTED_COMMIT=$(git -C "$PROJ" rev-parse --short HEAD)
if [[ "$SCAN_COMMIT" == "$EXPECTED_COMMIT" ]]; then
    pass "_extract_scan_metadata reads scan_commit from meta.json"
else
    fail "_extract_scan_metadata wrong commit (expected ${EXPECTED_COMMIT}, got ${SCAN_COMMIT})"
fi

# File count should be 5 (from our hand-written meta.json fixture)
FILE_COUNT=$(_extract_scan_metadata "${PROJ}/PROJECT_INDEX.md" "File-Count")
if [[ "$FILE_COUNT" == "5" ]]; then
    pass "_extract_scan_metadata reads file_count from meta.json"
else
    fail "_extract_scan_metadata wrong file_count (expected 5, got ${FILE_COUNT})"
fi

echo "=== _extract_scan_metadata — legacy fallback ==="

LSCAN=$(_extract_scan_metadata "${LPROJ}/PROJECT_INDEX.md" "Scan-Commit")
LEXPECTED=$(git -C "$LPROJ" rev-parse --short HEAD)
if [[ "$LSCAN" == "$LEXPECTED" ]]; then
    pass "_extract_scan_metadata legacy reads from HTML comments"
else
    fail "_extract_scan_metadata legacy wrong commit (expected ${LEXPECTED}, got ${LSCAN})"
fi

LDATE=$(_extract_scan_metadata "${LPROJ}/PROJECT_INDEX.md" "Last-Scan")
if [[ "$LDATE" == "2026-01-15T00:00:00Z" ]]; then
    pass "_extract_scan_metadata legacy reads Last-Scan"
else
    fail "_extract_scan_metadata legacy wrong date (got ${LDATE})"
fi

# =============================================================================
# Tests: _extract_sampled_files M68 (manifest.json preferred)
# =============================================================================
echo "=== _extract_sampled_files — manifest.json preferred ==="

# Need PROJECT_INDEX.md to exist for the function signature
if [[ ! -f "${PROJ}/PROJECT_INDEX.md" ]]; then
    printf '# placeholder\n' > "${PROJ}/PROJECT_INDEX.md"
fi
SAMPLED=$(_extract_sampled_files "${PROJ}/PROJECT_INDEX.md")
if echo "$SAMPLED" | grep -q 'README.md'; then
    pass "_extract_sampled_files reads from manifest.json"
else
    fail "_extract_sampled_files missing README.md (got: $SAMPLED)"
fi

if echo "$SAMPLED" | grep -q 'src/index.ts'; then
    pass "_extract_sampled_files reads second entry from manifest"
else
    fail "_extract_sampled_files missing src/index.ts"
fi

echo "=== _extract_sampled_files — legacy fallback (fixed regex) ==="

LSAMPLED=$(_extract_sampled_files "${LPROJ}/PROJECT_INDEX.md")
if echo "$LSAMPLED" | grep -q 'src/main.js'; then
    pass "_extract_sampled_files legacy fallback works (fixed regex)"
else
    fail "_extract_sampled_files legacy fallback missing (got: $LSAMPLED)"
fi

# =============================================================================
# Tests: Intake consumer receives non-empty context
# =============================================================================
echo "=== Intake consumer — structured project ==="

INTAKE_CTX=$(read_index_summary "$PROJ" 8000)
if [[ -n "$INTAKE_CTX" ]]; then
    pass "Intake receives non-empty context for structured project"
else
    fail "Intake context is empty for structured project"
fi

INTAKE_SIZE=${#INTAKE_CTX}
if [[ "$INTAKE_SIZE" -le 8000 ]]; then
    pass "Intake context within 8KB budget (${INTAKE_SIZE} chars)"
else
    fail "Intake context exceeds budget (${INTAKE_SIZE} > 8000)"
fi

echo "=== Intake consumer — legacy project ==="

LINTAKE=$(read_index_summary "$LPROJ" 8000)
if [[ -n "$LINTAKE" ]]; then
    pass "Intake receives non-empty context for legacy project"
else
    fail "Intake context is empty for legacy project"
fi

# =============================================================================
# Tests: Synthesis consumer is bounded
# =============================================================================
echo "=== Synthesis consumer — bounded without summarize_headings ==="

SYNTH_CTX=$(read_index_summary "$PROJ" 60000)
SYNTH_SIZE=${#SYNTH_CTX}
if [[ "$SYNTH_SIZE" -le 60000 ]]; then
    pass "Synthesis context within 60KB budget (${SYNTH_SIZE} chars)"
else
    fail "Synthesis context exceeds budget (${SYNTH_SIZE} > 60000)"
fi

# Verify content richness — should contain actual data, not just headings
if echo "$SYNTH_CTX" | grep -q 'react'; then
    pass "Synthesis context preserves dependency details (not headings-only)"
else
    fail "Synthesis context lost dependency details"
fi

# =============================================================================
# Tests: Replan consumer is bounded
# =============================================================================
echo "=== Replan consumer — bounded ==="

REPLAN_CTX=$(read_index_summary "$PROJ" 40000)
REPLAN_SIZE=${#REPLAN_CTX}
if [[ "$REPLAN_SIZE" -le 40000 ]]; then
    pass "Replan context within 40KB budget (${REPLAN_SIZE} chars)"
else
    fail "Replan context exceeds budget (${REPLAN_SIZE} > 40000)"
fi

# =============================================================================
# Tests: Empty/missing project directory
# =============================================================================
echo "=== Edge: missing project ==="

EMPTY_DIR="${TEST_TMPDIR}/nonexistent"
EMPTY_META=$(read_index_meta "$EMPTY_DIR")
if [[ -z "$EMPTY_META" ]]; then
    pass "read_index_meta returns empty for missing project"
else
    fail "read_index_meta should be empty for missing project"
fi

# Should produce something minimal or empty, not crash
if read_index_summary "$EMPTY_DIR" 1000 >/dev/null 2>&1; then
    pass "read_index_summary handles missing project gracefully"
else
    fail "read_index_summary crashed on missing project"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "=== Results ==="
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
