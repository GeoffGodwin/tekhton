#!/usr/bin/env bash
# =============================================================================
# prompts_io.sh — File-content helpers for prompt assembly.
#
# Sourced by lib/prompts.sh. Hosts the size-bounded reader and the
# delimiter-wrapping helper that the rest of the pipeline uses to build
# template variable values for render_prompt. Extracted from lib/prompts.sh
# in m15 so the engine shim can stay under the 60-line wedge ceiling without
# breaking widely-used callers (lib/context_cache.sh, lib/replan_*.sh,
# lib/clarify.sh, …).
# =============================================================================

# _wrap_file_content — Wraps file content in explicit delimiters for prompt
# injection mitigation. Agents are instructed to treat delimited content as data.
# Usage: content=$(_wrap_file_content "label" "$raw_content")
_wrap_file_content() {
    local label="$1"
    local content="$2"
    if [[ -z "$content" ]]; then
        echo "$content"
        return
    fi
    printf '%s\n%s\n%s' \
        "--- BEGIN FILE CONTENT: ${label} ---" \
        "$content" \
        "--- END FILE CONTENT: ${label} ---"
}

# _safe_read_file — Reads a file with size validation. Returns empty string and
# warns if the file exceeds the maximum size (default: 1MB / 1048576 bytes).
# NOTE: Do not use _safe_read_file for $PROJECT_INDEX_FILE.
# Use read_index_summary() or read_index_*() from lib/index_reader.sh
# which provide bounded, structured access to project index data (M68).
# Usage: content=$(_safe_read_file "/path/to/file" "label")
_safe_read_file() {
    local file_path="$1"
    local label="${2:-file}"
    local max_bytes="${3:-1048576}"  # 1MB default

    if [[ ! -f "$file_path" ]]; then
        return
    fi

    # Cross-platform file size: try GNU stat, then BSD stat, then wc -c
    local file_size=0
    file_size=$(stat -c%s "$file_path" 2>/dev/null || \
                stat -f%z "$file_path" 2>/dev/null || \
                wc -c < "$file_path" 2>/dev/null || echo "0")
    file_size=$(echo "$file_size" | tr -d '[:space:]')

    if [[ "$file_size" -gt "$max_bytes" ]]; then
        warn "[prompts] ${label} exceeds size limit (${file_size} > ${max_bytes} bytes). Skipping injection."
        return
    fi

    cat "$file_path"
}

# load_intake_template_vars — Populate INTAKE_* template variables for rendering.
# Called before render_prompt for prompts that use intake context.
load_intake_template_vars() {
    export INTAKE_REPORT_CONTENT=""
    export INTAKE_TWEAKS_BLOCK="${INTAKE_TWEAKS_BLOCK:-}"
    export INTAKE_HISTORY_BLOCK="${INTAKE_HISTORY_BLOCK:-}"

    if [[ -f "${INTAKE_REPORT_FILE:-}" ]]; then
        INTAKE_REPORT_CONTENT=$(_safe_read_file "${INTAKE_REPORT_FILE:-}" "INTAKE_REPORT")
    fi
}
