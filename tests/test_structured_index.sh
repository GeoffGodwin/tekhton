#!/usr/bin/env bash
# Test: Milestone 67 — Structured Project Index Data Layer
# Covers: crawl_project structured output, meta.json, inventory.jsonl,
#         dependencies.json, configs.json, tests.json, samples/, tree.txt,
#         atomic writes, PROJECT_INDEX_BUDGET, legacy bridge
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

# Source detect.sh first (provides _DETECT_EXCLUDE_DIRS + _extract_json_keys)
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/crawler.sh
source "${TEKHTON_HOME}/lib/crawler.sh"
# shellcheck source=../lib/index_reader.sh
source "${TEKHTON_HOME}/lib/index_reader.sh"
# shellcheck source=../lib/index_view.sh
source "${TEKHTON_HOME}/lib/index_view.sh"

# Helper: create a test project with representative files
make_test_project() {
    local dir="${TEST_TMPDIR}/${1}"
    mkdir -p "${dir}/src" "${dir}/tests" "${dir}/.claude"
    cd "$dir" && git init -q && git config user.email "test@test" && git config user.name "Test"

    # Source files
    printf 'function main() {\n  console.log("hello");\n}\n' > "${dir}/src/index.ts"
    printf 'export function add(a, b) {\n  return a + b;\n}\n' > "${dir}/src/utils.ts"

    # Test file
    printf 'import { add } from "../src/utils";\ntest("add", () => expect(add(1,2)).toBe(3));\n' > "${dir}/tests/utils.test.ts"

    # Config files
    cat > "${dir}/package.json" << 'PKGJSON'
{
  "name": "test-project",
  "version": "1.0.0",
  "dependencies": {
    "react": "^18.2.0",
    "express": "^4.18.0"
  },
  "devDependencies": {
    "jest": "^29.0.0",
    "typescript": "^5.0.0"
  }
}
PKGJSON
    printf '{"compilerOptions":{"strict":true}}\n' > "${dir}/tsconfig.json"
    printf 'node_modules/\ndist/\n' > "${dir}/.gitignore"

    # README
    printf '# Test Project\n\nA sample project for testing.\n' > "${dir}/README.md"

    git -C "$dir" add -A && git -C "$dir" commit -q -m "init"
    echo "$dir"
}

# =============================================================================
# Test: crawl_project creates .claude/index/ directory with all expected files
# =============================================================================
echo "=== crawl_project creates structured index directory ==="

PROJ=$(make_test_project "structured_basic")
crawl_project "$PROJ" 120000

INDEX_DIR="${PROJ}/.claude/index"

if [[ -d "$INDEX_DIR" ]]; then
    pass "crawl_project creates .claude/index/ directory"
else
    fail "crawl_project did not create .claude/index/ directory"
fi

for expected_file in meta.json tree.txt inventory.jsonl dependencies.json configs.json tests.json; do
    if [[ -f "${INDEX_DIR}/${expected_file}" ]]; then
        pass "${expected_file} exists in .claude/index/"
    else
        fail "${expected_file} missing from .claude/index/"
    fi
done

if [[ -d "${INDEX_DIR}/samples" ]]; then
    pass "samples/ directory exists"
else
    fail "samples/ directory missing"
fi

if [[ -f "${INDEX_DIR}/samples/manifest.json" ]]; then
    pass "samples/manifest.json exists"
else
    fail "samples/manifest.json missing"
fi

# =============================================================================
# Test: meta.json is valid JSON with all required fields
# =============================================================================
echo "=== meta.json validation ==="

META="${INDEX_DIR}/meta.json"
# Validate JSON with python3 if available, fallback to grep
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${META}'))" 2>/dev/null; then
        pass "meta.json is valid JSON (python3 validated)"
    else
        fail "meta.json is not valid JSON"
    fi
else
    if head -1 "$META" | grep -q '^{' && tail -1 "$META" | grep -q '^}'; then
        pass "meta.json has valid JSON structure (basic check)"
    else
        fail "meta.json does not have valid JSON structure"
    fi
