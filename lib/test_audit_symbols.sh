#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit_symbols.sh — Symbol-level stale reference detection (Milestone 88)
#
# Sourced by tekhton.sh — do not run directly.
# Provides: _detect_stale_symbol_refs()
#
# Cross-references test_map.json (test file → referenced symbols) against
# tags.json (source file → defined symbols) to detect test files that reference
# symbols no longer defined anywhere in the codebase.
#
# Dependencies: common.sh (warn), indexer.sh (_indexer_find_venv_python)
# =============================================================================

_detect_stale_symbol_refs() {
    [[ "${TEST_AUDIT_SYMBOL_MAP_ENABLED:-true}" != "true" ]] && return

    local test_map_file="${TEST_SYMBOL_MAP_FILE:-}"
    [[ -z "$test_map_file" ]] && return
    [[ ! -f "$test_map_file" ]] && return
    [[ -z "${_AUDIT_TEST_FILES:-}" ]] && return

    local tags_file
    tags_file="$(dirname "$test_map_file")/tags.json"
    [[ ! -f "$tags_file" ]] && return

    local venv_python="python3"
    if command -v _indexer_find_venv_python &>/dev/null; then
        venv_python=$(_indexer_find_venv_python 2>/dev/null) || venv_python="python3"
    fi

    local test_files_tmp
    test_files_tmp=$(mktemp 2>/dev/null || echo "/tmp/tekhton_stale_sym_$$")
    echo "$_AUDIT_TEST_FILES" > "$test_files_tmp"

    local findings
    findings=$("$venv_python" -c '
import json, sys

test_map_path, tags_path, test_files_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(test_files_path) as f:
    test_files = set(line.strip() for line in f if line.strip())

with open(test_map_path) as f:
    test_map = json.load(f)

with open(tags_path) as f:
    tags_data = json.load(f)

defined = set()
for entry in tags_data.values():
    if not isinstance(entry, dict):
        continue
    tags = entry.get("tags", entry)
    if not isinstance(tags, dict):
        continue
    for d in tags.get("definitions", []):
        name = d.get("name", "")
        if name:
            defined.add(name)

files_map = test_map.get("files", test_map)
for tf in sorted(test_files):
    syms = files_map.get(tf, [])
    for sym in syms:
        if sym not in defined:
            print("STALE-SYM: {} references \x27{}\x27 not found in any source definition".format(tf, sym))
' "$test_map_file" "$tags_file" "$test_files_tmp" 2>/dev/null || true)

    rm -f "$test_files_tmp" 2>/dev/null || true

    if [[ -n "$findings" ]]; then
        _AUDIT_ORPHAN_FINDINGS="${_AUDIT_ORPHAN_FINDINGS:+${_AUDIT_ORPHAN_FINDINGS}
}${findings}"
    fi
}
