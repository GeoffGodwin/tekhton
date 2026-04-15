#!/usr/bin/env bash
# Test: Project health scoring (Milestone 15)
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

# Define variables required by health library modules (normally set by run_tests.sh
# or config_defaults.sh, but must be present when tests run standalone).
TEKHTON_DIR="${TEKHTON_DIR:-.tekhton}"
DESIGN_FILE="${DESIGN_FILE:-${TEKHTON_DIR}/DESIGN.md}"
HEALTH_REPORT_FILE="${HEALTH_REPORT_FILE:-${TEKHTON_DIR}/HEALTH_REPORT.md}"

# Source health modules
source "${TEKHTON_HOME}/lib/health.sh"

PASS=0
FAIL=0

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected '${expected}', got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

assert_range() {
    local label="$1" min="$2" max="$3" actual="$4"
    if [[ "$actual" -ge "$min" ]] && [[ "$actual" -le "$max" ]]; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: ${label}: expected ${min}-${max}, got '${actual}'" >&2
        FAIL=$((FAIL + 1))
    fi
}

# ============================================================================
# Test 1: Belt mapping at all boundaries
# ============================================================================

assert_eq "belt 0" "White Belt" "$(get_health_belt 0)"
assert_eq "belt 19" "White Belt" "$(get_health_belt 19)"
assert_eq "belt 20" "Yellow Belt" "$(get_health_belt 20)"
assert_eq "belt 39" "Yellow Belt" "$(get_health_belt 39)"
assert_eq "belt 40" "Orange Belt" "$(get_health_belt 40)"
assert_eq "belt 59" "Orange Belt" "$(get_health_belt 59)"
assert_eq "belt 60" "Green Belt" "$(get_health_belt 60)"
assert_eq "belt 74" "Green Belt" "$(get_health_belt 74)"
assert_eq "belt 75" "Blue Belt" "$(get_health_belt 75)"
assert_eq "belt 89" "Blue Belt" "$(get_health_belt 89)"
assert_eq "belt 90" "Black Belt" "$(get_health_belt 90)"
assert_eq "belt 100" "Black Belt" "$(get_health_belt 100)"

# ============================================================================
# Test 2: Empty project scores near zero
# ============================================================================

EMPTY_DIR="$TMPDIR/empty_project"
mkdir -p "$EMPTY_DIR/${TEKHTON_DIR:-.tekhton}"
cd "$EMPTY_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "# Empty" > README.md
git add . && git commit -q -m "init"

HEALTH_ENABLED=true
HEALTH_SAMPLE_SIZE=20
HEALTH_WEIGHT_TESTS=30
HEALTH_WEIGHT_QUALITY=25
HEALTH_WEIGHT_DEPS=15
HEALTH_WEIGHT_DOCS=15
HEALTH_WEIGHT_HYGIENE=15
HEALTH_SHOW_BELT=true
HEALTH_RUN_TESTS=false
HEALTH_BASELINE_FILE=.claude/HEALTH_BASELINE.json
HEALTH_REPORT_FILE="${TEKHTON_DIR}/HEALTH_REPORT.md"
TEST_CMD=true

score=$(assess_project_health "$EMPTY_DIR")
# Has README.md and git, so some base docs/hygiene points
assert_range "empty project score" 0 35 "$score"

