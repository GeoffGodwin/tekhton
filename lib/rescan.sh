#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# rescan.sh — Project rescan shim (m30.1 cutover)
#
# Pre-m30.1: this file owned the incremental-update path (git diff since
# last scan, surgical regeneration of affected .claude/index/ files).
# m30.1 ported the crawler core to Go and deleted the bash emitters
# (lib/crawler_*.sh) the incremental path depended on. The incremental
# Go port is m30.2's milestone — until then this shim degrades every
# rescan to a full crawl via `tekhton crawler crawl`.
#
# `rescan_project` remains because tekhton-legacy.sh calls it by name;
# the rest of the bash rescan logic (significance detection, surgical
# patching, scan-metadata helpers) deletes outright. Tests that
# exercised those helpers (tests/test_rescan.sh) skip-stub themselves.
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: common.sh (log, warn, header, success), tekhton binary on PATH.
# =============================================================================

# rescan_project — Always delegate to `tekhton crawler crawl` until m30.2.
# Args: $1 = project directory, $2 = budget in chars (default: 120000),
#       $3 = ignored ("full" had meaning pre-m30.1; now a no-op).
rescan_project() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-${PROJECT_INDEX_BUDGET:-120000}}"
    # $3 (force_full) intentionally ignored — every rescan is full in m30.1.

    header "Tekhton — Project Rescan"

    local bin="${TEKHTON_BIN:-tekhton}"
    if ! command -v "$bin" >/dev/null 2>&1 && [[ ! -x "$bin" ]]; then
        error "rescan: tekhton binary not found (set TEKHTON_BIN or build via 'make build')"
        return 1
    fi

    log "Rescan (m30.1: delegating to full crawl; incremental returns in m30.2)..."
    "$bin" crawler crawl --project-dir "$project_dir" --budget "$budget_chars" >/dev/null

    # Regenerate the human-readable view from the structured data the Go
    # crawler just wrote. View generation stays bash until m31+.
    generate_project_index_view "$project_dir" "$budget_chars"

    local index_file="${project_dir}/${PROJECT_INDEX_FILE:-.tekhton/PROJECT_INDEX.md}"
    local final_size=0
    [[ -f "$index_file" ]] && final_size=$(wc -c < "$index_file" | tr -d '[:space:]')
    success "${PROJECT_INDEX_FILE:-.tekhton/PROJECT_INDEX.md} rewritten (${final_size} chars)"
    return 0
}
