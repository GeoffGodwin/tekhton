#!/usr/bin/env bash
# Test: m43 — multi-entry VERSION_FILES + post-bump consistency self-check
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Isolate from any parent pipeline state.
unset PROJECT_DIR MILESTONE_DIR MILESTONE_MANIFEST TEKHTON_DIR 2>/dev/null || true

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stubs the helpers under test reference.
log()        { :; }
warn()       { :; }
error()      { :; }
success()    { :; }
header()     { :; }
log_verbose(){ :; }

# trip_commit_gate stub — records calls so we can assert.
_TRIP_REASONS_FILE=$(mktemp)
trip_commit_gate() {
    echo "$1" >> "$_TRIP_REASONS_FILE"
    return 0
}

# Source the libs in the same order tekhton-legacy.sh does.
# shellcheck source=../lib/project_version.sh
source "${TEKHTON_HOME}/lib/project_version.sh"
# shellcheck source=../lib/project_version_bump.sh
source "${TEKHTON_HOME}/lib/project_version_bump.sh"
# shellcheck source=../lib/project_version_bump_helpers.sh
source "${TEKHTON_HOME}/lib/project_version_bump_helpers.sh"
# shellcheck source=../lib/project_version_verify.sh
source "${TEKHTON_HOME}/lib/project_version_verify.sh"

# =============================================================================
# _parse_version_files_list — separator + whitespace handling
# =============================================================================
echo "=== _parse_version_files_list ==="

result=$(_parse_version_files_list "package.json:.version;Cargo.toml:.package.version")
expected="package.json:.version
Cargo.toml:.package.version"
if [[ "$result" == "$expected" ]]; then pass "semicolon-separated split"; else fail "semicolon split: got '$result'"; fi

# Newline-separated.
result=$(_parse_version_files_list "$(printf 'a.toml:.v\nb.json:.version\n')")
expected="a.toml:.v
b.json:.version"
if [[ "$result" == "$expected" ]]; then pass "newline-separated split"; else fail "newline split: got '$result'"; fi

