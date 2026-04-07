#!/usr/bin/env bash
# Test: _check_code_quality() dimension sub-scores (Milestone 15)
#
# Covers: linter config, pre-commit hooks, TODO density, magic number density,
#         type safety, function length, and output format.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stubs for common.sh functions (health.sh expects these in scope)
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
RED='' GREEN='' YELLOW='' BOLD='' NC=''

export TEKHTON_HOME

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

# Helper: extract a named integer sub-score from the JSON details field
# Usage: extract_sub RESULT_STRING "linter"
extract_sub() {
    local result="$1" key="$2"
    echo "$result" | grep -oE "\"${key}\":[0-9]+" | grep -oE '[0-9]+$' | head -1
}

# Helper: create an isolated git repo
make_git_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q
    git -C "$d" config user.email "test@test.com"
    git -C "$d" config user.name "Test"
}

HEALTH_SAMPLE_SIZE=20

# ============================================================================
# Test 1: Linter config sub-score — absent (0) vs present (20)
# ============================================================================

LINT_DIR="$TMPDIR/linter"
make_git_repo "$LINT_DIR"
echo 'function foo() {}' > "$LINT_DIR/app.js"
git -C "$LINT_DIR" add . && git -C "$LINT_DIR" commit -q -m "init"

result=$(_check_code_quality "$LINT_DIR")
linter=$(extract_sub "$result" "linter")
assert_eq "linter absent → 0" "0" "$linter"

# Add .eslintrc.json
echo '{"extends":"recommended"}' > "$LINT_DIR/.eslintrc.json"
git -C "$LINT_DIR" add . && git -C "$LINT_DIR" commit -q -m "add eslint"
result=$(_check_code_quality "$LINT_DIR")
linter=$(extract_sub "$result" "linter")
assert_eq "linter .eslintrc.json → 20" "20" "$linter"

# ============================================================================
# Test 2: Linter config sub-score — .pylintrc variant
# ============================================================================

PY_DIR="$TMPDIR/pylint"
make_git_repo "$PY_DIR"
echo '.pylintrc placeholder' > "$PY_DIR/.pylintrc"
echo 'x = 1' > "$PY_DIR/app.py"
git -C "$PY_DIR" add . && git -C "$PY_DIR" commit -q -m "init"

result=$(_check_code_quality "$PY_DIR")
linter=$(extract_sub "$result" "linter")
assert_eq "linter .pylintrc → 20" "20" "$linter"

# ============================================================================
# Test 3: Pre-commit hooks sub-score — absent (0)
# ============================================================================

PC_DIR="$TMPDIR/precommit"
make_git_repo "$PC_DIR"
echo 'x = 1' > "$PC_DIR/app.py"
git -C "$PC_DIR" add . && git -C "$PC_DIR" commit -q -m "init"

result=$(_check_code_quality "$PC_DIR")
pc=$(extract_sub "$result" "precommit")
assert_eq "precommit absent → 0" "0" "$pc"

# ============================================================================
# Test 4: Pre-commit hooks sub-score — .pre-commit-config.yaml (10)
# ============================================================================

echo "repos: []" > "$PC_DIR/.pre-commit-config.yaml"
result=$(_check_code_quality "$PC_DIR")
pc=$(extract_sub "$result" "precommit")
assert_eq "precommit yaml → 10" "10" "$pc"

# ============================================================================
# Test 5: Pre-commit hooks sub-score — .husky/pre-commit (10)
# ============================================================================

HUSKY_DIR="$TMPDIR/husky"
make_git_repo "$HUSKY_DIR"
mkdir -p "$HUSKY_DIR/.husky"
echo '#!/bin/sh' > "$HUSKY_DIR/.husky/pre-commit"
echo 'x = 1' > "$HUSKY_DIR/app.py"
git -C "$HUSKY_DIR" add . && git -C "$HUSKY_DIR" commit -q -m "init"

result=$(_check_code_quality "$HUSKY_DIR")
pc=$(extract_sub "$result" "precommit")
assert_eq "precommit husky → 10" "10" "$pc"

# ============================================================================
# Test 6: TODO density sub-score — high density → low score
# ============================================================================

TODO_DIR="$TMPDIR/todo_heavy"
make_git_repo "$TODO_DIR"

# 50 TODOs in 100 lines ≈ 500 per 1000 → well above 20/1000 threshold → score 0
{
    for i in $(seq 1 50); do
        echo "# TODO fix line $i"
        echo "x = $i"
    done
} > "$TODO_DIR/heavy.py"
git -C "$TODO_DIR" add . && git -C "$TODO_DIR" commit -q -m "init"

result=$(_check_code_quality "$TODO_DIR")
todo=$(extract_sub "$result" "todo_density")
assert_range "high TODO density → 0-5" 0 5 "$todo"

# ============================================================================
# Test 7: TODO density sub-score — zero density → 20
# ============================================================================

