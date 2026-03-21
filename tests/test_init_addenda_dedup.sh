#!/usr/bin/env bash
# Test: _append_addenda() deduplication — same addendum file not appended twice
# when the languages list contains two entries that resolve to the same filename.
# Covers the coverage gap noted in REVIEWER_REPORT.md (Milestone 19, Cycle 2).
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub functions and color vars required by init.sh / init_config.sh
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }
BOLD="" CYAN="" GREEN="" YELLOW="" RED="" NC=""
export BOLD CYAN GREEN YELLOW RED NC

# Source init.sh — pulls in init_config.sh and prompts_interactive.sh
# shellcheck source=../lib/init.sh
source "${TEKHTON_HOME}/lib/init.sh"

# =============================================================================
# Setup: fake tekhton_home with one addendum file
# =============================================================================
FAKE_HOME="${TEST_TMPDIR}/fake_tekhton"
mkdir -p "${FAKE_HOME}/templates/agents/addenda"

SENTINEL="ADDENDUM_SENTINEL_XYZ_12345"
echo "# Test addendum" > "${FAKE_HOME}/templates/agents/addenda/typescript.md"
echo "${SENTINEL}" >> "${FAKE_HOME}/templates/agents/addenda/typescript.md"

# =============================================================================
# Test 1: Single language — addendum appended exactly once
# =============================================================================
echo "=== Single language: addendum appended once ==="

TARGET1="${TEST_TMPDIR}/target1.md"
echo "# Base role" > "$TARGET1"
SINGLE_LANG="typescript|high|package.json"

_append_addenda "$TARGET1" "$FAKE_HOME" "$SINGLE_LANG"

count=$(grep -c "$SENTINEL" "$TARGET1" || true)
if [[ "$count" -eq 1 ]]; then
    pass "Single language: addendum sentinel appears exactly once"
else
    fail "Single language: addendum sentinel appears ${count} times (expected 1)"
fi

# =============================================================================
# Test 2: Same language name twice — addendum must NOT be appended twice
# This is the regression guard: if detection emits the same language entry
# twice, _append_addenda should not double-append the addendum file.
# =============================================================================
echo "=== Duplicate language entry: addendum appended only once ==="

TARGET2="${TEST_TMPDIR}/target2.md"
echo "# Base role" > "$TARGET2"
# Two entries with the same language name — both resolve to typescript.md
DUP_LANGS="$(printf 'typescript|high|package.json\ntypescript|medium|tsconfig.json')"

_append_addenda "$TARGET2" "$FAKE_HOME" "$DUP_LANGS"

count=$(grep -c "$SENTINEL" "$TARGET2" || true)
if [[ "$count" -eq 1 ]]; then
    pass "Duplicate language entries: addendum sentinel appears exactly once (deduplicated)"
else
    fail "Duplicate language entries: addendum sentinel appears ${count} times (expected 1 — double-append bug)"
fi

# =============================================================================
# Test 3: Two different languages, different addenda — both appended
# =============================================================================
echo "=== Two distinct languages: both addenda appended ==="

SENTINEL2="ADDENDUM_SENTINEL_PYTHON_67890"
echo "# Python addendum" > "${FAKE_HOME}/templates/agents/addenda/python.md"
echo "${SENTINEL2}" >> "${FAKE_HOME}/templates/agents/addenda/python.md"

TARGET3="${TEST_TMPDIR}/target3.md"
echo "# Base role" > "$TARGET3"
TWO_LANGS="$(printf 'typescript|high|package.json\npython|high|pyproject.toml')"

_append_addenda "$TARGET3" "$FAKE_HOME" "$TWO_LANGS"

ts_count=$(grep -c "$SENTINEL" "$TARGET3" || true)
py_count=$(grep -c "$SENTINEL2" "$TARGET3" || true)

if [[ "$ts_count" -eq 1 ]] && [[ "$py_count" -eq 1 ]]; then
    pass "Two distinct languages: each addendum appended exactly once"
else
    fail "Two distinct languages: typescript count=${ts_count}, python count=${py_count} (expected 1 each)"
fi

# =============================================================================
# Test 4: Language with no addendum file — target unchanged (no crash)
# =============================================================================
echo "=== Language with no addendum file: target unchanged ==="

TARGET4="${TEST_TMPDIR}/target4.md"
echo "# Base role" > "$TARGET4"
ORIGINAL_CONTENT=$(cat "$TARGET4")
NO_ADDENDUM_LANG="go|high|go.mod"  # no go.md addendum in fake_home

_append_addenda "$TARGET4" "$FAKE_HOME" "$NO_ADDENDUM_LANG"

current_content=$(cat "$TARGET4")
if [[ "$current_content" = "$ORIGINAL_CONTENT" ]]; then
    pass "Language with no addendum: target file unchanged"
else
    fail "Language with no addendum: target file was modified unexpectedly"
fi

# =============================================================================
# Test 5: Empty languages — no-op, target unchanged
# =============================================================================
echo "=== Empty languages: no-op ==="

TARGET5="${TEST_TMPDIR}/target5.md"
echo "# Base role" > "$TARGET5"
ORIGINAL_CONTENT=$(cat "$TARGET5")

_append_addenda "$TARGET5" "$FAKE_HOME" ""

current_content=$(cat "$TARGET5")
if [[ "$current_content" = "$ORIGINAL_CONTENT" ]]; then
    pass "Empty languages: target file unchanged"
else
    fail "Empty languages: target file was modified unexpectedly"
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