# Mixed separators + whitespace trimmed + empty entries skipped.
result=$(_parse_version_files_list "  a:.v ; ; b:.w
   c:.x
")
expected="a:.v
b:.w
c:.x"
if [[ "$result" == "$expected" ]]; then pass "mixed separators + trim + empty skip"; else fail "mixed: got '$result'"; fi

# Output array form via nameref.
declare -a out=()
_parse_version_files_list "x:.a;y:.b" out
if [[ "${#out[@]}" -eq 2 && "${out[0]}" == "x:.a" && "${out[1]}" == "y:.b" ]]; then
    pass "nameref output populates array"
else
    fail "nameref output: ${out[*]}"
fi

# =============================================================================
# Multi-file bump — Cargo + non-root package.json synced to same version
# =============================================================================
echo "=== multi-file bump: Cargo + package.json ==="

PROJ="${TEST_TMPDIR}/multifile"
mkdir -p "$PROJ/.claude" "$PROJ/bindings/wasm/pkg-template"
cat > "$PROJ/Cargo.toml" <<'TOML'
[workspace.package]
version = "0.4.2"
TOML
cat > "$PROJ/bindings/wasm/pkg-template/package.json" <<'JSON'
{
  "name": "@scope/wasm-binding",
  "version": "0.4.2",
  "main": "index.js"
}
JSON
cat > "$PROJ/.claude/project_version.cfg" <<EOF
VERSION_STRATEGY=semver
VERSION_FILES=Cargo.toml:.workspace.package.version;bindings/wasm/pkg-template/package.json:.version
CURRENT_VERSION=0.4.2
EOF

# Override the version-from-first-file detector path: the first declared
# file is Cargo.toml; _detect_version_from_file with toml_version pulls
# the `version = "X"` line directly. Both files start at 0.4.2 so user
# pre-bump detection is a no-op.
PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch"

if grep -q 'version = "0.4.3"' "$PROJ/Cargo.toml"; then
    pass "multi-file bump: Cargo.toml bumped 0.4.2 → 0.4.3"
else
    fail "multi-file bump: Cargo.toml not bumped: $(grep version "$PROJ/Cargo.toml")"
fi

if grep -q '"version": "0.4.3"' "$PROJ/bindings/wasm/pkg-template/package.json"; then
    pass "multi-file bump: non-root package.json synced to 0.4.3"
else
    fail "multi-file bump: package.json not synced: $(grep version "$PROJ/bindings/wasm/pkg-template/package.json")"
fi

# Cache moved forward.
cached=$(grep CURRENT_VERSION "$PROJ/.claude/project_version.cfg" | sed 's/CURRENT_VERSION=//')
if [[ "$cached" == "0.4.3" ]]; then pass "multi-file bump: cache CURRENT_VERSION=0.4.3"; else fail "cache: $cached"; fi

# Verify did NOT trip the commit gate (everything is in sync).
if [[ ! -s "$_TRIP_REASONS_FILE" ]]; then
    pass "multi-file bump in sync: commit gate not tripped"
else
    fail "multi-file bump in sync: commit gate tripped with: $(cat "$_TRIP_REASONS_FILE")"
fi
: > "$_TRIP_REASONS_FILE"

# =============================================================================
# Desync detection — bumper writes one file but not the other, verify trips
# =============================================================================
echo "=== desync detection ==="

PROJ="${TEST_TMPDIR}/desync"
mkdir -p "$PROJ/.claude"
# bindings/secondary/package.json declared in config but does NOT exist;
# the verify step should treat missing files as a non-blocking miss
# (operator templates may declare files that don't materialise on every
# branch). To produce a real desync we instead put two files in conflict.
cat > "$PROJ/Cargo.toml" <<'TOML'
[package]
version = "1.0.0"
TOML
mkdir -p "$PROJ/sub"
# Pre-write the secondary file with a DIFFERENT version so bumper has
# nothing to match against ('${OLD}' won't be found in it).
cat > "$PROJ/sub/package.json" <<'JSON'
{"name":"sub","version":"9.9.9"}
JSON
cat > "$PROJ/.claude/project_version.cfg" <<EOF
VERSION_STRATEGY=semver
VERSION_FILES=Cargo.toml:.package.version;sub/package.json:.version
CURRENT_VERSION=1.0.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "patch" || true

# Cargo.toml should have bumped; sub/package.json wasn't matched so stays 9.9.9.
if grep -q 'version = "1.0.1"' "$PROJ/Cargo.toml"; then
    pass "desync: Cargo.toml bumped 1.0.0 → 1.0.1"
else
    fail "desync: Cargo.toml: $(grep version "$PROJ/Cargo.toml")"
fi

# Commit gate should have been tripped with the desync reason.
if grep -q '^version_files_desynced_' "$_TRIP_REASONS_FILE" 2>/dev/null; then
    pass "desync: commit gate tripped with version_files_desynced_* reason"
else
    fail "desync: commit gate NOT tripped (file contents: $(cat "$_TRIP_REASONS_FILE" 2>/dev/null))"
fi
: > "$_TRIP_REASONS_FILE"

# =============================================================================
# Backward compat — single-file VERSION_FILES still works
# =============================================================================
echo "=== single-file backward compat ==="

PROJ="${TEST_TMPDIR}/single"
mkdir -p "$PROJ/.claude"
echo "2.0.0" > "$PROJ/VERSION"
cat > "$PROJ/.claude/project_version.cfg" <<'EOF'
VERSION_STRATEGY=semver
VERSION_FILES=VERSION:.
CURRENT_VERSION=2.0.0
EOF

PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_ENABLED="true" bump_version_files "minor"

new_ver=$(tr -d '[:space:]' < "$PROJ/VERSION")
if [[ "$new_ver" == "2.1.0" ]]; then pass "single-file VERSION bumped to 2.1.0"; else fail "single-file: $new_ver"; fi
if [[ ! -s "$_TRIP_REASONS_FILE" ]]; then
    pass "single-file in sync: commit gate not tripped"
else
    fail "single-file: commit gate tripped: $(cat "$_TRIP_REASONS_FILE")"
fi
: > "$_TRIP_REASONS_FILE"

# =============================================================================
# verify_version_files_synced — missing files are not a desync
# =============================================================================
echo "=== verify_version_files_synced: missing files ==="

PROJ="${TEST_TMPDIR}/missing"
mkdir -p "$PROJ"
echo "3.0.0" > "$PROJ/VERSION"

PROJECT_DIR="$PROJ" verify_version_files_synced "3.0.0" \
    "VERSION:." "does-not-exist/package.json:.version"
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "verify: missing declared file is non-blocking"
else
    fail "verify: missing file reported as desync (rc=$rc)"
fi
if [[ ! -s "$_TRIP_REASONS_FILE" ]]; then
    pass "verify: missing-only case did not trip commit gate"
else
    fail "verify: missing file tripped commit gate: $(cat "$_TRIP_REASONS_FILE")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

rm -f "$_TRIP_REASONS_FILE"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