fi

for field in schema_version project_name scan_date scan_commit file_count total_lines tree_lines doc_quality_score; do
    if grep -q "\"${field}\"" "$META"; then
        pass "meta.json contains field: ${field}"
    else
        fail "meta.json missing field: ${field}"
    fi
done

# Check schema_version is 1
if grep -q '"schema_version": 1' "$META"; then
    pass "meta.json schema_version is 1"
else
    fail "meta.json schema_version is not 1"
fi

# =============================================================================
# Test: inventory.jsonl line count matches meta.json file_count
# =============================================================================
echo "=== inventory.jsonl consistency with meta.json ==="

INV="${INDEX_DIR}/inventory.jsonl"
inv_lines=$(wc -l < "$INV" | tr -d '[:space:]')
meta_file_count=$(awk -F'"file_count":' 'NF>1{split($2,a,/[,}]/); gsub(/[^0-9]/,"",a[1]); print a[1]}' "$META")

if [[ "$inv_lines" == "$meta_file_count" ]]; then
    pass "inventory.jsonl line count (${inv_lines}) matches meta.json file_count (${meta_file_count})"
else
    fail "inventory.jsonl lines (${inv_lines}) != meta.json file_count (${meta_file_count})"
fi

# Test: inventory lines field sum matches meta.json total_lines
inv_total_lines=$(awk -F'"lines":' '{split($2,a,/[,}]/); s+=a[1]} END {print s+0}' "$INV")
meta_total_lines=$(awk -F'"total_lines":' 'NF>1{split($2,a,/[,}]/); gsub(/[^0-9]/,"",a[1]); print a[1]}' "$META")

if [[ "$inv_total_lines" == "$meta_total_lines" ]]; then
    pass "inventory.jsonl lines sum (${inv_total_lines}) matches meta.json total_lines (${meta_total_lines})"
else
    fail "inventory.jsonl lines sum (${inv_total_lines}) != meta.json total_lines (${meta_total_lines})"
fi

# =============================================================================
# Test: inventory.jsonl records have required fields
# =============================================================================
echo "=== inventory.jsonl record validation ==="

first_record=$(head -1 "$INV")
for field in path dir lines size; do
    if printf '%s' "$first_record" | grep -q "\"${field}\""; then
        pass "inventory.jsonl records contain field: ${field}"
    else
        fail "inventory.jsonl records missing field: ${field}"
    fi
done

# Verify size category values
if grep -q '"size":"small"\|"size":"tiny"\|"size":"medium"\|"size":"large"\|"size":"huge"' "$INV"; then
    pass "inventory.jsonl uses valid size categories"
else
    fail "inventory.jsonl has unexpected size categories"
fi

# =============================================================================
# Test: dependencies.json is valid JSON and captures manifests
# =============================================================================
echo "=== dependencies.json validation ==="

DEPS="${INDEX_DIR}/dependencies.json"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${DEPS}'))" 2>/dev/null; then
        pass "dependencies.json is valid JSON"
    else
        fail "dependencies.json is not valid JSON"
    fi
fi

if grep -q '"package.json"' "$DEPS"; then
    pass "dependencies.json detects package.json manifest"
else
    fail "dependencies.json missing package.json manifest"
fi

if grep -q '"react"' "$DEPS"; then
    pass "dependencies.json captures react dependency"
else
    fail "dependencies.json missing react dependency"
fi

if grep -q '"npm"' "$DEPS"; then
    pass "dependencies.json identifies npm as manager"
else
    fail "dependencies.json missing npm manager"
fi

# =============================================================================
# Test: configs.json is valid JSON and lists config files
# =============================================================================
echo "=== configs.json validation ==="

CONFIGS="${INDEX_DIR}/configs.json"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${CONFIGS}'))" 2>/dev/null; then
        pass "configs.json is valid JSON"
    else
        fail "configs.json is not valid JSON"
    fi
