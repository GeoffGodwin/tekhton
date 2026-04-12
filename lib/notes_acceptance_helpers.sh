#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_acceptance_helpers.sh — Acceptance helpers: review skip + metadata store
#
# Sourced by tekhton.sh — do not run directly.
# Extracted from notes_acceptance.sh for file-size compliance.
# Expects: notes_core.sh sourced first for _set_note_metadata.
# Expects: NOTES_FILTER, CLAIMED_NOTE_IDS from caller.
#
# Provides:
#   should_skip_review_for_polish — Check if all changed files are non-logic
#   _store_acceptance_result      — Update note metadata with acceptance result
# =============================================================================

# --- Reviewer skip for POLISH -------------------------------------------------

# should_skip_review_for_polish — Returns 0 if all changed files are non-logic
# (CSS, config, assets, docs) and review can be skipped.
should_skip_review_for_polish() {
    if [[ "${POLISH_SKIP_REVIEW:-true}" != "true" ]]; then
        return 1
    fi
    if [[ "${NOTES_FILTER:-}" != "POLISH" ]]; then
        return 1
    fi

    local skip_patterns="${POLISH_SKIP_REVIEW_PATTERNS:-*.css *.scss *.less *.json *.yaml *.yml *.toml *.cfg *.ini *.svg *.png *.md}"

    # Get all changed files (tracked + untracked)
    local _all_changed=""
    _all_changed=$(git diff --name-only HEAD 2>/dev/null || true)
    local _staged=""
    _staged=$(git diff --cached --name-only 2>/dev/null || true)
    local _untracked=""
    _untracked=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -v '^\.claude/' \
        | grep -v 'CODER_SUMMARY\.md' \
        | grep -v '_REPORT\.md' || true)
    _all_changed="${_all_changed}${_staged:+
${_staged}}${_untracked:+
${_untracked}}"

    if [[ -z "$_all_changed" ]]; then
        # No changes at all — nothing to review
        return 0
    fi

    # Deduplicate
    _all_changed=$(echo "$_all_changed" | sort -u)

    # Check each file against skip patterns
    while IFS= read -r file; do
        [[ -z "$file" ]] && continue
        # Skip pipeline artifacts
        [[ "$file" == "${CODER_SUMMARY_FILE}" ]] && continue
        [[ "$file" =~ _REPORT\.md$ ]] && continue
        [[ "$file" =~ ^\.claude/ ]] && continue

        local _matched=false
        local pat
        for pat in $skip_patterns; do
            local _ext="${pat#\*}"
            if [[ "$file" == *"$_ext" ]]; then
                _matched=true
                break
            fi
        done
        if [[ "$_matched" = false ]]; then
            # Found a file that doesn't match skip patterns — must review
            return 1
        fi
    done <<< "$_all_changed"

    return 0
}

# --- Acceptance metadata storage -----------------------------------------------

# _store_acceptance_result CODE WARNINGS — Update note metadata with acceptance result.
_store_acceptance_result() {
    local code="$1"
    local _warnings="${2:-}"

    # Export for metrics/dashboard consumption
    export NOTE_ACCEPTANCE_RESULT="${code}"
    export NOTE_ACCEPTANCE_WARNINGS="${_warnings}"

    # Update metadata for each claimed note
    if [[ -n "${CLAIMED_NOTE_IDS:-}" ]] && command -v _set_note_metadata &>/dev/null; then
        local nid
        local _rev_skipped="${REVIEWER_SKIPPED:-false}"
        for nid in $CLAIMED_NOTE_IDS; do
            _set_note_metadata "$nid" "acceptance" "$code" 2>/dev/null || true
            _set_note_metadata "$nid" "reviewer_skipped" "$_rev_skipped" 2>/dev/null || true
        done
    fi
}
