#!/usr/bin/env bash
# Test: Milestones 67-69 — Full structured index pipeline
# Covers: crawl_project structured output, view generator, rescan structured
#         updates, legacy migration, no truncation markers
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
: "${DESIGN_FILE:=${TEKHTON_DIR}/DESIGN.md}"

# Source libraries
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"
# shellcheck source=../lib/index_reader.sh
source "${TEKHTON_HOME}/lib/index_reader.sh"
# shellcheck source=../lib/index_view.sh
source "${TEKHTON_HOME}/lib/index_view.sh"
# shellcheck source=../lib/rescan_helpers.sh
source "${TEKHTON_HOME}/lib/rescan_helpers.sh"
# shellcheck source=../lib/rescan.sh
source "${TEKHTON_HOME}/lib/rescan.sh"

# Helper: create a real project and run full crawl
make_crawl_project() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "${dir}/src" "${dir}/tests" "${dir}/.claude"
    cd "$dir" && git init -q && git config user.email "test@test" && git config user.name "Test"

    printf 'function main() {\n  console.log("hello");\n}\n' > "${dir}/src/index.ts"
    printf 'export function add(a: number, b: number) {\n  return a + b;\n}\n' > "${dir}/src/utils.ts"
    printf 'import { add } from "../src/utils";\ntest("add", () => expect(add(1,2)).toBe(3));\n' > "${dir}/tests/utils.test.ts"
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
    printf '# Test Project\n\nA sample project for testing.\n' > "${dir}/README.md"
    printf 'node_modules/\n.claude/\n' > "${dir}/.gitignore"

    git -C "$dir" add -A && git -C "$dir" commit -q -m "init"

    echo "$dir"
}

# =============================================================================
# Test: crawl_project produces all structured files
# =============================================================================
echo "=== crawl_project: structured index emission ==="

PROJ=$(make_crawl_project "crawl_struct")
crawl_project "$PROJ" 120000

if [[ -f "${PROJ}/.claude/index/meta.json" ]]; then
    pass "crawl_project creates meta.json"
else
    fail "crawl_project missing meta.json"
fi

if [[ -f "${PROJ}/.claude/index/tree.txt" ]]; then
    pass "crawl_project creates tree.txt"
else
    fail "crawl_project missing tree.txt"
fi

if [[ -f "${PROJ}/.claude/index/inventory.jsonl" ]]; then
    pass "crawl_project creates inventory.jsonl"
else
    fail "crawl_project missing inventory.jsonl"
fi

if [[ -f "${PROJ}/.claude/index/dependencies.json" ]]; then
    pass "crawl_project creates dependencies.json"
else
    fail "crawl_project missing dependencies.json"
fi

if [[ -f "${PROJ}/.claude/index/configs.json" ]]; then
    pass "crawl_project creates configs.json"
else
    fail "crawl_project missing configs.json"
fi

if [[ -f "${PROJ}/.claude/index/tests.json" ]]; then
    pass "crawl_project creates tests.json"
else
    fail "crawl_project missing tests.json"
fi

if [[ -f "${PROJ}/.claude/index/samples/manifest.json" ]]; then
    pass "crawl_project creates samples/manifest.json"
else
    fail "crawl_project missing samples/manifest.json"
fi

# =============================================================================
# Test: meta.json has correct schema_version
# =============================================================================
echo "=== crawl_project: meta.json schema_version ==="

if grep -q '"schema_version": 1' "${PROJ}/.claude/index/meta.json"; then
    pass "meta.json has schema_version 1"
else
    fail "meta.json missing or wrong schema_version"
fi

# =============================================================================
# Test: inventory.jsonl record count matches file count
# =============================================================================
echo "=== crawl_project: inventory.jsonl record count ==="

EXPECTED_FILES=$(git -C "$PROJ" ls-files | wc -l | tr -d '[:space:]')
ACTUAL_RECORDS=$(wc -l < "${PROJ}/.claude/index/inventory.jsonl" | tr -d '[:space:]')
if [[ "$ACTUAL_RECORDS" -eq "$EXPECTED_FILES" ]]; then
    pass "inventory.jsonl has ${ACTUAL_RECORDS} records matching ${EXPECTED_FILES} files"
else
    fail "inventory.jsonl has ${ACTUAL_RECORDS} records but expected ${EXPECTED_FILES} files"
fi

# =============================================================================
# Test: VIEW generator produces valid markdown from crawl output
# =============================================================================
echo "=== crawl_project: PROJECT_INDEX.md contains all 6 sections ==="

