#!/usr/bin/env bash
# =============================================================================
# stages/cleanup.sh — Post-success autonomous debt sweep stage
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
#
# Runs AFTER the primary pipeline (coder → review → tester) completes
# successfully. Selects a batch of accumulated non-blocking notes and invokes
# the jr coder model to address them. Build gate failure in cleanup logs a
# warning but does NOT fail the overall pipeline.
# =============================================================================

# should_run_cleanup — Returns 0 (true) if all cleanup trigger conditions are met.
# Trigger conditions (all must be true):
#   1. CLEANUP_ENABLED=true
#   2. Unresolved non-blocking count exceeds CLEANUP_TRIGGER_THRESHOLD
should_run_cleanup() {
    if [ "${CLEANUP_ENABLED:-false}" != "true" ]; then
        return 1
    fi

    local unresolved
    unresolved=$(count_unresolved_notes)
    local threshold="${CLEANUP_TRIGGER_THRESHOLD:-5}"

    if [ "$unresolved" -le "$threshold" ]; then
        return 1
    fi

    return 0
}

# run_stage_cleanup — Autonomous debt sweep stage.
#   1. Selects a batch of prioritized non-blocking notes
#   2. Invokes jr coder with cleanup-specific prompt
#   3. Runs build gate (failure = warning, not pipeline failure)
#   4. Parses agent output to mark resolved/deferred items
run_stage_cleanup() {
    header "Cleanup — Autonomous Debt Sweep"

    local unresolved
    unresolved=$(count_unresolved_notes)
    local batch_size="${CLEANUP_BATCH_SIZE:-5}"

    log "Unresolved non-blocking notes: ${unresolved} (threshold: ${CLEANUP_TRIGGER_THRESHOLD:-5})"
    log "Selecting up to ${batch_size} items for cleanup..."

    # Extract modified files from the primary pipeline's CODER_SUMMARY.md (if available)
    # so that select_cleanup_batch can prioritize notes overlapping with this run's work.
    local modified_files=""
    if [ -f "${PROJECT_DIR}/CODER_SUMMARY.md" ]; then
        modified_files=$(awk '/^## Files (Created|Modified)/{found=1; next} found && /^##/{exit} found && /^[-*]/{print}' \
            "${PROJECT_DIR}/CODER_SUMMARY.md" 2>/dev/null \
            | sed 's/^[-*][[:space:]]*//' | sed 's/ .*//' | sort -u || true)
    fi

    # Select prioritized batch
    local batch
    batch=$(select_cleanup_batch "$batch_size" "$modified_files")

    if [ -z "$batch" ]; then
        warn "No eligible notes for cleanup sweep."
        return 0
    fi

    local batch_count
    batch_count=$(echo "$batch" | count_lines)
    log "Selected ${batch_count} item(s) for cleanup sweep."

    # Strip the checkbox prefix for the prompt (agent sees just the note text)
    local cleanup_items
    # shellcheck disable=SC2001
    cleanup_items=$(echo "$batch" | sed 's/^- \[ \] /- /')

    # Export for prompt rendering
    export CLEANUP_ITEMS="$cleanup_items"
    export CLEANUP_ITEM_COUNT="$batch_count"

    local cleanup_prompt
    cleanup_prompt=$(render_prompt "cleanup")

    # Snapshot files modified by the primary pipeline BEFORE cleanup runs.
    # On build-gate failure we revert only cleanup-introduced changes, not these.
    # If the primary pipeline left uncommitted changes, they appear in this snapshot
    # and are thus protected from the cleanup revert logic.
    local pre_cleanup_files
    pre_cleanup_files=$(git diff --name-only 2>/dev/null || true)

    log "Invoking cleanup agent (jr coder, max ${CLEANUP_MAX_TURNS:-15} turns)..."

    # Ensure AGENT_TOOLS_CLEANUP is defined with a safe default.
    # Falls back to JR_CODER tools if not already exported from lib/agent.sh.
    local _cleanup_tools="${AGENT_TOOLS_CLEANUP:-${AGENT_TOOLS_JR_CODER:-}}"

    run_agent \
        "Cleanup" \
        "$CLAUDE_JR_CODER_MODEL" \
        "${CLEANUP_MAX_TURNS:-15}" \
        "$cleanup_prompt" \
        "$LOG_FILE" \
        "$_cleanup_tools"

    log "Cleanup agent finished."

    # --- Null run detection ---
    if was_null_run; then
        warn "Cleanup agent was a null run — no debt items addressed."
        return 0
    fi

    # --- Build gate (failure = warning only) ---
    local build_pass=true
    if ! run_build_gate "post-cleanup"; then
        warn "Build gate FAILED after cleanup sweep — reverting cleanup changes."
        warn "Cleanup changes may have introduced issues. Review BUILD_ERRORS.md."
        build_pass=false

        # Revert ONLY files that cleanup touched, preserving primary pipeline work.
        # Compare current modified files against the pre-cleanup snapshot.
        local post_cleanup_files
        post_cleanup_files=$(git diff --name-only 2>/dev/null || true)

        if [ -n "$post_cleanup_files" ]; then
            while IFS= read -r changed_file; do
                [ -z "$changed_file" ] && continue
                # Only revert if this file was NOT already modified before cleanup
                if ! echo "$pre_cleanup_files" | grep -qxF "$changed_file" 2>/dev/null; then
                    git checkout -- "$changed_file" 2>/dev/null || true
                fi
            done <<< "$post_cleanup_files"
        fi

    fi

    # --- Parse cleanup results and update NON_BLOCKING_LOG.md ---
    _process_cleanup_results "$batch" "$build_pass"

    local resolved_count
    resolved_count=$(_count_cleanup_resolved)
    local deferred_count
    deferred_count=$(_count_cleanup_deferred)

    if [ "$resolved_count" -gt 0 ] || [ "$deferred_count" -gt 0 ]; then
        success "Cleanup sweep: ${resolved_count} resolved, ${deferred_count} deferred."
    else
        log "Cleanup sweep: no items conclusively resolved or deferred."
    fi
}

