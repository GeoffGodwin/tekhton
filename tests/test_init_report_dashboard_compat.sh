#!/usr/bin/env bash
# Test: emit_init_report_file() / emit_dashboard_init() metadata format compatibility
# Coverage gap identified by reviewer: verify HTML comment metadata block written by
# emit_init_report_file() can be correctly parsed by emit_dashboard_init().
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# --- Stub functions required by init_report.sh --------------------------------
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
# Color variables used by emit_init_summary (not emit_init_report_file, but needed for sourcing)
GREEN=""; BOLD=""; NC=""; YELLOW=""; CYAN=""; RED=""

# Source the report generator
# shellcheck source=../lib/init_report.sh
source "${TEKHTON_HOME}/lib/init_report.sh"

# --- Stubs required by dashboard_emitters.sh ----------------------------------

# is_dashboard_enabled — returns 0 (enabled) for testing
is_dashboard_enabled() { return 0; }

# _json_escape — minimal implementation for testing
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    echo "$s"
}

# _to_js_timestamp — stub
_to_js_timestamp() { echo "2026-01-01T00:00:00Z"; }

# _write_js_file — writes a simple JS file to the given path
_write_js_file() {
    local filepath="$1"
    local varname="$2"
    local json_content="$3"
    local tmpfile="${filepath}.tmp.$$"
    printf 'window.%s = %s;\n' "$varname" "$json_content" > "$tmpfile"
    mv "$tmpfile" "$filepath"
}

# Source dashboard_emitters.sh after stubs are defined
# shellcheck source=../lib/dashboard_emitters.sh
source "${TEKHTON_HOME}/lib/dashboard_emitters.sh"

# =============================================================================
# Helper: build a test project directory with dashboard data/ dir
# =============================================================================
make_project() {
    local proj_dir="$1"
    mkdir -p "${proj_dir}/.claude/dashboard/data"
    export PROJECT_DIR="$proj_dir"
    export DASHBOARD_DIR=".claude/dashboard"
    export TEKHTON_VERSION="3.22.0"
}

# =============================================================================
# Test 1: basic field round-trip
# Writes INIT_REPORT.md, parses it with emit_dashboard_init, checks fields.
# =============================================================================
echo "=== Basic field round-trip ==="

PROJ1="${TEST_TMPDIR}/proj1"
make_project "$PROJ1"

# Call emit_init_report_file with known values
languages="python|high|pyproject.toml"
frameworks="django|python|pyproject.toml"
commands="$(printf 'test|pytest|pyproject.toml|high\nanalyze|ruff check .|pyproject.toml|high')"
entry_points="src/main.py"
project_type="api-service"
file_count=42

emit_init_report_file "$PROJ1" "$languages" "$frameworks" "$commands" \
    "$entry_points" "$project_type" "$file_count"

# Verify INIT_REPORT.md was created
if [[ -f "${PROJ1}/INIT_REPORT.md" ]]; then
    pass "INIT_REPORT.md created by emit_init_report_file"
else
    fail "INIT_REPORT.md not created by emit_init_report_file"
fi

# Verify metadata block is present
if grep -q "<!-- init-report-meta" "${PROJ1}/INIT_REPORT.md"; then
    pass "HTML metadata comment block present in INIT_REPORT.md"
else
    fail "HTML metadata comment block missing from INIT_REPORT.md"
fi

# Run emit_dashboard_init to parse the file
emit_dashboard_init "$PROJ1"

init_js="${PROJ1}/.claude/dashboard/data/init.js"
if [[ -f "$init_js" ]]; then
    pass "init.js created by emit_dashboard_init"
else
    fail "init.js not created by emit_dashboard_init"
fi

# =============================================================================
# Test 2: field values extracted correctly (project name)
# =============================================================================
echo "=== Field extraction: project name ==="

