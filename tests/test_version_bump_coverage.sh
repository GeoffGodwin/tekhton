#!/usr/bin/env bash
# Test: m43 coverage gaps
#   1. _bump_single_file '*' catch-all: non-conventional-basename JSON file
#   2. verify_version_files_synced HUMAN_ACTION fallback paths (both branches)
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

# trip_commit_gate stub — records calls so assertions can inspect them.
_TRIP_REASONS_FILE=$(mktemp)
trap 'rm -rf "$TEST_TMPDIR" "$_TRIP_REASONS_FILE"' EXIT
trip_commit_gate() {
    echo "$1" >> "$_TRIP_REASONS_FILE"
    return 0
}

# shellcheck source=../lib/project_version.sh
source "${TEKHTON_HOME}/lib/project_version.sh"
# shellcheck source=../lib/project_version_bump.sh
source "${TEKHTON_HOME}/lib/project_version_bump.sh"
# shellcheck source=../lib/project_version_bump_helpers.sh
source "${TEKHTON_HOME}/lib/project_version_bump_helpers.sh"
# shellcheck source=../lib/project_version_verify.sh
source "${TEKHTON_HOME}/lib/project_version_verify.sh"

# =============================================================================
# Coverage gap 1a: _bump_single_file catch-all — non-conventional JSON basename
#
# The '*' branch uses `head -c 1` to detect JSON by its opening '{'. A file
# like `widget-manifest.json` does not match any named case (package.json,
# composer.json, …), so it falls through to this branch. The test confirms
# the version IS bumped via the JSON path and surrounding fields are preserved.
# =============================================================================
echo "=== _bump_single_file catch-all: non-conventional JSON basename ==="

JFILE="${TEST_TMPDIR}/widget-manifest.json"
cat > "$JFILE" <<'JSON'
{
  "name": "widget",
  "version": "1.2.3",
  "description": "non-conventional JSON basename"
}
JSON

_bump_single_file "$JFILE" "1.2.3" "1.2.4"

if grep -q '"version": "1.2.4"' "$JFILE"; then
    pass "catch-all: widget-manifest.json version bumped via JSON path"
else
    fail "catch-all: version not bumped in widget-manifest.json: $(grep version "$JFILE")"
fi

# Surrounding fields must survive (format-preserving route).
if grep -q '"name": "widget"' "$JFILE"; then
    pass "catch-all: surrounding fields preserved after catch-all bump"
else
    fail "catch-all: surrounding fields corrupted: $(cat "$JFILE")"
fi

# =============================================================================
# Coverage gap 1b: _bump_single_file catch-all — non-JSON file (first char ≠ '{')
#
# An unknown-extension file whose content does NOT start with '{' must be
# left unchanged; routing it through the JSON bumper would corrupt it.
# =============================================================================
echo "=== _bump_single_file catch-all: non-JSON unknown file is a no-op ==="

TFILE="${TEST_TMPDIR}/custom-version-file.txt"
printf 'version=1.2.3\n' > "$TFILE"

_bump_single_file "$TFILE" "1.2.3" "1.2.4"

if grep -q '^version=1.2.3' "$TFILE"; then
    pass "catch-all: non-JSON file (first char 'v') left unchanged"
else
    fail "catch-all: non-JSON file was unexpectedly modified: $(cat "$TFILE")"
fi

# =============================================================================
# Coverage gap 1c: verify_version_files_synced round-trip for catch-all file
#
# After bumping widget-manifest.json (which works via the catch-all), the
# post-bump self-check uses _accessor_for_file which returns "plaintext" for
# any filename not in its explicit list. The "plaintext" accessor reads the
# whole file with `tr -d '[:space:]'`, producing the full JSON blob — not
# just the version string — so the version comparison fails and the commit
# gate is falsely tripped.
#
# This test documents the bug: a manually declared non-conventional JSON
# version file triggers a false desync after a successful bump.
# =============================================================================
echo "=== verify round-trip: non-conventional JSON — catch-all accessor gap ==="

: > "$_TRIP_REASONS_FILE"
PROJ="${TEST_TMPDIR}/roundtrip"
mkdir -p "$PROJ"
# File is already in its post-bump state; version matches the target.
cat > "$PROJ/widget-manifest.json" <<'JSON'
{
  "name": "widget",
  "version": "1.2.4",
  "description": "post-bump state"
}
JSON

PROJECT_DIR="$PROJ" verify_version_files_synced "1.2.4" \
    "widget-manifest.json:.version" || true

# CORRECT behavior: gate must NOT trip when the version is in sync.
# CURRENT behavior: _accessor_for_file returns "plaintext" for widget-manifest.json,
# so _detect_version_from_file reads the whole file as a blob, which doesn't
# match "1.2.4", causing a false desync trip.
if [[ ! -s "$_TRIP_REASONS_FILE" ]]; then
    pass "verify round-trip: non-conventional JSON round-trip does not false-trip gate"
