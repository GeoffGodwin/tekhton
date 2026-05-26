#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# markdown_helpers.sh — m24. Generic markdown post-processing helpers.
#
# Sourced by lib/drift_cleanup.sh — do not run directly. Holds the
# previously-named `_normalize_markdown_blank_runs` helper that used to
# live in lib/notes_core_normalize.sh (deleted in m24 along with the
# rest of the lib/notes*.sh family). The helper itself is not
# notes-specific — it post-processes any markdown file by collapsing
# blank-line runs.
# =============================================================================

# _normalize_markdown_blank_runs FILE
#
# Rewrites FILE in-place, normalizing blank-line runs:
#   - Strips leading blank lines entirely.
#   - Strips trailing blank lines (keeps a single terminating newline).
#   - Collapses interior runs of >= 2 blank lines to a single blank line.
#   - Preserves blank lines inside fenced code blocks (``` ... ```).
#
# Idempotent: running twice on the same file produces identical output.
# Safe: never rewrites a non-blank line; header, bullet, and description
# lines pass through unchanged.
_normalize_markdown_blank_runs() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/norm_XXXXXXXX")
    awk '
        BEGIN { in_fence = 0; saw_content = 0; blank_pending = 0 }
        /^```/ {
            if (blank_pending) { print ""; blank_pending = 0 }
            in_fence = !in_fence; print; saw_content = 1; next
        }
        in_fence { print; next }
        /^[[:space:]]*$/ {
            if (saw_content) { blank_pending = 1 }
            next
        }
        {
            if (blank_pending) { print ""; blank_pending = 0 }
            print
            saw_content = 1
        }
    ' "$file" > "$tmpfile"
    mv "$tmpfile" "$file"
}
