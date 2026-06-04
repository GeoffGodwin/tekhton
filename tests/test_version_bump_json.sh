#!/usr/bin/env bash
# Test: m43 — format-preserving JSON version bump + auto-discovery
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

unset PROJECT_DIR MILESTONE_DIR MILESTONE_MANIFEST TEKHTON_DIR 2>/dev/null || true

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

log()        { :; }
warn()       { :; }
error()      { :; }
success()    { :; }
header()     { :; }
log_verbose(){ :; }

trip_commit_gate() { :; }

# shellcheck source=../lib/project_version.sh
source "${TEKHTON_HOME}/lib/project_version.sh"
# shellcheck source=../lib/project_version_bump.sh
source "${TEKHTON_HOME}/lib/project_version_bump.sh"
# shellcheck source=../lib/project_version_bump_helpers.sh
source "${TEKHTON_HOME}/lib/project_version_bump_helpers.sh"
# shellcheck source=../lib/project_version_verify.sh
source "${TEKHTON_HOME}/lib/project_version_verify.sh"

# =============================================================================
# _bump_json_version — format preservation
# =============================================================================
echo "=== _bump_json_version: format preservation ==="

JFILE="${TEST_TMPDIR}/format.json"
# Author-written shape: 4-space indent, trailing comma stripped, custom key
# order, blank line at the bottom.
cat > "$JFILE" <<'JSON'
{
    "name": "@scope/widget",
    "version": "0.1.0",
    "description": "format-canary",
    "main": "src/index.js",
    "scripts": {
        "build": "tsc"
    }
}
JSON

# Snapshot before for byte-level comparison.
BEFORE_FILE=$(mktemp)
cp "$JFILE" "$BEFORE_FILE"

_bump_json_version "$JFILE" "0.1.0" "0.1.1"

# Only the version line should differ. Count: every changed line should
# contain "version".
diff_changed=$(diff "$BEFORE_FILE" "$JFILE" | grep -cE '^[<>] ' || true)
diff_version_lines=$(diff "$BEFORE_FILE" "$JFILE" | grep -cE '^[<>] .*"version"' || true)
if [[ "$diff_changed" -eq 2 && "$diff_version_lines" -eq 2 ]]; then
    pass "format preservation: only the version line changed (2/2 changed lines mention version)"
else
    fail "format preservation: changed=$diff_changed version=$diff_version_lines (want 2/2)"
    diff "$BEFORE_FILE" "$JFILE"
fi
rm -f "$BEFORE_FILE"

# Key order must be preserved.
expected_keys="name version description main scripts"
actual_keys=$(grep -oE '^\s*"[a-z]+":' "$JFILE" | sed 's/[[:space:]]//g; s/[":]//g' | head -5 | tr '\n' ' ' | sed 's/ $//')
if [[ "$actual_keys" == "$expected_keys" ]]; then
    pass "format preservation: key order preserved ($actual_keys)"
else
    fail "format preservation: key order changed (got '$actual_keys', want '$expected_keys')"
fi

# Indent (4 spaces) must be preserved.
if grep -q '^    "version": "0.1.1"' "$JFILE"; then
    pass "format preservation: 4-space indent preserved"
else
    fail "format preservation: indent changed: $(grep version "$JFILE")"
fi

# Trailing newline-only line preserved.
if [[ "$(tail -c 1 "$JFILE" | od -An -c)" == "  \n" ]]; then
    pass "format preservation: trailing newline preserved"
else
    fail "format preservation: trailing newline lost"
fi

# =============================================================================
# _bump_json_version — single-line / compact shape
# =============================================================================
echo "=== _bump_json_version: compact JSON ==="

JFILE="${TEST_TMPDIR}/compact.json"
echo '{"name":"x","version":"1.0.0","main":"i.js"}' > "$JFILE"
_bump_json_version "$JFILE" "1.0.0" "1.0.1"

if grep -q '{"name":"x","version": "1.0.1","main":"i.js"}' "$JFILE"; then
    pass "compact JSON: single-line bump preserves surrounding fields"
else
    fail "compact JSON: $(cat "$JFILE")"
fi

# =============================================================================
# _bump_json_version — non-matching old version is a no-op
# =============================================================================
echo "=== _bump_json_version: non-matching old version ==="