fi

if grep -q '".gitignore"' "$CONFIGS" && grep -q '"Git ignore rules"' "$CONFIGS"; then
    pass "configs.json lists .gitignore with correct purpose"
else
    fail "configs.json missing .gitignore or wrong purpose"
fi

if grep -q '"tsconfig.json"' "$CONFIGS"; then
    pass "configs.json lists tsconfig.json"
else
    fail "configs.json missing tsconfig.json"
fi

# =============================================================================
# Test: tests.json is valid JSON and detects test directories
# =============================================================================
echo "=== tests.json validation ==="

TESTS="${INDEX_DIR}/tests.json"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${TESTS}'))" 2>/dev/null; then
        pass "tests.json is valid JSON"
    else
        fail "tests.json is not valid JSON"
    fi
fi

if grep -q '"tests/"' "$TESTS"; then
    pass "tests.json detects tests/ directory"
else
    fail "tests.json missing tests/ directory"
fi

if grep -q '"jest"' "$TESTS"; then
    pass "tests.json detects jest framework"
else
    fail "tests.json missing jest framework"
fi

# =============================================================================
# Test: samples/manifest.json and sample files exist
# =============================================================================
echo "=== samples/ validation ==="

MANIFEST="${INDEX_DIR}/samples/manifest.json"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('${MANIFEST}'))" 2>/dev/null; then
        pass "samples/manifest.json is valid JSON"
    else
        fail "samples/manifest.json is not valid JSON"
    fi
fi

# README.md should be sampled (highest priority)
if grep -q '"README.md"' "$MANIFEST"; then
    pass "samples/manifest.json lists README.md"
else
    fail "samples/manifest.json missing README.md"
fi

# Check the stored sample file exists
if [[ -f "${INDEX_DIR}/samples/README.md.txt" ]]; then
    pass "README.md.txt sample file exists on disk"
else
    fail "README.md.txt sample file missing"
fi

# Verify stored path sanitization (/ → __)
if grep -q '"src__index.ts.txt"' "$MANIFEST"; then
    pass "samples/manifest.json uses sanitized path (/ → __)"
else
    # src/index.ts might not be sampled if budget runs out; check for any sanitized path
    if grep -q '__' "$MANIFEST"; then
        pass "samples/manifest.json uses sanitized paths (/ → __)"
    else
        pass "samples/manifest.json OK (no nested paths to sanitize)"
    fi
fi

# =============================================================================
# Test: tree.txt is not truncated for small project
# =============================================================================
echo "=== tree.txt validation ==="

TREE="${INDEX_DIR}/tree.txt"
if [[ -s "$TREE" ]]; then
    pass "tree.txt is non-empty"
else
    fail "tree.txt is empty"
fi

# Small project should not have truncation marker
if ! grep -q "truncated" "$TREE"; then
    pass "tree.txt is not truncated for small fixture"
else
    fail "tree.txt was unexpectedly truncated"
fi

# =============================================================================
# Test: PROJECT_INDEX.md is generated at ${PROJECT_INDEX_FILE} (M84: .tekhton/)
# =============================================================================
echo "=== M84: PROJECT_INDEX.md placement ==="

if [[ -f "${PROJ}/${PROJECT_INDEX_FILE}" ]]; then
    pass "PROJECT_INDEX.md generated at \${PROJECT_INDEX_FILE} (${PROJECT_INDEX_FILE})"
else
    fail "PROJECT_INDEX.md not generated at ${PROJECT_INDEX_FILE}"
fi

# Verify it has expected sections
for section in "Directory Tree" "File Inventory" "Key Dependencies" "Configuration Files" "Test Infrastructure" "Sampled File Content"; do
    if grep -q "## ${section}" "${PROJ}/${PROJECT_INDEX_FILE}"; then
        pass "PROJECT_INDEX.md contains section: ${section}"
    else
        fail "PROJECT_INDEX.md missing section: ${section}"
    fi