else
    fail "verify round-trip: gate falsely tripped for widget-manifest.json — _accessor_for_file returns 'plaintext' for .json files, causing false desync: $(cat "$_TRIP_REASONS_FILE")"
fi
: > "$_TRIP_REASONS_FILE"

# =============================================================================
# Coverage gap 2a: verify_version_files_synced HUMAN_ACTION — branch A
#
# When _append_human_action_entry is defined (bash function available in scope),
# verify_version_files_synced must call it with source="project_version_bump"
# and a description that mentions the target version.
# =============================================================================
echo "=== verify: HUMAN_ACTION via _append_human_action_entry (branch A) ==="

: > "$_TRIP_REASONS_FILE"
PROJ="${TEST_TMPDIR}/human_action_a"
mkdir -p "$PROJ"
# VERSION file deliberately out of sync (1.0.0 ≠ target 1.0.1) to trigger desync.
printf '1.0.0\n' > "$PROJ/VERSION"

_HUMAN_ACTION_LOG="${TEST_TMPDIR}/human_action_a.log"
: > "$_HUMAN_ACTION_LOG"

_append_human_action_entry() {
    printf 'source=%s\tdesc=%s\n' "$1" "$2" >> "$_HUMAN_ACTION_LOG"
}

PROJECT_DIR="$PROJ" verify_version_files_synced "1.0.1" "VERSION:." || true

# The function must have been called with the right source identifier.
if grep -q 'source=project_version_bump' "$_HUMAN_ACTION_LOG"; then
    pass "HUMAN_ACTION branch A: _append_human_action_entry called with correct source"
else
    fail "HUMAN_ACTION branch A: _append_human_action_entry not called or wrong source: $(cat "$_HUMAN_ACTION_LOG")"
fi

# Description must mention the target version so operators know what to fix.
if grep -q 'target=1.0.1' "$_HUMAN_ACTION_LOG"; then
    pass "HUMAN_ACTION branch A: description mentions target version"
else
    fail "HUMAN_ACTION branch A: description missing target version: $(cat "$_HUMAN_ACTION_LOG")"
fi

# The gate must also have been tripped (confirms desync was detected at all).
if grep -q '^version_files_desynced_' "$_TRIP_REASONS_FILE" 2>/dev/null; then
    pass "HUMAN_ACTION branch A: commit gate also tripped (desync was detected)"
else
    fail "HUMAN_ACTION branch A: commit gate not tripped — verify didn't detect desync"
fi

# Clean up: remove the function so branch B can test the fallback CLI path.
unset -f _append_human_action_entry
: > "$_TRIP_REASONS_FILE"

# =============================================================================
# Coverage gap 2b: verify_version_files_synced HUMAN_ACTION — branch B
#
# When _append_human_action_entry is NOT defined, verify_version_files_synced
# falls back to calling `$TEKHTON_BIN drift human-action append`. This test
# stubs TEKHTON_BIN as a fake executable that logs its argv, then asserts the
# correct subcommand and --source flag appear.
# =============================================================================
echo "=== verify: HUMAN_ACTION via tekhton CLI (branch B) ==="

: > "$_TRIP_REASONS_FILE"
PROJ="${TEST_TMPDIR}/human_action_b"
mkdir -p "$PROJ"
printf '2.0.0\n' > "$PROJ/VERSION"  # Out of sync: target is 2.0.1.

# Fake tekhton binary: logs its full argv as one whitespace-joined line.
FAKE_BIN_DIR="${TEST_TMPDIR}/fakebin"
mkdir -p "$FAKE_BIN_DIR"
FAKE_BIN="${FAKE_BIN_DIR}/tekhton"
_CLI_LOG="${TEST_TMPDIR}/cli_calls.log"
: > "$_CLI_LOG"
cat > "$FAKE_BIN" <<FAKEEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> ${_CLI_LOG}
exit 0
FAKEEOF
chmod +x "$FAKE_BIN"

# _append_human_action_entry must NOT be defined (we unset it above).
PROJECT_DIR="$PROJ" TEKHTON_BIN="$FAKE_BIN" \
    verify_version_files_synced "2.0.1" "VERSION:." || true

# The CLI must have been called with the drift human-action subcommand.
if grep -q 'drift human-action append' "$_CLI_LOG"; then
    pass "HUMAN_ACTION branch B: tekhton drift human-action append called on desync"
else
    fail "HUMAN_ACTION branch B: CLI not invoked or wrong subcommand: $(cat "$_CLI_LOG" 2>/dev/null)"
fi

# --source project_version_bump must be present.
if grep -q 'project_version_bump' "$_CLI_LOG"; then
    pass "HUMAN_ACTION branch B: --source project_version_bump in CLI invocation"
else
    fail "HUMAN_ACTION branch B: --source flag missing from CLI args: $(cat "$_CLI_LOG")"
fi

# =============================================================================
# Summary
# =============================================================================
echo
echo "Results: ${PASS} passed, ${FAIL} failed"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
