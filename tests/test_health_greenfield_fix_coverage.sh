#!/usr/bin/env bash
# Test: Greenfield scoring fixes (health scoring false inflation bug)
# Verifies that code_quality and dependency_health return 0 on greenfield projects
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Minimal stubs for common.sh functions ---
log() { :; }
warn() { :; }
error() { :; }
success() { :; }
header() { :; }
RED='' GREEN='' YELLOW='' BOLD='' NC=''

export TEKHTON_HOME

# Source health modules
source "${TEKHTON_HOME}/lib/health.sh"

PASS=0
FAIL=0

# Test helpers
assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected to find '$needle' in '$haystack'" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_json_field() {
    local label="$1" json="$2" field="$3" expected="$4"
    local actual
    actual=$(echo "$json" | grep -oE "\"${field}\":[0-9]+" | grep -oE '[0-9]+' || echo "NOT_FOUND")
    if [[ "$actual" == "$expected" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected field '${field}' to be '${expected}', got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Setup: Create test environments
# ============================================================================

# Greenfield: empty project with just git and README
GREENFIELD_DIR="$TMPDIR/greenfield"
mkdir -p "$GREENFIELD_DIR"
cd "$GREENFIELD_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "# New Project" > README.md
git add . && git commit -q -m "init"

# Greenfield with manifest: no code but has package.json
WITH_MANIFEST_DIR="$TMPDIR/with_manifest"
mkdir -p "$WITH_MANIFEST_DIR"
cd "$WITH_MANIFEST_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo '{"name":"test","version":"1.0.0"}' > package.json
echo "# Project with manifest" > README.md
git add . && git commit -q -m "init"

# Setup test environment variables
export HEALTH_ENABLED=true
export HEALTH_SAMPLE_SIZE=20
export HEALTH_WEIGHT_TESTS=30
export HEALTH_WEIGHT_QUALITY=25
export HEALTH_WEIGHT_DEPS=15
export HEALTH_WEIGHT_DOCS=15
export HEALTH_WEIGHT_HYGIENE=15
export HEALTH_SHOW_BELT=true
export HEALTH_RUN_TESTS=false
export HEALTH_BASELINE_FILE=.claude/HEALTH_BASELINE.json
export HEALTH_REPORT_FILE=HEALTH_REPORT.md
export TEST_CMD=true

# ============================================================================
# Test 1: Code quality returns 0 on greenfield (no source files)
# ============================================================================

quality_result=$(_check_code_quality "$GREENFIELD_DIR")
quality_score=$(echo "$quality_result" | cut -d'|' -f2)
quality_detail=$(echo "$quality_result" | cut -d'|' -f3-)

assert_eq "greenfield code_quality score is 0" "0" "$quality_score"

# Verify all sub-scores are 0 in the JSON detail
assert_json_field "greenfield code_quality linter" "$quality_detail" "linter" "0"
assert_json_field "greenfield code_quality precommit" "$quality_detail" "precommit" "0"
assert_json_field "greenfield code_quality todo_density" "$quality_detail" "todo_density" "0"
assert_json_field "greenfield code_quality magic_numbers" "$quality_detail" "magic_numbers" "0"
assert_json_field "greenfield code_quality type_safety" "$quality_detail" "type_safety" "0"
assert_json_field "greenfield code_quality function_length" "$quality_detail" "function_length" "0"

# ============================================================================
# Test 2: Dependency health returns 0 on greenfield (no manifest)
# ============================================================================

dep_result=$(_check_dependency_health "$GREENFIELD_DIR")
dep_score=$(echo "$dep_result" | cut -d'|' -f2)
dep_detail=$(echo "$dep_result" | cut -d'|' -f3-)

assert_eq "greenfield dependency_health score is 0" "0" "$dep_score"

# Verify all sub-scores are 0
assert_json_field "greenfield dependency lock_file" "$dep_detail" "lock_file" "0"
assert_json_field "greenfield dependency dep_ratio" "$dep_detail" "dep_ratio" "0"
assert_json_field "greenfield dependency vuln_scanner" "$dep_detail" "vuln_scanner" "0"
assert_json_field "greenfield dependency manifest" "$dep_detail" "manifest" "0"

# ============================================================================
# Test 3: Dependency health with manifest but no code (keeps ratio bonus)
# ============================================================================

dep_manifest_result=$(_check_dependency_health "$WITH_MANIFEST_DIR")
dep_manifest_score=$(echo "$dep_manifest_result" | cut -d'|' -f2)
dep_manifest_detail=$(echo "$dep_manifest_result" | cut -d'|' -f3-)

# With manifest present but no source files:
# - manifest_score should be 25 (manifest exists)
# - dep_ratio_score should be 25 (manifest exists but ratio calc didn't fire,
#   so award 25 to indicate "not over-dependent" per task spec)
# Total: 0 (lock) + 25 (ratio) + 0 (vuln) + 25 (manifest) = 50
assert_eq "with_manifest dependency_health score" "50" "$dep_manifest_score"

assert_json_field "with_manifest dependency manifest" "$dep_manifest_detail" "manifest" "25"
assert_json_field "with_manifest dependency dep_ratio" "$dep_manifest_detail" "dep_ratio" "25"

# ============================================================================
# Test 4: Composite score on pure greenfield is very low
# ============================================================================

score=$(assess_project_health "$GREENFIELD_DIR")
# Greenfield should be low — essentially just README + git setup
# Expected: ~0-15 (a few points for having README + .gitignore heuristics)
if [[ "$score" -lt 20 ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: greenfield composite should be <20, got '$score'" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 5: Report contains "Pre-code baseline" callout for greenfield
# ============================================================================

report_file="$GREENFIELD_DIR/HEALTH_REPORT.md"
if grep -q "Pre-code baseline" "$report_file" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: greenfield HEALTH_REPORT.md missing 'Pre-code baseline' callout" >&2
    FAIL=$((FAIL + 1))
fi

# Verify the exact text from the implementation
if grep -q "scores reflect project setup only, not code quality" "$report_file" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: greenfield report missing full callout text" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 6: Report for project WITH manifest shows Pre-code baseline
# ============================================================================

with_manifest_score=$(assess_project_health "$WITH_MANIFEST_DIR")
with_manifest_report="$WITH_MANIFEST_DIR/HEALTH_REPORT.md"

# Since with_manifest has manifest (dep_score=50) but still no code (code_quality=0),
# it will be higher but still mostly set-up focused
# Expected: manifest(25) + dep_ratio(25) weighted by 15% + some doc/hygiene from README/git = ~10-20
if [[ "$with_manifest_score" -lt 35 ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: with_manifest score should be <35, got '$with_manifest_score'" >&2
    FAIL=$((FAIL + 1))
fi

# Should still show Pre-code baseline since source_files == 0
if grep -q "Pre-code baseline" "$with_manifest_report" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: with_manifest report should show Pre-code baseline" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 7: Verify Test Health dimension on greenfield (should be very low)
# ============================================================================

test_result=$(_check_test_health "$GREENFIELD_DIR")
test_score=$(echo "$test_result" | cut -d'|' -f2)

# No test files, so minimal score expected
if [[ "$test_score" -lt 15 ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: greenfield test_health should be low, got '$test_score'" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 8: Verify source_files count is extracted correctly in report
# ============================================================================

# After assess_project_health, baseline should have source_files count
baseline_file="$GREENFIELD_DIR/.claude/HEALTH_BASELINE.json"
if [[ -f "$baseline_file" ]]; then
    source_files_count=$(grep -oE '"source_files":[0-9]+' "$baseline_file" | grep -oE '[0-9]+' || echo "NOT_FOUND")
    assert_eq "greenfield baseline source_files count" "0" "$source_files_count"
else
    echo "FAIL: greenfield baseline file not created" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 9: Greenfield to non-greenfield progression
# ============================================================================

PROGRESSING_DIR="$TMPDIR/progressing"
mkdir -p "$PROGRESSING_DIR/src"
cd "$PROGRESSING_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "# Progress" > README.md
git add . && git commit -q -m "init"

# First assessment: no code yet
score_before=$(assess_project_health "$PROGRESSING_DIR")

# Add source file
echo 'function main() { return 42; }' > "$PROGRESSING_DIR/src/main.js"
git add . && git commit -q -m "add source"

# Second assessment: now has code
HEALTH_BASELINE_FILE=.claude/HEALTH_BASELINE_v2.json
score_after=$(assess_project_health "$PROGRESSING_DIR")

# Code quality should increase when we add a source file
quality_before=$(_check_code_quality "$PROGRESSING_DIR")
# Create a copy with linter config
cp "$PROGRESSING_DIR" "$PROGRESSING_DIR"_with_linter -r
echo '{}' > "$PROGRESSING_DIR"_with_linter/.eslintrc.json
quality_with_linter=$(_check_code_quality "$PROGRESSING_DIR"_with_linter)

# These should be different (with linter config scores higher)
quality_score_before=$(echo "$quality_before" | cut -d'|' -f2)
quality_score_with_linter=$(echo "$quality_with_linter" | cut -d'|' -f2)

if [[ "$quality_score_with_linter" -gt "$quality_score_before" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: code_quality with linter should be higher than without" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Results
# ============================================================================

echo
echo "Greenfield fix coverage tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
