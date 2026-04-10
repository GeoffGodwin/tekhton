#!/usr/bin/env bash
# Test: _check_dependency_health() dimension sub-scores (Milestone 15)
#
# Covers: lock file absent/present/committed, dep ratio, vulnerability scanner,
#         manifest file presence, various lock file types, and output format.
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Stubs for common.sh functions
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

# ============================================================================
# Test 1: Empty project — no lock, no manifest, no vuln scanner
# ============================================================================

EMPTY_DIR="$TMPDIR/empty"
make_git_repo "$EMPTY_DIR"
echo "# empty" > "$EMPTY_DIR/README.md"
git -C "$EMPTY_DIR" add . && git -C "$EMPTY_DIR" commit -q -m "init"

result=$(_check_dependency_health "$EMPTY_DIR")
dimension=$(echo "$result" | cut -d'|' -f1)
lock=$(extract_sub "$result" "lock_file")
manifest=$(extract_sub "$result" "manifest")
vuln=$(extract_sub "$result" "vuln_scanner")

assert_eq "dimension name" "dependency_health" "$dimension"
assert_eq "empty: lock absent → 0" "0" "$lock"
assert_eq "empty: manifest absent → 0" "0" "$manifest"
assert_eq "empty: vuln scanner absent → 0" "0" "$vuln"

# ============================================================================
# Test 2: Lock file present but NOT committed to git → lock_score = 15
# ============================================================================

UNCOMMIT_DIR="$TMPDIR/uncommitted"
make_git_repo "$UNCOMMIT_DIR"
echo '{"name":"test"}' > "$UNCOMMIT_DIR/package.json"
git -C "$UNCOMMIT_DIR" add . && git -C "$UNCOMMIT_DIR" commit -q -m "init"
# Create lock AFTER commit — not tracked
echo '{}' > "$UNCOMMIT_DIR/package-lock.json"

result=$(_check_dependency_health "$UNCOMMIT_DIR")
lock=$(extract_sub "$result" "lock_file")
assert_eq "lock present but uncommitted → 15" "15" "$lock"

# ============================================================================
# Test 3: Lock file committed to git → lock_score = 25
# ============================================================================

COMMIT_DIR="$TMPDIR/committed"
make_git_repo "$COMMIT_DIR"
echo '{"name":"test"}' > "$COMMIT_DIR/package.json"
echo '{}' > "$COMMIT_DIR/package-lock.json"
git -C "$COMMIT_DIR" add . && git -C "$COMMIT_DIR" commit -q -m "init"

result=$(_check_dependency_health "$COMMIT_DIR")
lock=$(extract_sub "$result" "lock_file")
assert_eq "lock committed → 25" "25" "$lock"

# ============================================================================
# Test 4: package.json manifest detected → manifest_score = 25
# ============================================================================

result=$(_check_dependency_health "$COMMIT_DIR")
manifest=$(extract_sub "$result" "manifest")
assert_eq "package.json manifest → 25" "25" "$manifest"

# ============================================================================
# Test 5: Vulnerability scanner — renovate.json → vuln_score = 25
# ============================================================================

RENOVATE_DIR="$TMPDIR/renovate"
make_git_repo "$RENOVATE_DIR"
echo '{}' > "$RENOVATE_DIR/renovate.json"
git -C "$RENOVATE_DIR" add . && git -C "$RENOVATE_DIR" commit -q -m "init"

result=$(_check_dependency_health "$RENOVATE_DIR")
vuln=$(extract_sub "$result" "vuln_scanner")
assert_eq "renovate.json → vuln 25" "25" "$vuln"

# ============================================================================
# Test 6: Vulnerability scanner — .snyk → vuln_score = 25
# ============================================================================

SNYK_DIR="$TMPDIR/snyk"
make_git_repo "$SNYK_DIR"
echo '{}' > "$SNYK_DIR/.snyk"
git -C "$SNYK_DIR" add . && git -C "$SNYK_DIR" commit -q -m "init"

result=$(_check_dependency_health "$SNYK_DIR")
vuln=$(extract_sub "$result" "vuln_scanner")
assert_eq ".snyk → vuln 25" "25" "$vuln"

# ============================================================================
# Test 7: Vulnerability scanner — .github/dependabot.yml → vuln_score = 25
# ============================================================================

DEPEND_DIR="$TMPDIR/dependabot"
make_git_repo "$DEPEND_DIR"
mkdir -p "$DEPEND_DIR/.github"
echo 'version: 2' > "$DEPEND_DIR/.github/dependabot.yml"
git -C "$DEPEND_DIR" add . && git -C "$DEPEND_DIR" commit -q -m "init"

result=$(_check_dependency_health "$DEPEND_DIR")
vuln=$(extract_sub "$result" "vuln_scanner")
assert_eq "dependabot.yml → vuln 25" "25" "$vuln"

# ============================================================================
# Test 8: Various manifest formats — pyproject.toml
# ============================================================================