JFILE="${TEST_TMPDIR}/nomatch.json"
echo '{"version":"5.0.0"}' > "$JFILE"
_bump_json_version "$JFILE" "1.0.0" "1.0.1"
if grep -q '"version":"5.0.0"' "$JFILE"; then
    pass "non-match: file unchanged when old_version does not match"
else
    fail "non-match: $(cat "$JFILE")"
fi

# =============================================================================
# _bump_single_file routes package.json → JSON bumper
# =============================================================================
echo "=== _bump_single_file routes package.json ==="

JFILE="${TEST_TMPDIR}/route.json"
mv "${TEST_TMPDIR}/format.json" "$JFILE" 2>/dev/null || cat > "$JFILE" <<'JSON'
{
    "name": "@scope/widget",
    "version": "0.1.1",
    "description": "format-canary"
}
JSON
# Rename to package.json so _bump_single_file picks the json branch.
mv "$JFILE" "${TEST_TMPDIR}/package.json"
JFILE="${TEST_TMPDIR}/package.json"

_bump_single_file "$JFILE" "0.1.1" "0.1.2"

if grep -q '"version": "0.1.2"' "$JFILE"; then
    pass "route: _bump_single_file → JSON bumper for package.json"
else
    fail "route: $(grep version "$JFILE")"
fi

# Description and indent preserved (proves format-preservation through the route).
if grep -q '^    "description": "format-canary"' "$JFILE"; then
    pass "route: surrounding fields + 4-space indent preserved through router"
else
    fail "route: indent broken: $(cat "$JFILE")"
fi

# =============================================================================
# Auto-discovery — non-root package.json picked up at detection time
# =============================================================================
echo "=== _discover_package_json_files: non-root scan ==="

PROJ="${TEST_TMPDIR}/autodiscover"
mkdir -p "$PROJ/.claude" "$PROJ/bindings/wasm/pkg-template" "$PROJ/node_modules/leaky"
# Root package.json (already caught by main loop).
echo '{"name":"root","version":"1.0.0"}' > "$PROJ/package.json"
# Non-root one we want to discover.
echo '{"name":"binding","version":"1.0.0"}' > "$PROJ/bindings/wasm/pkg-template/package.json"
# Node modules entry — must be excluded.
echo '{"name":"leaky","version":"99.99.99"}' > "$PROJ/node_modules/leaky/package.json"
# A package.json without a version — should be skipped.
mkdir -p "$PROJ/no-version"
echo '{"name":"no-version"}' > "$PROJ/no-version/package.json"

# No git repo in this fixture, so the find fallback fires.
discovered=$(_discover_package_json_files "$PROJ" | sort)

if echo "$discovered" | grep -q '^bindings/wasm/pkg-template/package.json$'; then
    pass "auto-discovery: non-root package.json found"
else
    fail "auto-discovery: missing non-root entry: $discovered"
fi
if echo "$discovered" | grep -q 'node_modules'; then
    fail "auto-discovery: node_modules leaked: $discovered"
else
    pass "auto-discovery: node_modules excluded"
fi
if echo "$discovered" | grep -q '^no-version/package.json$'; then
    fail "auto-discovery: package.json without version was included: $discovered"
else
    pass "auto-discovery: package.json without version skipped"
fi

# Detect-pass picks the non-root package.json up too.
PROJECT_DIR="$PROJ" PROJECT_VERSION_CONFIG=".claude/project_version.cfg" \
    PROJECT_VERSION_STRATEGY="semver" detect_project_version_files

cfg="$PROJ/.claude/project_version.cfg"
if grep -q 'bindings/wasm/pkg-template/package.json:.version' "$cfg"; then
    pass "detect_project_version_files: auto-discovered binding listed in VERSION_FILES"
else
    fail "detect: $(cat "$cfg")"
fi
# Must NOT list the same root package.json twice.
root_count=$(grep -o 'package.json:' "$cfg" | wc -l)
if [[ "$root_count" -eq 2 ]]; then
    # 2 total: root package.json + non-root one. No duplicates.
    pass "detect: no duplicate package.json entries"
else
    fail "detect: package.json appears $root_count times (expected 2): $(cat "$cfg")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