# Verify baseline file was written
if [[ -f "$EMPTY_DIR/.claude/HEALTH_BASELINE.json" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_BASELINE.json not created for empty project" >&2
    FAIL=$((FAIL + 1))
fi

# Verify report file was written
if [[ -f "$EMPTY_DIR/$HEALTH_REPORT_FILE" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: $HEALTH_REPORT_FILE not created for empty project" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 3: Well-maintained project scores high
# ============================================================================

GOOD_DIR="$TMPDIR/good_project"
mkdir -p "$GOOD_DIR"/{src,tests,.github/workflows,"${TEKHTON_DIR:-.tekhton}"}
cd "$GOOD_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"

# Source files
echo 'function main() { console.log("hello"); }' > "$GOOD_DIR/src/app.ts"
echo 'export class User { name: string; }' > "$GOOD_DIR/src/user.ts"
echo 'export function validate(x: number) { return x > 0; }' > "$GOOD_DIR/src/util.ts"

# Test files (consistent naming)
echo 'describe("app", () => { it("works", () => {}); });' > "$GOOD_DIR/tests/app.spec.ts"
echo 'describe("user", () => { it("creates", () => {}); });' > "$GOOD_DIR/tests/user.spec.ts"

# Linter config
echo '{ "extends": "eslint:recommended" }' > "$GOOD_DIR/.eslintrc.json"

# Pre-commit
mkdir -p "$GOOD_DIR/.husky"
echo '#!/bin/sh' > "$GOOD_DIR/.husky/pre-commit"

# Lock file
echo '{}' > "$GOOD_DIR/package-lock.json"
echo '{"dependencies": {"express": "^4.18.0"}}' > "$GOOD_DIR/package.json"

# Dependency scanner
echo '{}' > "$GOOD_DIR/renovate.json"

# tsconfig (type safety)
echo '{"compilerOptions": {"strict": true}}' > "$GOOD_DIR/tsconfig.json"

# README with setup instructions
cat > "$GOOD_DIR/README.md" << 'RDME'
# Good Project

A well-maintained project with all the best practices.

## Getting Started

### Installation

```bash
npm install
```

### Setup

Run `npm start` to begin development.

## Architecture

The project uses TypeScript with Express.

## Contributing

See CONTRIBUTING.md
RDME

# Architecture doc
printf '# Architecture\n\nClean architecture.\n' > "$GOOD_DIR/ARCHITECTURE.md"

# CI config
echo "name: CI" > "$GOOD_DIR/.github/workflows/ci.yml"

# Gitignore
cat > "$GOOD_DIR/.gitignore" << 'GI'
node_modules
.env
dist
GI

# Changelog
printf '# Changelog\n## 1.0.0\n- Initial release\n' > "$GOOD_DIR/CHANGELOG.md"

# Contributing guide
printf '# Contributing\n\nPlease follow the code style.\n' > "$GOOD_DIR/CONTRIBUTING.md"

git add . && git commit -q -m "init well-maintained project"

HEALTH_BASELINE_FILE=.claude/HEALTH_BASELINE.json
HEALTH_REPORT_FILE="${TEKHTON_DIR}/HEALTH_REPORT.md"

score=$(assess_project_health "$GOOD_DIR")
assert_range "good project score" 60 100 "$score"

# ============================================================================
# Test 4: Weight validation — custom weights
# ============================================================================

HEALTH_WEIGHT_TESTS=20
HEALTH_WEIGHT_QUALITY=20
HEALTH_WEIGHT_DEPS=20
HEALTH_WEIGHT_DOCS=20
HEALTH_WEIGHT_HYGIENE=20

score_custom=$(assess_project_health "$GOOD_DIR")
# With equal weights, score should still be high for a good project
assert_range "custom weights score" 50 100 "$score_custom"

# Reset weights
HEALTH_WEIGHT_TESTS=30
HEALTH_WEIGHT_QUALITY=25
HEALTH_WEIGHT_DEPS=15
HEALTH_WEIGHT_DOCS=15
HEALTH_WEIGHT_HYGIENE=15

# ============================================================================
# Test 5: Delta computation (reassess)
# ============================================================================

score_reassess=$(reassess_project_health "$GOOD_DIR")
# Score should be stable (same codebase, no changes)
assert_eq "reassess stability" "$score" "$score_reassess"

# Check that baseline has delta fields
if grep -q '"delta"' "$GOOD_DIR/.claude/HEALTH_BASELINE.json" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: reassess baseline missing delta field" >&2
    FAIL=$((FAIL + 1))
fi

if grep -q '"previous_composite"' "$GOOD_DIR/.claude/HEALTH_BASELINE.json" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: reassess baseline missing previous_composite field" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 6: HEALTH_ENABLED=false makes no-op
# ============================================================================

HEALTH_ENABLED=false
score_disabled=$(assess_project_health "$GOOD_DIR")
assert_eq "disabled returns 0" "0" "$score_disabled"
HEALTH_ENABLED=true

# ============================================================================
# Test 7: Baseline persistence
# ============================================================================

if [[ -f "$GOOD_DIR/.claude/HEALTH_BASELINE.json" ]]; then
    composite_read=$(_read_json_int "$GOOD_DIR/.claude/HEALTH_BASELINE.json" "composite")
    assert_range "baseline read composite" 1 100 "$composite_read"
else
    echo "FAIL: baseline not found for persistence test" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 8: format_health_summary returns non-empty for assessed project
# ============================================================================

summary=$(format_health_summary "$GOOD_DIR")
if [[ "$summary" == *"Health:"* ]] && [[ "$summary" == *"/100"* ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: format_health_summary output unexpected: '$summary'" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 9: .env-in-git detection (hygiene failure)
# ============================================================================

ENV_DIR="$TMPDIR/env_project"
mkdir -p "$ENV_DIR"
cd "$ENV_DIR"
git init -q
git config user.email "test@test.com"
git config user.name "Test"
echo "SECRET=abc123" > .env
git add . && git commit -q -m "oops committed .env"

hygiene_result=$(_check_project_hygiene "$ENV_DIR")
hygiene_score=$(echo "$hygiene_result" | cut -d'|' -f2)
# env_safety sub-score should be 0, driving total hygiene down
assert_range "env-in-git hygiene low" 0 60 "$hygiene_score"

# ============================================================================
# Test 10: Individual dimension checks
# ============================================================================

# Test health for project with no test files
# TEST_CMD may still be set from test env, so unset it
local_saved_test_cmd="${TEST_CMD:-}"
TEST_CMD="true"
test_result=$(_check_test_health "$EMPTY_DIR")
test_score=$(echo "$test_result" | cut -d'|' -f2)
assert_range "empty test health" 0 15 "$test_score"
TEST_CMD="$local_saved_test_cmd"

# Doc quality fallback
doc_result=$(_check_doc_quality "$EMPTY_DIR")
doc_score=$(echo "$doc_result" | cut -d'|' -f2)
assert_range "empty doc quality" 0 30 "$doc_score"

# ============================================================================
# Test 11: Greenfield code quality score is 0
# ============================================================================

quality_result=$(_check_code_quality "$EMPTY_DIR")
quality_score_direct=$(echo "$quality_result" | cut -d'|' -f2)
assert_eq "empty code_quality score" "0" "$quality_score_direct"

# ============================================================================
# Test 12: Greenfield dependency health score is 0
# ============================================================================

dep_result=$(_check_dependency_health "$EMPTY_DIR")
dep_score_direct=$(echo "$dep_result" | cut -d'|' -f2)
assert_eq "empty dependency_health score" "0" "$dep_score_direct"

# ============================================================================
# Test 13: Greenfield report contains Pre-code baseline callout
# ============================================================================

if grep -q "Pre-code baseline" "$EMPTY_DIR/$HEALTH_REPORT_FILE" 2>/dev/null; then
    PASS=$((PASS + 1))
else
    echo "FAIL: HEALTH_REPORT.md missing 'Pre-code baseline' callout for greenfield project" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Results
# ============================================================================

echo
echo "Health scoring tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