PY_DIR="$TMPDIR/pyproject"
make_git_repo "$PY_DIR"
echo '[project]' > "$PY_DIR/pyproject.toml"
git -C "$PY_DIR" add . && git -C "$PY_DIR" commit -q -m "init"

result=$(_check_dependency_health "$PY_DIR")
manifest=$(extract_sub "$result" "manifest")
assert_eq "pyproject.toml manifest → 25" "25" "$manifest"

# ============================================================================
# Test 9: Various manifest formats — Cargo.toml
# ============================================================================

RUST_DIR="$TMPDIR/cargo"
make_git_repo "$RUST_DIR"
echo '[package]' > "$RUST_DIR/Cargo.toml"
git -C "$RUST_DIR" add . && git -C "$RUST_DIR" commit -q -m "init"

result=$(_check_dependency_health "$RUST_DIR")
manifest=$(extract_sub "$result" "manifest")
assert_eq "Cargo.toml manifest → 25" "25" "$manifest"

# ============================================================================
# Test 10: Various lock file types — yarn.lock
# ============================================================================

YARN_DIR="$TMPDIR/yarn"
make_git_repo "$YARN_DIR"
echo '# yarn lockfile v1' > "$YARN_DIR/yarn.lock"
git -C "$YARN_DIR" add . && git -C "$YARN_DIR" commit -q -m "init"

result=$(_check_dependency_health "$YARN_DIR")
lock=$(extract_sub "$result" "lock_file")
assert_eq "yarn.lock committed → 25" "25" "$lock"

# ============================================================================
# Test 11: Dep ratio — no source files → dep_ratio stays at default (25)
# ============================================================================

# In COMMIT_DIR: only package.json and package-lock.json, no .ts/.js/.py etc.
# src_count = 0, so dep_ratio_score remains at default 25
result=$(_check_dependency_health "$COMMIT_DIR")
dep_ratio=$(extract_sub "$result" "dep_ratio")
assert_eq "no source files → dep_ratio 25" "25" "$dep_ratio"

# ============================================================================
# Test 12: Full score composition — lock(25)+manifest(25)+dep_ratio(25)+vuln(0)=75
# ============================================================================

result=$(_check_dependency_health "$COMMIT_DIR")
score=$(echo "$result" | cut -d'|' -f2)
# lock=25 (committed), manifest=25 (package.json), dep_ratio=25, vuln=0
assert_eq "composition: lock+manifest+dep_ratio" "75" "$score"

# ============================================================================
# Test 13: Output format — score numeric, details contains all sub-score keys
# ============================================================================

result=$(_check_dependency_health "$COMMIT_DIR")
score=$(echo "$result" | cut -d'|' -f2)
details=$(echo "$result" | cut -d'|' -f3-)

if [[ "$score" =~ ^[0-9]+$ ]]; then
    PASS=$((PASS + 1))
else
    echo "FAIL: dependency_health score not numeric: '${score}'" >&2
    FAIL=$((FAIL + 1))
fi

for key in "lock_file" "dep_ratio" "vuln_scanner" "manifest"; do
    if echo "$details" | grep -q "\"${key}\""; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: details missing key '${key}': ${details}" >&2
        FAIL=$((FAIL + 1))
    fi
done

# ============================================================================
# Test 14: Dep ratio boundary — ratio=50 scores 25, ratio>50 scores 20
# ============================================================================

# ratio=50: 1 dep, 2 source files → (1*100)/2 = 50 → dep_ratio_score=25
RATIO50_DIR="$TMPDIR/ratio50"
make_git_repo "$RATIO50_DIR"
printf 'module test\n\nrequire (\n\texample.com/pkg v1.0.0\n)\n' > "$RATIO50_DIR/go.mod"
echo 'package main' > "$RATIO50_DIR/main.go"
echo 'package main' > "$RATIO50_DIR/util.go"
git -C "$RATIO50_DIR" add . && git -C "$RATIO50_DIR" commit -q -m "init"

result=$(_check_dependency_health "$RATIO50_DIR")
dep_ratio=$(extract_sub "$result" "dep_ratio")
assert_eq "ratio=50 boundary → dep_ratio 25" "25" "$dep_ratio"

# ratio=100: 1 dep, 1 source file → (1*100)/1 = 100 → dep_ratio_score=20
RATIO100_DIR="$TMPDIR/ratio100"
make_git_repo "$RATIO100_DIR"
printf 'module test\n\nrequire (\n\texample.com/pkg v1.0.0\n)\n' > "$RATIO100_DIR/go.mod"
echo 'package main' > "$RATIO100_DIR/main.go"
git -C "$RATIO100_DIR" add . && git -C "$RATIO100_DIR" commit -q -m "init"

result=$(_check_dependency_health "$RATIO100_DIR")
dep_ratio=$(extract_sub "$result" "dep_ratio")
assert_eq "ratio=100 → dep_ratio 20" "20" "$dep_ratio"

# ============================================================================
# Results
# ============================================================================

echo
echo "Dependency health tests: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
