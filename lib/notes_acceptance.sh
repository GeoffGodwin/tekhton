#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# notes_acceptance.sh — Tag-specific acceptance heuristics (Milestone 42)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: notes_core.sh sourced first for _set_note_metadata.
# Expects: NOTES_FILTER, CLAIMED_NOTE_IDS, log(), warn() from caller.
#
# Provides:
#   run_note_acceptance  — Run tag-specific acceptance checks after coder completes
#   check_bug_acceptance — BUG: regression test + RCA presence
#   check_feat_acceptance — FEAT: conventional file placement
#   check_polish_acceptance — POLISH: logic file modification warning
#   should_skip_review_for_polish — Check if all changed files are non-logic
# =============================================================================

# --- BUG acceptance -----------------------------------------------------------

# check_bug_acceptance — Checks for regression test and root cause analysis.
# Returns warnings as newline-separated strings via stdout.
# Exit 0 = pass (may still have warnings), exit 1 = error running checks.
check_bug_acceptance() {
    local warnings=""

    # Check: did git diff include changes to at least one test file?
    local _test_files_changed=0
    if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        _test_files_changed=$(git diff --name-only HEAD 2>/dev/null \
            | grep -ciE '(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)' || true)
    fi
    # Also check untracked new test files
    local _new_test_files=0
    _new_test_files=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -ciE '(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)' || true)

    if [[ "$_test_files_changed" -eq 0 ]] && [[ "$_new_test_files" -eq 0 ]]; then
        warnings="${warnings:+${warnings}
}warn_no_test: Bug fix has no regression test coverage. Consider adding a test that reproduces the original bug."
    fi

    # Check: does CODER_SUMMARY.md contain a Root Cause Analysis section?
    if [[ -f "CODER_SUMMARY.md" ]]; then
        if ! grep -qi "## Root Cause" CODER_SUMMARY.md 2>/dev/null; then
            warnings="${warnings:+${warnings}
}warn_no_rca: No root cause analysis provided. Future debugging may repeat the same investigation."
        fi
    fi

    echo "$warnings"
}

# --- FEAT acceptance ----------------------------------------------------------

# check_feat_acceptance — Checks for conventional file placement.
# Returns warnings as newline-separated strings via stdout.
check_feat_acceptance() {
    local warnings=""

    # Get newly created files (untracked + staged new)
    local _new_files=""
    _new_files=$(git ls-files --others --exclude-standard 2>/dev/null || true)
    local _staged_new=""
    _staged_new=$(git diff --cached --name-only --diff-filter=A 2>/dev/null || true)
    _new_files="${_new_files}${_staged_new:+
${_staged_new}}"
    # Deduplicate (untracked + staged new can overlap)
    if [[ -n "$_new_files" ]]; then
        _new_files=$(echo "$_new_files" | sort -u)
    fi

    if [[ -z "$_new_files" ]]; then
        echo "$warnings"
        return 0
    fi

    # Build list of common directory patterns from git tree
    local _common_dirs=""
    _common_dirs=$(git ls-files 2>/dev/null \
        | sed 's|/[^/]*$||' \
        | sort | uniq -c | sort -rn \
        | head -20 \
        | awk '{print $2}' || true)

    if [[ -z "$_common_dirs" ]]; then
        echo "$warnings"
        return 0
    fi

    # Check each new file — is its parent directory in the common patterns?
    while IFS= read -r newfile; do
        [[ -z "$newfile" ]] && continue
        local _dir
        _dir=$(dirname "$newfile")
        # Skip files at repo root — can't check convention
        [[ "$_dir" = "." ]] && continue
        # Skip test files — they have their own conventions
        if echo "$newfile" | grep -qiE '(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)'; then
            continue
        fi
        # Check if this directory is already established (exact line match)
        if ! echo "$_common_dirs" | grep -qxF "$_dir"; then
            # Find the closest matching directory by prefix
            local _parent_dir
            _parent_dir=$(dirname "$_dir")
            local _suggested=""
            if [[ "$_parent_dir" != "." ]]; then
                _suggested=$(echo "$_common_dirs" | grep -F "$_parent_dir" | head -1 || true)
            fi
            if [[ -n "$_suggested" ]] && [[ "$_suggested" != "$_dir" ]]; then
                warnings="${warnings:+${warnings}
}warn_file_placement: New file '${newfile}' may not follow project conventions. Expected location: ${_suggested}/"
            fi
        fi
    done <<< "$_new_files"

    echo "$warnings"
}