CLEAN_DIR="$TMPDIR/clean"
make_git_repo "$CLEAN_DIR"
{
    echo "def add(a, b):"
    echo "    return a + b"
    echo "def sub(a, b):"
    echo "    return a - b"
} > "$CLEAN_DIR/math.py"
git -C "$CLEAN_DIR" add . && git -C "$CLEAN_DIR" commit -q -m "init"

result=$(_check_code_quality "$CLEAN_DIR")
todo=$(extract_sub "$result" "todo_density")
assert_eq "zero TODO density → 20" "20" "$todo"

# ============================================================================
# Test 8: Magic number density sub-score — high density → reduced score
# ============================================================================

MAGIC_DIR="$TMPDIR/magic"
make_git_repo "$MAGIC_DIR"

# Generate file with many non-standard numbers (3+ digits, not in exclusion list)
{
    echo "def process():"
    for i in $(seq 1 30); do
        val=$(( i * 37 + 123 ))   # 3-digit numbers not in the exclude list
        echo "    result = ${val}"
    done
} > "$MAGIC_DIR/numbers.py"
git -C "$MAGIC_DIR" add . && git -C "$MAGIC_DIR" commit -q -m "init"

result=$(_check_code_quality "$MAGIC_DIR")
magic=$(extract_sub "$result" "magic_numbers")
# High magic number density should be penalized (not max 20)
assert_range "high magic density → 0-15" 0 15 "$magic"

# ============================================================================
# Test 9: Magic number density sub-score — no magic numbers → 20
# ============================================================================

result=$(_check_code_quality "$CLEAN_DIR")
magic=$(extract_sub "$result" "magic_numbers")
assert_eq "no magic numbers → 20" "20" "$magic"

# ============================================================================
# Test 10: Type safety — TypeScript source files → 15
# ============================================================================

TS_DIR="$TMPDIR/typescript"
make_git_repo "$TS_DIR"
echo 'export const foo = (): void => {}' > "$TS_DIR/app.ts"
echo 'export interface User { name: string; }' > "$TS_DIR/user.ts"
git -C "$TS_DIR" add . && git -C "$TS_DIR" commit -q -m "init"

result=$(_check_code_quality "$TS_DIR")
type_safety=$(extract_sub "$result" "type_safety")
assert_eq "TypeScript type safety → 15" "15" "$type_safety"

# ============================================================================
# Test 11: Type safety — plain JS, no tsconfig → 0
# ============================================================================

JS_DIR="$TMPDIR/plainjs"
make_git_repo "$JS_DIR"
echo 'const foo = () => {}' > "$JS_DIR/app.js"
git -C "$JS_DIR" add . && git -C "$JS_DIR" commit -q -m "init"

result=$(_check_code_quality "$JS_DIR")
type_safety=$(extract_sub "$result" "type_safety")
assert_eq "plain JS no tsconfig type safety → 0" "0" "$type_safety"

# ============================================================================
# Test 12: Type safety — Go source files → 15
# ============================================================================

GO_DIR="$TMPDIR/golang"
make_git_repo "$GO_DIR"
echo 'package main' > "$GO_DIR/main.go"
echo 'func hello() string { return "hi" }' >> "$GO_DIR/main.go"
git -C "$GO_DIR" add . && git -C "$GO_DIR" commit -q -m "init"

result=$(_check_code_quality "$GO_DIR")
type_safety=$(extract_sub "$result" "type_safety")
assert_eq "Go type safety → 15" "15" "$type_safety"

# ============================================================================
# Test 13: Output format — dimension name, score numeric, details JSON
# ============================================================================

result=$(_check_code_quality "$CLEAN_DIR")
dimension=$(echo "$result" | cut -d'|' -f1)
score=$(echo "$result" | cut -d'|' -f2)
details=$(echo "$result" | cut -d'|' -f3-)

assert_eq "dimension name" "code_quality" "$dimension"

if [[ "$score" =~ ^[0-9]+$ ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: code_quality score not numeric: '${score}'" >&2
    FAIL=$((FAIL + 1))
fi

if [[ "$details" == "{"* ]] && [[ "$details" == *"}" ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: code_quality details not JSON object: '${details}'" >&2
    FAIL=$((FAIL + 1))
fi

# ============================================================================
# Test 14: Score is capped at 100
# ============================================================================

# A project with every possible quality signal — score should be <= 100
PERFECT_DIR="$TMPDIR/perfect"
make_git_repo "$PERFECT_DIR"
echo '{"extends":"recommended"}' > "$PERFECT_DIR/.eslintrc.json"
echo "repos: []" > "$PERFECT_DIR/.pre-commit-config.yaml"
echo '{"compilerOptions":{"strict":true}}' > "$PERFECT_DIR/tsconfig.json"
echo 'export const add = (a: number, b: number): number => a + b;' > "$PERFECT_DIR/app.ts"
git -C "$PERFECT_DIR" add . && git -C "$PERFECT_DIR" commit -q -m "init"

result=$(_check_code_quality "$PERFECT_DIR")
score=$(echo "$result" | cut -d'|' -f2)
assert_range "score capped at 100" 0 100 "$score"

# ============================================================================
# Results
# ============================================================================

echo
echo "Code quality tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