VIEW=$(cat "${PROJ}/${PROJECT_INDEX_FILE}")

for heading in "Directory Tree" "File Inventory" "Key Dependencies" \
               "Configuration Files" "Test Infrastructure" "Sampled File Content"; do
    if echo "$VIEW" | grep -q "## ${heading}"; then
        pass "PROJECT_INDEX.md contains ## ${heading}"
    else
        fail "PROJECT_INDEX.md missing ## ${heading}"
    fi
done

# =============================================================================
# Test: PROJECT_INDEX.md fits within budget
# =============================================================================
echo "=== crawl_project: output fits within budget ==="

VIEW_SIZE=$(wc -c < "${PROJ}/${PROJECT_INDEX_FILE}" | tr -d '[:space:]')
if [[ "$VIEW_SIZE" -le 120000 ]]; then
    pass "PROJECT_INDEX.md within 120K budget (${VIEW_SIZE} chars)"
else
    fail "PROJECT_INDEX.md exceeds 120K budget (${VIEW_SIZE} chars)"
fi

# =============================================================================
# Test: No truncation markers in output
# =============================================================================
echo "=== crawl_project: no truncation markers ==="

if grep -q "truncated to fit budget" "${PROJ}/${PROJECT_INDEX_FILE}"; then
    fail "PROJECT_INDEX.md contains legacy truncation marker"
else
    pass "PROJECT_INDEX.md free of legacy truncation markers"
fi

# =============================================================================
# Test: View generator with various budgets
# =============================================================================
echo "=== view generator: budget compliance ==="

for budget in 1000 10000 50000 120000; do
    generate_project_index_view "$PROJ" "$budget"
    local_size=$(wc -c < "${PROJ}/${PROJECT_INDEX_FILE}" | tr -d '[:space:]')
    if [[ "$local_size" -le "$budget" ]]; then
        pass "View fits within ${budget}-char budget (actual: ${local_size})"
    else
        fail "View exceeds ${budget}-char budget (actual: ${local_size})"
    fi
done

# Restore full view
generate_project_index_view "$PROJ" 120000

# =============================================================================
# Test: Rescan with file addition updates inventory and regenerates view
# =============================================================================
echo "=== rescan: file addition updates inventory ==="

# Add a new file
printf 'export const API_URL = "http://localhost:3000";\n' > "${PROJ}/src/config.ts"
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "add config"

rescan_project "$PROJ" 120000

# Check inventory.jsonl has the new file
if grep -q '"path":"src/config.ts"' "${PROJ}/.claude/index/inventory.jsonl"; then
    pass "Rescan adds new file to inventory.jsonl"
else
    fail "Rescan did not add new file to inventory.jsonl"
fi

# View should be regenerated
if grep -q "config.ts" "${PROJ}/${PROJECT_INDEX_FILE}"; then
    pass "Rescan regenerates view with new file"
else
    fail "Rescan view missing new file"
fi

# =============================================================================
# Test: Rescan with file deletion removes from inventory
# =============================================================================
echo "=== rescan: file deletion updates inventory ==="

git -C "$PROJ" rm -q "${PROJ}/src/config.ts"
git -C "$PROJ" commit -q -m "remove config"

rescan_project "$PROJ" 120000

if grep -q '"path":"src/config.ts"' "${PROJ}/.claude/index/inventory.jsonl"; then
    fail "Rescan did not remove deleted file from inventory.jsonl"
else
    pass "Rescan removes deleted file from inventory.jsonl"
fi

# =============================================================================
# Test: Rescan with manifest change regenerates dependencies
# =============================================================================
echo "=== rescan: manifest change regenerates dependencies ==="

# Modify package.json to add a dep
cat > "${PROJ}/package.json" << 'PKGJSON'
{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "react": "^18.2.0",
    "express": "^4.18.0",
    "lodash": "^4.17.0"
  },
  "devDependencies": {
    "jest": "^29.0.0"
  }
}
PKGJSON
git -C "$PROJ" add -A && git -C "$PROJ" commit -q -m "add lodash dep"

rescan_project "$PROJ" 120000

if grep -q "lodash" "${PROJ}/.claude/index/dependencies.json"; then
    pass "Rescan updates dependencies.json with new dep"
else
    fail "Rescan did not add lodash to dependencies.json"
fi

if grep -q "lodash" "${PROJ}/${PROJECT_INDEX_FILE}"; then
    pass "Rescan view shows new dependency"
else
    fail "Rescan view missing new dependency"
fi