# _process_cleanup_results — Parses CLEANUP_REPORT.md (if produced) or uses
# a heuristic to determine which items were addressed vs deferred.
# Args: $1 = batch (original notes), $2 = build_pass (true/false)
_process_cleanup_results() {
    local batch="$1"
    local build_pass="$2"

    _CLEANUP_RESOLVED=0
    _CLEANUP_DEFERRED=0

    # If build failed, none of the items are resolved
    if [ "$build_pass" != "true" ]; then
        warn "Build failed — no cleanup items marked resolved."
        return 0
    fi

    # Check if the agent produced a CLEANUP_REPORT.md with structured output
    if [ -f "CLEANUP_REPORT.md" ]; then
        _parse_cleanup_report "$batch"
        # Archive the cleanup report
        if [ -n "${LOG_DIR:-}" ] && [ -n "${TIMESTAMP:-}" ]; then
            mv "CLEANUP_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_CLEANUP_REPORT.md" 2>/dev/null || true
        fi
        return 0
    fi

    # Fallback: use file-change heuristic from CODER_SUMMARY.md
    # (the cleanup agent writes to CODER_SUMMARY.md or similar)
    _resolve_cleanup_by_file_changes "$batch"
}

# _parse_cleanup_report — Reads CLEANUP_REPORT.md for structured results.
# Expected format:
#   ## Resolved
#   - <note text excerpt>
#   ## Deferred
#   - [DEFERRED] <note text excerpt>: <reason>
#   ## Not Attempted
#   - <note text excerpt>
#
# NOTE: The "## Not Attempted" section is deliberately NOT parsed here.
# Items the agent did not attempt remain as open `[ ]` entries in
# NON_BLOCKING_LOG.md — no state change is needed. They will be
# re-selected in future cleanup sweeps.
_parse_cleanup_report() {
    local batch="$1"
    local report="CLEANUP_REPORT.md"

    # Extract resolved items
    local resolved_section
    resolved_section=$(awk '/^## Resolved/{found=1; next} found && /^##/{exit} found && /^- /{print}' \
        "$report" 2>/dev/null || true)

    # Extract deferred items
    local deferred_section
    deferred_section=$(awk '/^## Deferred/{found=1; next} found && /^##/{exit} found && /^- /{print}' \
        "$report" 2>/dev/null || true)

    # Match resolved items back to the original batch and mark [x]
    if [ -n "$resolved_section" ]; then
        while IFS= read -r resolved_line; do
            [ -z "$resolved_line" ] && continue
            # Strip leading "- " or "- [x] "
            local text
            # shellcheck disable=SC2001
            text=$(echo "$resolved_line" | sed 's/^- \(\[x\] \)\?//')

            # Try to find a matching note in the batch
            while IFS= read -r batch_line; do
                [ -z "$batch_line" ] && continue
                if echo "$batch_line" | grep -qF "$text" 2>/dev/null; then
                    if mark_note_resolved "$text"; then
                        _CLEANUP_RESOLVED=$((_CLEANUP_RESOLVED + 1))
                    fi
                    break
                fi
            done <<< "$batch"
        done <<< "$resolved_section"
    fi

    # Match deferred items back to the original batch and mark [DEFERRED]
    if [ -n "$deferred_section" ]; then
        while IFS= read -r deferred_line; do
            [ -z "$deferred_line" ] && continue
            # Strip leading "- " or "- [DEFERRED] "
            local text
            text=$(echo "$deferred_line" | sed 's/^- \(\[DEFERRED\] \)\?//' | sed 's/:.*//')

            while IFS= read -r batch_line; do
                [ -z "$batch_line" ] && continue
                if echo "$batch_line" | grep -qF "$text" 2>/dev/null; then
                    if mark_note_deferred "$text"; then
                        _CLEANUP_DEFERRED=$((_CLEANUP_DEFERRED + 1))
                    fi
                    break
                fi
            done <<< "$batch"
        done <<< "$deferred_section"
    fi
}

# _resolve_cleanup_by_file_changes — Fallback heuristic: if the agent modified
# a file referenced in a note, mark that note as resolved.
_resolve_cleanup_by_file_changes() {
    local batch="$1"

    # Get files modified since cleanup started (from git)
    local modified_files
    modified_files=$(git diff --name-only 2>/dev/null || true)

    if [ -z "$modified_files" ]; then
        return 0
    fi

    while IFS= read -r note_line; do
        [ -z "$note_line" ] && continue

        while IFS= read -r mod_file; do
            [ -z "$mod_file" ] && continue
            local basename_mod
            basename_mod=$(basename "$mod_file" 2>/dev/null || echo "$mod_file")
            if echo "$note_line" | grep -qF "$basename_mod" 2>/dev/null; then
                # Extract enough text to match in the log file
                local match_text
                # shellcheck disable=SC2001
                match_text=$(echo "$note_line" | sed 's/^- \[ \] //')
                if mark_note_resolved "$match_text"; then
                    _CLEANUP_RESOLVED=$((_CLEANUP_RESOLVED + 1))
                fi
                break
            fi
        done <<< "$modified_files"
    done <<< "$batch"
}

# _count_cleanup_resolved — Returns the count of items resolved in this sweep.
_count_cleanup_resolved() {
    echo "${_CLEANUP_RESOLVED:-0}"
}

# _count_cleanup_deferred — Returns the count of items deferred in this sweep.
_count_cleanup_deferred() {
    echo "${_CLEANUP_DEFERRED:-0}"
}
