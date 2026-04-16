#!/usr/bin/env bash
# test_audit_symbol_orphan.sh — Tests for symbol-level orphan detection (M88)
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

PROJECT_DIR="$TMPDIR_TEST"
TEKHTON_SESSION_DIR=$(mktemp -d "$TMPDIR_TEST/session_XXXXXXXX")
TEKHTON_DIR=".tekhton"
mkdir -p "${TMPDIR_TEST}/${TEKHTON_DIR}"
export TEKHTON_HOME PROJECT_DIR TEKHTON_SESSION_DIR TEKHTON_DIR

cd "$PROJECT_DIR"

# --- Source required libraries ---
source "${TEKHTON_HOME}/lib/common.sh"
BOLD="" NC=""

# Stub _indexer_find_venv_python to use system python3
_indexer_find_venv_python() { command -v python3; }

source "${TEKHTON_HOME}/lib/test_audit_symbols.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; }

# --- Fixture helpers ---
_setup_cache_dir() {
    local cache_dir="${TMPDIR_TEST}/.claude/index"
    mkdir -p "$cache_dir"
    echo "$cache_dir"
}

_write_test_map() {
    local cache_dir="$1"
    shift
    # Remaining args: pairs of "file sym1,sym2,..."
    local json='{"version":1,"generated":"2026-01-01T00:00:00Z","files":{'
    local first=true
    while [[ $# -gt 0 ]]; do
        local file="$1" syms_str="$2"
        shift 2
        if [[ "$first" != "true" ]]; then json="${json},"; fi
        first=false
        json="${json}\"${file}\":["
        local sym_first=true
        IFS=',' read -ra sym_arr <<< "$syms_str"
        for s in "${sym_arr[@]}"; do
            if [[ "$sym_first" != "true" ]]; then json="${json},"; fi
            sym_first=false
            json="${json}\"${s}\""
        done
        json="${json}]"
    done
    json="${json}}}"
    echo "$json" > "${cache_dir}/test_map.json"
}

_write_tags() {
    local cache_dir="$1"
    shift
    # Remaining args: pairs of "file defname1,defname2,..."
    local json='{'
    local first=true
    while [[ $# -gt 0 ]]; do
        local file="$1" defs_str="$2"
        shift 2
        if [[ "$first" != "true" ]]; then json="${json},"; fi
        first=false
        json="${json}\"${file}\":{\"mtime\":1,\"tags\":{\"definitions\":["
        local def_first=true
        IFS=',' read -ra def_arr <<< "$defs_str"
        for d in "${def_arr[@]}"; do
            if [[ "$def_first" != "true" ]]; then json="${json},"; fi
            def_first=false
            json="${json}{\"name\":\"${d}\",\"type\":\"function\"}"
        done
        json="${json}],\"references\":[]}}"
    done
    json="${json}}"
    echo "$json" > "${cache_dir}/tags.json"
}

# ============================================================================
echo "=== Symbol-level orphan detection tests ==="

# --- test_stale_sym_detected ---
echo "--- test_stale_sym_detected ---"
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_migrate.py" "apply_migration,OldFunc"
_write_tags "$cache_dir" "src/migrate.py" "apply_migration"
# OldFunc is NOT in tags → should be flagged
TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES="tests/test_migrate.py"
_AUDIT_ORPHAN_FINDINGS=""
_detect_stale_symbol_refs
if echo "$_AUDIT_ORPHAN_FINDINGS" | grep -q "STALE-SYM.*OldFunc"; then
    pass "Stale symbol OldFunc detected"
else
    fail "Expected STALE-SYM finding for OldFunc, got: $_AUDIT_ORPHAN_FINDINGS"
fi
if echo "$_AUDIT_ORPHAN_FINDINGS" | grep -q "STALE-SYM.*apply_migration"; then
    fail "apply_migration should NOT be flagged (it exists in tags)"
else
    pass "Live symbol apply_migration not flagged"
fi

# --- test_live_sym_not_flagged ---
echo "--- test_live_sym_not_flagged ---"
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_calc.py" "multiply,add"
_write_tags "$cache_dir" "src/calc.py" "multiply,add"
TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES="tests/test_calc.py"
_AUDIT_ORPHAN_FINDINGS=""
_detect_stale_symbol_refs
if [[ -z "$_AUDIT_ORPHAN_FINDINGS" ]]; then
    pass "No stale symbols when all refs are live"
else
    fail "Expected no findings, got: $_AUDIT_ORPHAN_FINDINGS"
fi

# --- test_skips_when_no_map ---
echo "--- test_skips_when_no_map ---"
TEST_SYMBOL_MAP_FILE="/nonexistent/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES="tests/test_x.py"
_AUDIT_ORPHAN_FINDINGS=""
_detect_stale_symbol_refs
if [[ -z "$_AUDIT_ORPHAN_FINDINGS" ]]; then
    pass "Silently skipped when test_map.json absent"
else
    fail "Expected no findings when map missing, got: $_AUDIT_ORPHAN_FINDINGS"
fi

# --- test_skips_when_map_disabled ---
echo "--- test_skips_when_map_disabled ---"
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_x.py" "gone_func"
_write_tags "$cache_dir" "src/x.py" "other_func"
TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=false
_AUDIT_TEST_FILES="tests/test_x.py"
_AUDIT_ORPHAN_FINDINGS=""
_detect_stale_symbol_refs
if [[ -z "$_AUDIT_ORPHAN_FINDINGS" ]]; then
    pass "Silently skipped when TEST_AUDIT_SYMBOL_MAP_ENABLED=false"
else
    fail "Expected no findings when disabled, got: $_AUDIT_ORPHAN_FINDINGS"
fi

# --- test_appends_to_existing_findings ---
echo "--- test_appends_to_existing_findings ---"
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_a.py" "missing_sym"
_write_tags "$cache_dir" "src/a.py" "present_sym"
TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES="tests/test_a.py"
_AUDIT_ORPHAN_FINDINGS="ORPHAN: tests/test_a.py imports deleted module 'old.py'"
_detect_stale_symbol_refs
if echo "$_AUDIT_ORPHAN_FINDINGS" | grep -q "ORPHAN.*old.py"; then
    pass "Existing ORPHAN finding preserved"
else
    fail "Existing finding was lost"
fi
if echo "$_AUDIT_ORPHAN_FINDINGS" | grep -q "STALE-SYM.*missing_sym"; then
    pass "New STALE-SYM appended alongside existing findings"
else
    fail "New STALE-SYM not appended, got: $_AUDIT_ORPHAN_FINDINGS"
fi

# --- test_skips_when_audit_test_files_empty ---
echo "--- test_skips_when_audit_test_files_empty ---"
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_y.py" "vanished_func"
_write_tags "$cache_dir" "src/y.py" "other_func"
# vanished_func is NOT in tags — would be flagged if _AUDIT_TEST_FILES were set
TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES=""
_AUDIT_ORPHAN_FINDINGS=""
_detect_stale_symbol_refs
if [[ -z "$_AUDIT_ORPHAN_FINDINGS" ]]; then
    pass "Silently skipped when _AUDIT_TEST_FILES is empty"
else
    fail "Expected no findings when _AUDIT_TEST_FILES empty, got: $_AUDIT_ORPHAN_FINDINGS"
fi

# ============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