# --- POLISH acceptance --------------------------------------------------------

# check_polish_acceptance — Checks for unintended logic file modifications.
# Returns warnings as newline-separated strings via stdout.
check_polish_acceptance() {
    local warnings=""
    local logic_patterns="${POLISH_LOGIC_FILE_PATTERNS:-*.py *.js *.ts *.sh *.go *.rs *.java *.rb *.c *.cpp *.h}"

    # Get all changed files
    local _changed_files=""
    _changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
    local _staged_files=""
    _staged_files=$(git diff --cached --name-only 2>/dev/null || true)
    _changed_files="${_changed_files}${_staged_files:+
${_staged_files}}"

    if [[ -z "$_changed_files" ]]; then
        echo "$warnings"
        return 0
    fi

    local _logic_files=""
    local pat
    for pat in $logic_patterns; do
        # Convert glob to grep pattern: *.py -> \.py$
        local _ext="${pat#\*}"
        _ext=$(printf '%s' "$_ext" | sed 's/\./\\./g')
        local _matched
        _matched=$(echo "$_changed_files" | grep -E "${_ext}$" || true)
        if [[ -n "$_matched" ]]; then
            # Exclude test files — tests for polish are fine
            _matched=$(echo "$_matched" | grep -viE '(test[_/]|_test\.|\.test\.|\.spec\.|tests/|spec/)' || true)
            if [[ -n "$_matched" ]]; then
                _logic_files="${_logic_files:+${_logic_files}
}${_matched}"
            fi
        fi
    done

    if [[ -n "$_logic_files" ]]; then
        # Deduplicate
        _logic_files=$(echo "$_logic_files" | sort -u)
        local _list
        _list=$(echo "$_logic_files" | tr '\n' ', ' | sed 's/,$//')
        warnings="warn_logic_modified: Polish note modified logic files: ${_list}. This may indicate scope creep beyond the visual/UX change."
    fi

    echo "$warnings"
}

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
        [[ "$file" == CODER_SUMMARY.md ]] && continue
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

# --- Main entry point ---------------------------------------------------------

# run_note_acceptance — Run tag-specific acceptance checks after coder completes.
# Logs warnings to CODER_SUMMARY.md and stores results in note metadata.
# Arguments: none (reads NOTES_FILTER global)
# Returns: 0 always (warnings, not blockers)
run_note_acceptance() {
    local tag="${NOTES_FILTER:-}"
    if [[ -z "$tag" ]]; then
        return 0
    fi

    local warnings=""
    case "$tag" in
        BUG)    warnings=$(check_bug_acceptance) ;;
        FEAT)   warnings=$(check_feat_acceptance) ;;
        POLISH) warnings=$(check_polish_acceptance) ;;
        *)      return 0 ;;
    esac

    if [[ -z "$warnings" ]]; then
        log "Note acceptance [${tag}]: pass"
        # Store acceptance result in note metadata for claimed notes
        _store_acceptance_result "pass" ""
        return 0
    fi

    # Log warnings
    warn "Note acceptance [${tag}]: warnings found"
    local _warning_codes=""
    local _code=""
    local _msg=""
    while IFS= read -r w; do
        [[ -z "$w" ]] && continue
        _code="${w%%:*}"
        _msg="${w#*: }"
        warn "  ${_msg}"
        _warning_codes="${_warning_codes:+${_warning_codes},}${_code}"
    done <<< "$warnings"

    # Append warnings to CODER_SUMMARY.md
    if [[ -f "CODER_SUMMARY.md" ]]; then
        {
            echo ""
            echo "## Acceptance Warnings"
            while IFS= read -r w; do
                [[ -z "$w" ]] && continue
                local _msg="${w#*: }"
                echo "- ${_msg}"
            done <<< "$warnings"
        } >> CODER_SUMMARY.md
    fi

    # Store result in note metadata
    _store_acceptance_result "$_warning_codes" "$warnings"
    return 0
}

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