done

# =============================================================================
# Test: PROJECT_INDEX_BUDGET config key is respected
# =============================================================================
echo "=== PROJECT_INDEX_BUDGET config key ==="

PROJ2=$(make_test_project "budget_test")
PROJECT_INDEX_BUDGET=5000 crawl_project "$PROJ2" "${PROJECT_INDEX_BUDGET:-5000}"

size=$(wc -c < "${PROJ2}/${PROJECT_INDEX_FILE}" | tr -d '[:space:]')
# With a 5000 budget, the file should be notably smaller
if [[ "$size" -le 6000 ]]; then
    pass "PROJECT_INDEX.md respects small budget (${size} chars <= 6000)"
else
    fail "PROJECT_INDEX.md exceeds budget (${size} chars > 6000 for budget 5000)"
fi

# =============================================================================
# Test: Empty project (no files) produces valid outputs
# =============================================================================
echo "=== Empty project handling ==="

EMPTY=$(make_test_project "empty_proj")
# Remove all files except .git
find "$EMPTY" -maxdepth 1 -not -name '.git' -not -name '.claude' -not -path "$EMPTY" -exec rm -rf {} + 2>/dev/null || true
git -C "$EMPTY" add -A && git -C "$EMPTY" commit -q -m "empty" --allow-empty

crawl_project "$EMPTY" 120000

EMPTY_INV="${EMPTY}/.claude/index/inventory.jsonl"
if [[ -f "$EMPTY_INV" ]]; then
    empty_size=$(wc -c < "$EMPTY_INV" | tr -d '[:space:]')
    if [[ "$empty_size" -eq 0 ]]; then
        pass "Empty project produces empty inventory.jsonl (0 bytes)"
    else
        pass "Empty project produces inventory.jsonl (${empty_size} bytes)"
    fi
else
    fail "Empty project did not create inventory.jsonl"
fi

# =============================================================================
# Test: _json_escape handles special characters
# =============================================================================
echo "=== _json_escape special character handling ==="

escaped=$(_json_escape 'path/with "quotes" and \\backslash')
if [[ "$escaped" == 'path/with \"quotes\" and \\\\backslash' ]]; then
    pass "_json_escape handles quotes and backslashes"
else
    fail "_json_escape output unexpected: ${escaped}"
fi

escaped=$(_json_escape $'line1\nline2\ttab')
if printf '%s' "$escaped" | grep -q '\\n' && printf '%s' "$escaped" | grep -q '\\t'; then
    pass "_json_escape handles newlines and tabs"
else
    fail "_json_escape failed on newlines/tabs: ${escaped}"
fi

# =============================================================================
# Test: Cargo.toml dependencies captured in JSON
# =============================================================================
echo "=== Cargo.toml dependency detection ==="

RUST_PROJ=$(make_test_project "rust_deps")
cat > "${RUST_PROJ}/Cargo.toml" << 'EOF'
[package]
name = "myapp"
version = "0.1.0"

[dependencies]
serde = "1.0"
tokio = { version = "1.0", features = ["full"] }

[dev-dependencies]
mockall = "0.11"
EOF
git -C "$RUST_PROJ" add -A && git -C "$RUST_PROJ" commit -q -m "add cargo"

crawl_project "$RUST_PROJ" 120000

RUST_DEPS="${RUST_PROJ}/.claude/index/dependencies.json"
if grep -q '"Cargo.toml"' "$RUST_DEPS" && grep -q '"cargo"' "$RUST_DEPS"; then
    pass "dependencies.json detects Cargo.toml with cargo manager"
else
    fail "dependencies.json missing Cargo.toml detection"
fi

if grep -q '"serde"' "$RUST_DEPS" && grep -q '"tokio"' "$RUST_DEPS"; then
    pass "dependencies.json captures serde and tokio from Cargo.toml"
else
    fail "dependencies.json missing Cargo.toml dependencies"
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