# =============================================================================
# Test: Forced full crawl produces same result
# =============================================================================
echo "=== rescan: forced full crawl ==="

# Get current state
local_inv_before=$(wc -l < "${PROJ}/.claude/index/inventory.jsonl" | tr -d '[:space:]')

rescan_project "$PROJ" 120000 "full"

local_inv_after=$(wc -l < "${PROJ}/.claude/index/inventory.jsonl" | tr -d '[:space:]')
if [[ "$local_inv_before" -eq "$local_inv_after" ]]; then
    pass "Forced full crawl produces same inventory count (${local_inv_after})"
else
    fail "Forced full crawl changed inventory count (${local_inv_before} → ${local_inv_after})"
fi

# No truncation markers after forced crawl
if grep -q "truncated to fit budget" "${PROJ}/${PROJECT_INDEX_FILE}"; then
    fail "Forced crawl left truncation markers"
else
    pass "Forced crawl free of truncation markers"
fi

# =============================================================================
# Test: Legacy migration — project with old PROJECT_INDEX.md but no .claude/index/
# =============================================================================
echo "=== legacy migration: triggers full crawl ==="

LEGACY_DIR="${TEST_TMPDIR}/legacy_mig"
mkdir -p "${LEGACY_DIR}/.claude" "${LEGACY_DIR}/src"
cd "$LEGACY_DIR" && git init -q && git config user.email "test@test" && git config user.name "Test"
printf 'print("hello")\n' > "${LEGACY_DIR}/src/main.py"
git -C "$LEGACY_DIR" add -A && git -C "$LEGACY_DIR" commit -q -m "init"

local_commit=$(git -C "$LEGACY_DIR" rev-parse --short HEAD)

# Create old-style PROJECT_INDEX.md (no .claude/index/)
cat > "${LEGACY_DIR}/PROJECT_INDEX.md" << LEGACY
# PROJECT_INDEX.md — legacy

<!-- Last-Scan: 2026-01-01T00:00:00Z -->
<!-- Scan-Commit: ${local_commit} -->
<!-- File-Count: 1 -->
<!-- Total-Lines: 1 -->

**Project:** legacy
**Scanned:** 2026-01-01T00:00:00Z
**Files:** 1 | **Lines:** 1

## Directory Tree

.
└── src
    └── main.py

## File Inventory

| Path | Lines | Size |
|------|-------|------|
| src/main.py | 1 | tiny |

... (truncated to fit budget)

## Key Dependencies

(none detected)

## Configuration Files

(none detected)

## Test Infrastructure

(no test infrastructure detected)

## Sampled File Content

(no files sampled)
LEGACY

# Rescan should detect missing structured index and run full crawl
rescan_project "$LEGACY_DIR" 120000

if [[ -f "${LEGACY_DIR}/.claude/index/meta.json" ]]; then
    pass "Legacy migration creates structured index"
else
    fail "Legacy migration did not create structured index"
fi

if grep -q "truncated to fit budget" "${LEGACY_DIR}/${PROJECT_INDEX_FILE}"; then
    fail "Legacy migration left old truncation markers in view"
else
    pass "Legacy migration produces clean view (no truncation markers)"
fi

# =============================================================================
# Test: Reader API (M68) works with M69 view output
# =============================================================================
echo "=== reader API: works with structured index ==="

META=$(read_index_meta "$PROJ")
if echo "$META" | grep -q 'project_name='; then
    pass "read_index_meta works with M69 structured index"
else
    fail "read_index_meta failed with M69 structured index"
fi

SUMMARY=$(read_index_summary "$PROJ" 8000)
SUMMARY_SIZE=${#SUMMARY}
if [[ "$SUMMARY_SIZE" -le 8000 ]] && [[ "$SUMMARY_SIZE" -gt 0 ]]; then
    pass "read_index_summary respects budget (${SUMMARY_SIZE} <= 8000)"
else
    fail "read_index_summary budget issue (size: ${SUMMARY_SIZE})"
fi

# =============================================================================
# Test: _truncate_section is no longer callable
# =============================================================================
echo "=== cleanup: _truncate_section removed ==="

if type -t _truncate_section &>/dev/null; then
    fail "_truncate_section still exists — should be removed"
else
    pass "_truncate_section has been removed"
fi

# =============================================================================
# Test: _replace_section is no longer callable
# =============================================================================
echo "=== cleanup: _replace_section removed ==="

if type -t _replace_section &>/dev/null; then
    fail "_replace_section still exists — should be removed"
else
    pass "_replace_section has been removed"
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
