#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_audit_sampler.sh — Rolling test audit sampler (Milestone 89)
#
# Sourced by tekhton.sh — do not run directly.
# Provides:
#   _ensure_test_audit_history_file — Resolve cache_dir/test_audit_history.jsonl
#   _record_audit_history FILES     — Append JSONL entries for audited files
#   _prune_audit_history            — Trim history to TEST_AUDIT_HISTORY_MAX_RECORDS
#   _sample_unaudited_test_files    — Populate _AUDIT_SAMPLE_FILES with K oldest
#
# A rolling K-file sample of "least-recently-audited" tests is appended to
# the audit context each run, so stale tests get re-evaluated by the LLM
# rubric over time without growing per-run cost beyond K extra files.
#
# Dependencies: common.sh (warn). Optional: indexer_helpers.sh
#   (_indexer_resolve_cache_dir) — used when available for cache_dir parity
#   with task_history.jsonl.
# =============================================================================

_TEST_AUDIT_HISTORY_FILE=""

# Resolve the audit history JSONL path. Independent of REPO_MAP_ENABLED — the
# sampler is pure shell and works in any project regardless of indexer state.
_ensure_test_audit_history_file() {
    if [[ -n "$_TEST_AUDIT_HISTORY_FILE" ]]; then return; fi
    local cache_dir=""
    if command -v _indexer_resolve_cache_dir &>/dev/null; then
        cache_dir=$(_indexer_resolve_cache_dir 2>/dev/null) || cache_dir=""
    fi
    if [[ -z "$cache_dir" ]]; then
        cache_dir="${REPO_MAP_CACHE_DIR:-.claude/index}"
        if [[ "$cache_dir" != /* ]]; then
            cache_dir="${PROJECT_DIR}/${cache_dir}"
        fi
        mkdir -p "$cache_dir" 2>/dev/null || true
    fi
    _TEST_AUDIT_HISTORY_FILE="${cache_dir}/test_audit_history.jsonl"
}

# Append one JSONL entry per file in $1 (newline-separated). Best-effort:
# write failures warn but never block the pipeline.
_record_audit_history() {
    local files="${1:-}"
    [[ -z "$files" ]] && return 0
    _ensure_test_audit_history_file
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local f safe_f wrote=0
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        safe_f=$(printf '%s' "$f" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if echo "{\"ts\":\"${ts}\",\"file\":\"${safe_f}\"}" \
            >> "$_TEST_AUDIT_HISTORY_FILE" 2>/dev/null; then
            wrote=$((wrote + 1))
        else
            warn "[test-audit] Failed to append audit history for ${f}."
        fi
    done <<< "$files"
    [[ "$wrote" -gt 0 ]] && _prune_audit_history
    return 0
}

# Trim the history file to the last TEST_AUDIT_HISTORY_MAX_RECORDS lines.
# Atomic (tail to tmp, mv) — same pattern as _prune_task_history.
_prune_audit_history() {
    _ensure_test_audit_history_file
    local max_records="${TEST_AUDIT_HISTORY_MAX_RECORDS:-500}"
    [[ ! -f "$_TEST_AUDIT_HISTORY_FILE" ]] && return
    local line_count
    line_count=$(wc -l < "$_TEST_AUDIT_HISTORY_FILE" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$line_count" ]] && return
    [[ "$line_count" -le "$max_records" ]] && return

    local tmp_file="${_TEST_AUDIT_HISTORY_FILE}.tmp"
    if tail -n "$max_records" "$_TEST_AUDIT_HISTORY_FILE" > "$tmp_file" 2>/dev/null; then
        mv "$tmp_file" "$_TEST_AUDIT_HISTORY_FILE" 2>/dev/null || {
            rm -f "$tmp_file" 2>/dev/null || true
            warn "[test-audit] Failed to prune audit history."
        }
    else
        rm -f "$tmp_file" 2>/dev/null || true
        warn "[test-audit] Failed to prune audit history."
    fi
}

# Populate _AUDIT_SAMPLE_FILES with up to K test files that are absent from
# the current audit set and have the oldest (or missing) audit timestamps.
# Files never audited score epoch 0000-... and sort first.
_sample_unaudited_test_files() {
    _AUDIT_SAMPLE_FILES=""
    local k="${TEST_AUDIT_ROLLING_SAMPLE_K:-3}"
    [[ "$k" -le 0 ]] && return

    _ensure_test_audit_history_file

    local all_tests
    all_tests=$(_discover_all_test_files)
    [[ -z "$all_tests" ]] && return

    local current_set="${_AUDIT_TEST_FILES:-}"

    local -A last_seen=()
    if [[ -f "$_TEST_AUDIT_HISTORY_FILE" ]]; then
        local line hist_f hist_ts
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            hist_f=$(printf '%s' "$line" | sed -n 's/.*"file":"\([^"]*\)".*/\1/p')
            hist_ts=$(printf '%s' "$line" | sed -n 's/.*"ts":"\([^"]*\)".*/\1/p')
            [[ -z "$hist_f" ]] && continue
            [[ -z "$hist_ts" ]] && continue
            # Last entry per path wins (history may have duplicates)
            if [[ -z "${last_seen[$hist_f]:-}" ]] \
                || [[ "$hist_ts" > "${last_seen[$hist_f]}" ]]; then
                last_seen["$hist_f"]="$hist_ts"
            fi
        done < "$_TEST_AUDIT_HISTORY_FILE"
    fi

    # Sort all test files by last-audited timestamp ascending (oldest first).
    # ISO-8601 strings sort lexicographically. Unseen files get epoch 0.
    local sorted
    sorted=$(while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        printf '%s\t%s\n' "${last_seen[$f]:-0000-00-00T00:00:00Z}" "$f"
    done <<< "$all_tests" | LC_ALL=C sort | awk -F'\t' '{print $2}')

    local sampled=0
    local sample_list=""
    local f
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        # Skip if already in this run's modified-files audit set
        if [[ -n "$current_set" ]] && printf '%s\n' "$current_set" \
            | grep -qxF -- "$f" 2>/dev/null; then
            continue
        fi
        sample_list="${sample_list}${f}
"
        sampled=$((sampled + 1))
        [[ "$sampled" -ge "$k" ]] && break
    done <<< "$sorted"

    # Trim trailing newline for cleaner downstream rendering
    _AUDIT_SAMPLE_FILES="${sample_list%$'\n'}"
    export _AUDIT_SAMPLE_FILES
}
