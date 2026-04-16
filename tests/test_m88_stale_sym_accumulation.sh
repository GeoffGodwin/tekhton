#!/usr/bin/env bash
# =============================================================================
# test_m88_stale_sym_accumulation.sh — Rework-accumulation edge case (M88)
#
# Covers the reviewer coverage gap: when TEST_AUDIT_ORPHAN_DETECTION=false,
# _detect_orphaned_tests is skipped in the rework loop, meaning it never resets
# _AUDIT_ORPHAN_FINDINGS. Calling _detect_stale_symbol_refs a second time without
# that reset causes STALE-SYM entries to duplicate in the context.
#
# Tests:
#   1. Single call produces exactly one STALE-SYM finding
#   2. Second call without reset accumulates a duplicate STALE-SYM finding
#   3. Resetting _AUDIT_ORPHAN_FINDINGS before the second call prevents duplication
# =============================================================================
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

# Source common.sh for log/warn (test_audit_symbols.sh expects them available)
source "${TEKHTON_HOME}/lib/common.sh"
# Suppress output noise from log/warn
BOLD="" NC="" CYAN="" YELLOW=""

# Stub _indexer_find_venv_python to use system python3
_indexer_find_venv_python() { command -v python3; }

source "${TEKHTON_HOME}/lib/test_audit_symbols.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }

# --- Fixture helpers (same structure as test_audit_symbol_orphan.sh) ---

_setup_cache_dir() {
    local cache_dir="${TMPDIR_TEST}/.claude/index"
    mkdir -p "$cache_dir"
    echo "$cache_dir"
}

_write_test_map() {
    local cache_dir="$1"
    shift
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
echo "=== M88 rework-accumulation edge case tests ==="

# Setup: test_map.json references RemovedFunc; tags.json does NOT define it.
cache_dir=$(_setup_cache_dir)
_write_test_map "$cache_dir" "tests/test_migrate.py" "RemovedFunc,LiveFunc"
_write_tags "$cache_dir" "src/migrate.py" "LiveFunc,OtherFunc"

TEST_SYMBOL_MAP_FILE="${cache_dir}/test_map.json"
TEST_AUDIT_SYMBOL_MAP_ENABLED=true
_AUDIT_TEST_FILES="tests/test_migrate.py"

# --- test_single_call_produces_one_finding ---
echo "--- test_single_call_produces_one_finding ---"
_AUDIT_ORPHAN_FINDINGS=""

_detect_stale_symbol_refs

count=$(echo "$_AUDIT_ORPHAN_FINDINGS" | grep -c "STALE-SYM.*RemovedFunc" || true)
if [[ "$count" -eq 1 ]]; then
    pass "First call produces exactly one STALE-SYM finding for RemovedFunc"
else
    fail "Expected 1 STALE-SYM finding for RemovedFunc after first call, got ${count}: ${_AUDIT_ORPHAN_FINDINGS}"
fi

live_count=$(echo "$_AUDIT_ORPHAN_FINDINGS" | grep -c "STALE-SYM.*LiveFunc" || true)
if [[ "$live_count" -eq 0 ]]; then
    pass "LiveFunc (present in tags) not flagged on first call"
else
    fail "LiveFunc should not be flagged, got ${live_count} findings"
fi

# --- test_second_call_without_reset_duplicates ---
echo "--- test_second_call_without_reset_duplicates ---"
# Simulate what happens in the rework loop when TEST_AUDIT_ORPHAN_DETECTION=false:
# _detect_orphaned_tests is skipped (which would have reset _AUDIT_ORPHAN_FINDINGS).
# The findings from cycle 1 remain in _AUDIT_ORPHAN_FINDINGS when cycle 2 runs.

_detect_stale_symbol_refs

count=$(echo "$_AUDIT_ORPHAN_FINDINGS" | grep -c "STALE-SYM.*RemovedFunc" || true)
if [[ "$count" -eq 2 ]]; then
    pass "Second call without reset produces duplicate STALE-SYM (known accumulation behavior)"
else
    fail "Expected 2 STALE-SYM findings after second call without reset, got ${count}: ${_AUDIT_ORPHAN_FINDINGS}"
fi

# --- test_reset_before_second_call_prevents_duplication ---
echo "--- test_reset_before_second_call_prevents_duplication ---"
# Simulate what _detect_orphaned_tests does when TEST_AUDIT_ORPHAN_DETECTION=true:
# it resets _AUDIT_ORPHAN_FINDINGS="" before running. The subsequent call to
# _detect_stale_symbol_refs then gets a clean slate.
_AUDIT_ORPHAN_FINDINGS=""

_detect_stale_symbol_refs

count=$(echo "$_AUDIT_ORPHAN_FINDINGS" | grep -c "STALE-SYM.*RemovedFunc" || true)
if [[ "$count" -eq 1 ]]; then
    pass "Reset before second call produces exactly one STALE-SYM (no duplication)"
else
    fail "Expected 1 STALE-SYM after reset + second call, got ${count}: ${_AUDIT_ORPHAN_FINDINGS}"
fi

# ============================================================================
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