# The project name comes from basename of project_dir
expected_name="proj1"
# Extract from init.js: "project":"<value>"
extracted_project=$(grep -o '"project":"[^"]*"' "$init_js" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")

if [[ "$extracted_project" == "$expected_name" ]]; then
    pass "project name extracted correctly: '${extracted_project}'"
else
    fail "project name: expected '${expected_name}', got '${extracted_project}'"
fi

# =============================================================================
# Test 3: field extraction: file count
# =============================================================================
echo "=== Field extraction: file count ==="

extracted_count=$(grep -o '"fileCount":"[^"]*"' "$init_js" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")

if [[ "$extracted_count" == "$file_count" ]]; then
    pass "file count extracted correctly: '${extracted_count}'"
else
    fail "file count: expected '${file_count}', got '${extracted_count}'"
fi

# =============================================================================
# Test 4: field extraction: project type
# =============================================================================
echo "=== Field extraction: project type ==="

extracted_type=$(grep -o '"projectType":"[^"]*"' "$init_js" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")

if [[ "$extracted_type" == "$project_type" ]]; then
    pass "project type extracted correctly: '${extracted_type}'"
else
    fail "project type: expected '${project_type}', got '${extracted_type}'"
fi

# =============================================================================
# Test 5: available flag is set
# =============================================================================
echo "=== available flag ==="

if grep -q '"available":true' "$init_js"; then
    pass "available flag is true in init.js"
else
    fail "available flag missing or false in init.js"
fi

# =============================================================================
# Test 6: missing INIT_REPORT.md — emit_dashboard_init is a no-op
# =============================================================================
echo "=== No INIT_REPORT.md: no-op ==="

PROJ2="${TEST_TMPDIR}/proj2"
make_project "$PROJ2"
# Do NOT create INIT_REPORT.md

emit_dashboard_init "$PROJ2"

init_js2="${PROJ2}/.claude/dashboard/data/init.js"
if [[ ! -f "$init_js2" ]]; then
    pass "no INIT_REPORT.md: init.js not created (correct no-op)"
else
    fail "no INIT_REPORT.md: init.js should not be created"
fi

# =============================================================================
# Test 7: missing dashboard data/ dir — emit_dashboard_init is a no-op
# =============================================================================
echo "=== No dashboard/data dir: no-op ==="

PROJ3="${TEST_TMPDIR}/proj3"
mkdir -p "$PROJ3"
export PROJECT_DIR="$PROJ3"
# Create INIT_REPORT.md but NOT the dashboard dir
emit_init_report_file "$PROJ3" "$languages" "$frameworks" "$commands" \
    "$entry_points" "$project_type" "$file_count"

emit_dashboard_init "$PROJ3"
# Should not crash — silently returns
pass "missing dashboard/data/: function returns silently without error"

# =============================================================================
# Test 8: metadata field ordering — writer and parser agree on field names
# =============================================================================
echo "=== Metadata field name alignment ==="

# Verify the exact field names written by emit_init_report_file
# match what emit_dashboard_init looks for (case-sensitive pattern match)
report_file="${PROJ1}/INIT_REPORT.md"

# Check each field name that emit_dashboard_init parses
for field in "timestamp:" "project:" "file_count:" "project_type:"; do
    if awk '/^<!-- init-report-meta/,/^-->/' "$report_file" \
        | grep -v '^<!--' | grep -v -- '^-->' \
        | grep -qE "^${field}"; then
        pass "field '${field}' present in metadata block with correct format"
    else
        fail "field '${field}' missing or malformed in INIT_REPORT.md metadata block"
    fi
done

# =============================================================================
# Test 9: timestamp field is populated and parseable
# =============================================================================
echo "=== Timestamp field ==="

extracted_ts=$(grep -o '"timestamp":"[^"]*"' "$init_js" 2>/dev/null | head -1 | cut -d'"' -f4 || echo "")

if [[ -n "$extracted_ts" ]]; then
    pass "timestamp field populated: '${extracted_ts}'"
else
    fail "timestamp field empty in init.js"
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
