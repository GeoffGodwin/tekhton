#!/usr/bin/env bash
# =============================================================================
# stages/coder.sh — Stage 1: Coder (scout + implement + gates)
#
# Sourced by tekhton.sh — do not run directly.
# Expects all pipeline globals to be set (TASK, LOG_FILE, TIMESTAMP, etc.)
# =============================================================================

# _switch_to_sub_milestone — After a milestone split, update state to target
# the first sub-milestone (N.1). Sets _CURRENT_MILESTONE, TASK, and milestone
# state. Must be called in the same scope (not a subshell) so variable
# assignments propagate to the caller.
#
# Arguments:
#   $1 — current milestone number (the one that was just split)
#   $2 — path to CLAUDE.md
_switch_to_sub_milestone() {
    local _ms_num="$1"
    local _claude_md="$2"
    local _first_sub="${_ms_num}.1"
    # Title may be empty if the split agent used a heading format that
    # get_milestone_title doesn't match — task still proceeds with the number alone.
    local _first_title
    _first_title=$(get_milestone_title "$_first_sub" "$_claude_md" 2>/dev/null) || true

    _CURRENT_MILESTONE="$_first_sub"
    TASK="Implement Milestone ${_first_sub}: ${_first_title}"
    log "Task updated: ${TASK}"

    init_milestone_state "$_first_sub" "$(get_milestone_count "$_claude_md")"
}

# _reconstruct_coder_summary — Synthesize a minimal CODER_SUMMARY.md from git state.
# Called when the coder agent did substantive work but failed to produce or
# maintain the summary file. This allows the pipeline to proceed to review
# instead of crashing. The reviewer will assess actual file changes.
_reconstruct_coder_summary() {
    local _files_changed=""
    local _diff_stat=""
    local _untracked_files=""

    # Tracked modifications
    if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
        _files_changed=$(git diff --name-only HEAD 2>/dev/null | head -30)
        _diff_stat=$(git diff --stat HEAD 2>/dev/null | tail -5)
    fi

    # Untracked new files (excluding logs and session dirs)
    _untracked_files=$(git ls-files --others --exclude-standard 2>/dev/null \
        | grep -v '^\.claude/logs/' \
        | grep -v "^$(basename "${TEKHTON_SESSION_DIR:-__nosession__}")/" \
        | head -30)

    cat > CODER_SUMMARY.md <<RECON_EOF
## Status: IN PROGRESS

## Summary
CODER_SUMMARY.md was reconstructed by the pipeline after the coder agent
failed to produce or maintain it. The following files were modified based
on git state. The reviewer should assess actual changes directly.

## Files Modified
$(while IFS= read -r _f; do [ -n "$_f" ] && echo "- $_f"; done <<< "$_files_changed")

## New Files Created
$(while IFS= read -r _f; do [ -n "$_f" ] && echo "- $_f (new)"; done <<< "$_untracked_files")

## Git Diff Summary
\`\`\`
${_diff_stat}
\`\`\`

## Remaining Work
Unable to determine — coder did not report remaining items.
Review the task description against actual changes to identify gaps.
RECON_EOF
    warn "Reconstructed CODER_SUMMARY.md ($(wc -l < CODER_SUMMARY.md) lines) from git state."
}

# run_stage_coder — Runs the full coder stage including:
#   1. Optional scout sub-agent (for BUG/FEAT notes)
#   2. Context block construction (architecture, glossary, milestone, prior reports)
#   3. Coder agent invocation
#   4. IN PROGRESS / turn-limit handling with state save
#   5. Completion gate
#   6. Build gate with one retry
#
# Exits the pipeline (exit 1) on unrecoverable failure, saving state for resume.
# On success, CODER_SUMMARY.md exists and the build passes.
run_stage_coder() {
    local _stage_count="${PIPELINE_STAGE_COUNT:-4}"
    local _stage_pos="${PIPELINE_STAGE_POS:-1}"
    header "Stage ${_stage_pos} / ${_stage_count} — Coder"

    # --- Scout sub-agent (optional) ------------------------------------------
    BUG_SCOUT_CONTEXT=""
    SHOULD_SCOUT=false

    if [ "$NOTES_FILTER" = "BUG" ] && [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        SHOULD_SCOUT=true
    elif [ "$NOTES_FILTER" = "FEAT" ] && [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        # Only scout features that extend existing systems — not greenfield work
        if echo "$TASK$(extract_human_notes)" | grep -qiE "extend|add to|modify|integrate|update|change|existing"; then
            SHOULD_SCOUT=true
        fi
    elif [ "${DYNAMIC_TURNS_ENABLED}" = "true" ]; then
        # Scout for complexity estimation even without human notes
        SHOULD_SCOUT=true
    fi

    # Use cached scout results from dry-run if available (Milestone 23)
    if [[ "${SCOUT_CACHED:-false}" == "true" ]] && [[ -f "SCOUT_REPORT.md" ]]; then
        SHOULD_SCOUT=false
        log "Scout: using cached results from dry-run."
        apply_scout_turn_limits "SCOUT_REPORT.md"
        BUG_SCOUT_CONTEXT="
## Scout Report (pre-located relevant files — read THESE files, not the whole project)
$(cat SCOUT_REPORT.md)
"
        # Archive the cached report same as a live one
        cp "SCOUT_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md"
        rm "SCOUT_REPORT.md"
    fi

    if [ "$SHOULD_SCOUT" = true ]; then
        log "Running scout agent to locate relevant files and estimate complexity..."

        export HUMAN_NOTES_CONTENT
        HUMAN_NOTES_CONTENT=$(extract_human_notes)

        # Build architecture block for scout if available
        ARCHITECTURE_BLOCK=""
        if [ -f "${ARCHITECTURE_FILE}" ]; then
            local _arch_content
            _arch_content=$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")
            ARCHITECTURE_BLOCK="
## Architecture Map (use this to find files — do NOT explore blindly)
$(_wrap_file_content "ARCHITECTURE" "$_arch_content")"
        fi

        # Generate full repo map for scout (biggest token savings — replaces blind find/grep)
        export REPO_MAP_CONTENT=""
        if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]]; then
            log "[indexer] Generating repo map for scout..."
            if run_repo_map "$TASK"; then
                log "[indexer] Repo map generated (${#REPO_MAP_CONTENT} chars)."
            fi
        fi

        SCOUT_PROMPT=$(render_prompt "scout")

        run_agent \
            "Scout" \
            "$CLAUDE_SCOUT_MODEL" \
            "${SCOUT_MAX_TURNS}" \
            "$SCOUT_PROMPT" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_SCOUT"

        if [ -f "SCOUT_REPORT.md" ]; then
            print_run_summary
            success "Scout agent finished. Relevant files located."

            # Parse complexity estimate before archiving the report
            apply_scout_turn_limits "SCOUT_REPORT.md"

            BUG_SCOUT_CONTEXT="
## Scout Report (pre-located relevant files — read THESE files, not the whole project)
$(cat SCOUT_REPORT.md)
"
            # --- Pre-flight milestone sizing gate ---------------------------------
            # After scout estimates complexity, check if the milestone is oversized.
            # If so, split it into sub-milestones and re-scout the first one.
            if [ "$MILESTONE_MODE" = true ] && [ -n "${_CURRENT_MILESTONE:-}" ]; then
                if ! check_milestone_size "$_CURRENT_MILESTONE" "${SCOUT_REC_CODER_TURNS:-0}"; then
                    log "Milestone ${_CURRENT_MILESTONE} exceeds sizing threshold. Splitting..."

                    if split_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"; then
                        # Update to target the first sub-milestone
                        _switch_to_sub_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"

                        # Archive original scout report and re-scout narrower scope
                        cp "SCOUT_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT_presplit.md"
                        rm "SCOUT_REPORT.md"

                        log "Re-running scout for narrower sub-milestone ${_CURRENT_MILESTONE}..."

                        SCOUT_PROMPT=$(render_prompt "scout")
                        run_agent \
                            "Scout (post-split)" \
                            "$CLAUDE_SCOUT_MODEL" \
                            "${SCOUT_MAX_TURNS}" \
                            "$SCOUT_PROMPT" \
                            "$LOG_FILE" \
                            "$AGENT_TOOLS_SCOUT"

                        if [ -f "SCOUT_REPORT.md" ]; then
                            print_run_summary
                            success "Post-split scout finished."
                            apply_scout_turn_limits "SCOUT_REPORT.md"
                            BUG_SCOUT_CONTEXT="
## Scout Report (pre-located relevant files — read THESE files, not the whole project)
$(cat SCOUT_REPORT.md)
"
                            cp "SCOUT_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md"
                            rm "SCOUT_REPORT.md"
                        else
                            warn "Post-split scout did not produce SCOUT_REPORT.md — coder will explore independently."
                        fi
                    else
                        warn "Milestone split failed — proceeding with original scope."
                    fi
                fi
            fi

            # Archive scout report with the run
            if [ -f "SCOUT_REPORT.md" ]; then
                cp "SCOUT_REPORT.md" "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md"
                rm "SCOUT_REPORT.md"
            fi
        elif was_null_run; then
            print_run_summary
            warn "Scout was a null run (${LAST_AGENT_TURNS} turns) — coder will explore independently."
        else
            warn "Scout agent did not produce SCOUT_REPORT.md — coder will explore independently."
        fi
    fi

    # --- Repo map for coder (task-biased or scout-sliced) -------------------

    export REPO_MAP_CONTENT="${REPO_MAP_CONTENT:-}"
    if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]]; then
        # If we already have a full map from scout, try to slice it to scout-identified files
        if [[ -n "$REPO_MAP_CONTENT" ]] && [[ -n "$BUG_SCOUT_CONTEXT" ]]; then
            # Extract file paths from the scout report context
            local _scout_files=""
            if [[ -f "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md" ]]; then
                _scout_files=$(extract_files_from_coder_summary "${LOG_DIR}/${TIMESTAMP}_SCOUT_REPORT.md")
            fi
            if [[ -n "$_scout_files" ]]; then
                local _slice
                if _slice=$(get_repo_map_slice "$_scout_files"); then
                    REPO_MAP_CONTENT="$_slice"
                    log "[indexer] Repo map sliced to scout-identified files."
                fi
            fi
        elif [[ -z "$REPO_MAP_CONTENT" ]]; then
            # No map from scout phase — generate a fresh task-biased map
            log "[indexer] Generating repo map for coder..."
            if run_repo_map "$TASK"; then
                log "[indexer] Repo map generated (${#REPO_MAP_CONTENT} chars)."
            fi
        fi
    fi

    # --- Build context blocks for prompt template ----------------------------

    # Human notes block
    HUMAN_NOTES_BLOCK=""
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        case "$NOTES_FILTER" in
            BUG)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_BUG:-These are confirmed bugs. The scout report below has already located the relevant files — read THOSE files first, not the whole project. Find the root cause, fix it, then document your Root Cause Analysis in CODER_SUMMARY.md.}"
                ;;
            FEAT)
                local _default_feat="These are new feature requests. Read ${PROJECT_RULES_FILE} and ${ARCHITECTURE_FILE} before writing any code. New configurable values must use the project's config system — never hardcoded."
                NOTE_GUIDANCE="${NOTES_GUIDANCE_FEAT:-$_default_feat}"
                ;;
            POLISH)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_POLISH:-These are visual/UX polish items. No logic changes. Focus only on UI files and config.}"
                ;;
            *)
                NOTE_GUIDANCE="${NOTES_GUIDANCE_DEFAULT:-Implement scoped items directly. Flag anything ambiguous or architectural in CODER_SUMMARY.md.}"
                ;;
        esac

        export HUMAN_NOTES_BLOCK
        HUMAN_NOTES_BLOCK="
## Human Notes [${NOTES_FILTER:-ALL}]
${NOTE_GUIDANCE}

$(extract_human_notes)
${BUG_SCOUT_CONTEXT}"
    fi

    # Architecture context
    export ARCHITECTURE_BLOCK=""
    if [ -f "${ARCHITECTURE_FILE}" ]; then
        local _arch_main
        _arch_main=$(_safe_read_file "${ARCHITECTURE_FILE}" "ARCHITECTURE_FILE")
        ARCHITECTURE_BLOCK="
## Architecture Map (read FIRST — saves you 10+ turns of exploration)
$(_wrap_file_content "ARCHITECTURE" "$_arch_main")"
    fi

    export GLOSSARY_BLOCK=""
    if [ -n "${GLOSSARY_FILE}" ] && [ -f "${GLOSSARY_FILE}" ]; then
        GLOSSARY_BLOCK="
## Glossary (use these terms precisely — do not invent synonyms)
$(cat "${GLOSSARY_FILE}")"
    fi

    export MILESTONE_BLOCK=""
    if [ "$MILESTONE_MODE" = true ]; then
        # DAG path: use character-budgeted sliding window when manifest exists
        if [[ "${MILESTONE_DAG_ENABLED:-true}" == "true" ]] \
           && declare -f build_milestone_window &>/dev/null \
           && has_milestone_manifest 2>/dev/null; then
            build_milestone_window "$CLAUDE_CODER_MODEL" || true
        fi

        # Fallback: static block when no DAG or window build failed
        if [[ -z "$MILESTONE_BLOCK" ]]; then
            MILESTONE_BLOCK="
## Milestone Mode
This is a milestone-sized task. Before writing any code:
1. Read the relevant Milestone section in ${PROJECT_RULES_FILE} in full
2. Check the 'Seeds forward' annotations on this milestone for architectural decisions
   that must be made now to avoid rework later
3. Note any 'Watch for' annotations and design those extension points into your implementation
4. Document your architectural decisions in CODER_SUMMARY.md under '## Architecture Decisions'"
        fi
    fi

    # Prior reviewer context (unresolved blockers from a previous run)
    export PRIOR_REVIEWER_CONTEXT=""
    if [ -f "REVIEWER_REPORT.md" ] && [ "$START_AT" = "coder" ]; then
        local _reviewer_content
        _reviewer_content=$(_safe_read_file "REVIEWER_REPORT.md" "REVIEWER_REPORT")
        PRIOR_REVIEWER_CONTEXT="
## Prior Reviewer Report (unresolved blockers from last run)
The previous pipeline run ended with these unresolved items.
Fix the Complex and Simple Blockers listed below — do not re-implement anything already done.
Non-Blocking Notes are optional improvements if turns allow.

$(_wrap_file_content "REVIEWER_REPORT" "$_reviewer_content")"
    fi

    # Prior progress context (partial git diff from turn-limit resume)
    export PRIOR_PROGRESS_CONTEXT=""
    if [ -f "$PIPELINE_STATE_FILE" ]; then
        PRIOR_EXIT_REASON=$(grep "^## Exit Reason" -A1 "$PIPELINE_STATE_FILE" 2>/dev/null | tail -1 | tr -d '[:space:]' || true)
        if [ "$PRIOR_EXIT_REASON" = "turn_limit" ]; then
            PRIOR_GIT_DIFF=$(awk '/^## Partial Git Changes/{found=1; next} found && /^## /{exit} found{print}' "$PIPELINE_STATE_FILE")
            if [ -n "$PRIOR_GIT_DIFF" ]; then
                PRIOR_PROGRESS_CONTEXT="
## Previous Run Partial Progress
The last coder run hit the turn limit mid-implementation. These files were already modified:
${PRIOR_GIT_DIFF}

Check CODER_SUMMARY.md for what was completed. Do NOT redo work already done.
Pick up from where the previous run left off — read the modified files first to understand current state."
            fi
        fi
    fi

    # Prior tester bugs
    export PRIOR_TESTER_CONTEXT=""
    if [ -f "TESTER_REPORT.md" ] && grep -q "^### Bugs Found\|^## Bugs\|BUG-" TESTER_REPORT.md 2>/dev/null; then
        local _tester_content
        _tester_content=$(_safe_read_file "TESTER_REPORT.md" "TESTER_REPORT")
        PRIOR_TESTER_CONTEXT="
## Bugs Found by Tester (must fix)
The tester identified these bugs in the last run. Fix all BUG-* items before
doing anything else. Do not re-implement anything already working.

$(_wrap_file_content "TESTER_REPORT" "$_tester_content")"
    fi

    # Pre-finalization test gate failures (from orchestrate.sh retry loop)
    export PREFLIGHT_TEST_CONTEXT=""
    if [[ -f "PREFLIGHT_ERRORS.md" ]] && [[ "$START_AT" = "coder" ]]; then
        local _preflight_content
        _preflight_content=$(_safe_read_file "PREFLIGHT_ERRORS.md" "PREFLIGHT_ERRORS")
        PREFLIGHT_TEST_CONTEXT="
## Pre-Finalization Test Failures (must fix)
The pipeline completed all stages successfully, but the final test gate failed.
Fix ONLY these test failures — do not re-implement features already working.

$(_wrap_file_content "PREFLIGHT_ERRORS" "$_preflight_content")"
    fi

    # Accumulated non-blocking notes (injected when above threshold)
    export NON_BLOCKING_CONTEXT=""
    local nb_count
    nb_count=$(count_open_nonblocking_notes)
    local nb_threshold="${NON_BLOCKING_INJECTION_THRESHOLD:-8}"
    if [ "$nb_count" -gt "$nb_threshold" ]; then
        local nb_notes
        nb_notes=$(get_open_nonblocking_notes)
        NON_BLOCKING_CONTEXT="
## Accumulated Tech Debt (${nb_count} items)
These are non-blocking reviewer notes that have accumulated over multiple runs.
If your task specifies which items to address, follow the task scope exactly.
Otherwise, address as many as your remaining turns allow. For each item you
address, note the file and what you changed. Items you cannot reach are fine to skip.

${nb_notes}"
        warn "Non-blocking notes (${nb_count}) exceed threshold (${nb_threshold}) — injecting into coder prompt."
    fi

    # --- TDD pre-flight context (Milestone 27) --------------------------------
    # When PIPELINE_ORDER=test_first, inject TESTER_PREFLIGHT.md content so the
    # coder knows which tests to make pass.
    export TESTER_PREFLIGHT_CONTENT=""
    if [[ "${PIPELINE_ORDER:-standard}" == "test_first" ]]; then
        local _preflight_file="${TDD_PREFLIGHT_FILE:-TESTER_PREFLIGHT.md}"
        if [[ -f "$_preflight_file" ]]; then
            TESTER_PREFLIGHT_CONTENT=$(_safe_read_file "$_preflight_file" "TESTER_PREFLIGHT")
            log "TDD mode: injecting ${_preflight_file} into coder context."
        else
            warn "TDD mode active but ${_preflight_file} not found — coder will proceed without pre-written tests."
        fi
    fi

    # --- Clarification context (from prior pause) ----------------------------

    load_clarifications_content
    export CLARIFICATIONS_CONTENT

    # --- Context compiler (task-scoped filtering) ----------------------------
    # NOTE: build_context_packet is called before should_claim_notes intentionally.
    # It takes explicit args (not HUMAN_NOTES_BLOCK global), so the ordering is safe.

    build_context_packet "coder" "$TASK" "$CLAUDE_CODER_MODEL"

    # --- Context budget reporting --------------------------------------------

    # Mark human notes as in-progress before coder runs (only when task is about notes)
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ] && should_claim_notes; then
        claim_human_notes
    elif [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
        log "Human notes exist but no notes flag set (--human, --with-notes, or --notes-filter) — skipping notes injection."
        HUMAN_NOTES_BLOCK=""
    fi

    _add_context_component "Architecture" "$ARCHITECTURE_BLOCK"
    _add_context_component "Repo Map" "${REPO_MAP_CONTENT:-}"
    _add_context_component "Glossary" "$GLOSSARY_BLOCK"
    _add_context_component "Milestone" "$MILESTONE_BLOCK"
    _add_context_component "Human Notes" "$HUMAN_NOTES_BLOCK"
    _add_context_component "Prior Reviewer" "$PRIOR_REVIEWER_CONTEXT"
    _add_context_component "Prior Progress" "$PRIOR_PROGRESS_CONTEXT"
    _add_context_component "Prior Tester" "$PRIOR_TESTER_CONTEXT"
    _add_context_component "Preflight Tests" "$PREFLIGHT_TEST_CONTEXT"
    _add_context_component "Non-Blocking Notes" "$NON_BLOCKING_CONTEXT"
    _add_context_component "Scout Report" "$BUG_SCOUT_CONTEXT"
    _add_context_component "Clarifications" "$CLARIFICATIONS_CONTENT"
    _add_context_component "TDD Preflight" "${TESTER_PREFLIGHT_CONTENT:-}"
    log_context_report "coder" "$CLAUDE_CODER_MODEL"

    # --- Invoke coder agent --------------------------------------------------

    # TDD turn multiplier: give the coder slightly more budget when working
    # against pre-written tests (Milestone 27)
    if [[ "${PIPELINE_ORDER:-standard}" == "test_first" ]] && [[ -n "${TESTER_PREFLIGHT_CONTENT:-}" ]]; then
        local _base_turns="${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS}"
        local _multiplier="${CODER_TDD_TURN_MULTIPLIER:-1.2}"
        # bash doesn't do float math — use awk
        local _boosted_turns
        _boosted_turns=$(awk "BEGIN { printf \"%.0f\", ${_base_turns} * ${_multiplier} }")
        ADJUSTED_CODER_TURNS="$_boosted_turns"
        log "TDD mode: coder turn budget boosted ${_base_turns} → ${_boosted_turns} (×${_multiplier})."
    fi

    CODER_PROMPT=$(render_prompt "coder")

    log "Invoking coder agent (max ${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS} turns)..."
    run_agent \
        "Coder" \
        "$CLAUDE_CODER_MODEL" \
        "${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS}" \
        "$CODER_PROMPT" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_CODER"
    print_run_summary

    # Export actual coder turns for post-coder recalibration (Milestone 9)
    export ACTUAL_CODER_TURNS="${LAST_AGENT_TURNS:-0}"

    # --- UPSTREAM error detection (12.2) — API failures are not scope issues ---

    if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
        error "Coder agent hit an API error: ${AGENT_ERROR_MESSAGE}"
        write_pipeline_state \
            "coder" \
            "upstream_error" \
            "${MILESTONE_MODE:+--milestone }--start-at coder" \
            "$TASK" \
            "API error (${AGENT_ERROR_SUBCATEGORY}): ${AGENT_ERROR_MESSAGE}. This is transient — re-run the same command."

        error "State saved. This was an API failure, not a scope issue. Re-run the same command."
        exit 1
    fi

    success "Coder agent finished."

    # --- Null run detection ---------------------------------------------------

    if was_null_run; then
        error "Coder agent was a null run — it died before doing meaningful work."
        error "This usually means the agent couldn't find files, hit a permission error,"
        error "or the prompt was too complex for initial discovery."

        # Reset claimed notes — coder didn't produce any work
        if [ "$HUMAN_NOTE_COUNT" -gt 0 ]; then
            resolve_human_notes
        fi

        # --- Null-run auto-split for milestone mode ---
        # Instead of saving state and exiting, try to split the milestone
        # and re-run from scout stage with the narrower sub-milestone.
        if [ "$MILESTONE_MODE" = true ] && [ -n "${_CURRENT_MILESTONE:-}" ]; then
            if handle_null_run_split "$_CURRENT_MILESTONE" "CLAUDE.md"; then
                # Split succeeded — update state and re-run from scout
                _switch_to_sub_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"

                # Recursive call to run_stage_coder creates nested call frames up to
                # MILESTONE_MAX_SPLIT_DEPTH deep. With default of 3, this is safe.
                local _depth
                _depth=$(get_split_depth "$_CURRENT_MILESTONE")
                warn "Auto-split complete — re-running coder stage for milestone ${_CURRENT_MILESTONE} (depth ${_depth}/${MILESTONE_MAX_SPLIT_DEPTH:-3})..."
                run_stage_coder
                return
            fi
        fi

        write_pipeline_state \
            "coder" \
            "null_run" \
            "--start-at coder" \
            "$TASK" \
            "Agent used ${LAST_AGENT_TURNS} turn(s) and exited ${LAST_AGENT_EXIT_CODE}. Likely died during initial file discovery. Consider: narrower task description, adding a SCOUT_REPORT.md manually, or checking agent logs."

        error "State saved with exit reason 'null_run'. Check the log: ${LOG_FILE}"
        error "Re-run with a more specific task description or add context files."
        exit 1
    fi

    # --- Post-coder validation -----------------------------------------------

    if [ ! -f "CODER_SUMMARY.md" ]; then
        # If substantive work was done, reconstruct summary and continue
        if is_substantive_work; then
            warn "Coder did not produce CODER_SUMMARY.md but substantive work detected."
            _reconstruct_coder_summary
        elif [[ "${LAST_AGENT_TURNS:-0}" -ge "${ADJUSTED_CODER_TURNS:-${CODER_MAX_TURNS:-50}}" ]]; then
            # Coder exhausted its turn budget without producing a summary and
            # without substantive tracked/untracked changes. This is a scope
            # problem (too much exploration, not enough implementation), not a
            # hard crash. Classify explicitly so the orchestration loop can
            # attempt recovery (split or retry).
            warn "Coder exhausted turn budget (${LAST_AGENT_TURNS} turns) without CODER_SUMMARY.md or substantive work."
            AGENT_ERROR_CATEGORY="AGENT_SCOPE"
            AGENT_ERROR_SUBCATEGORY="turn_exhaustion_no_output"
            AGENT_ERROR_MESSAGE="Coder used all ${LAST_AGENT_TURNS} turns but produced no CODER_SUMMARY.md and no substantive file changes."

            # Attempt milestone split before giving up
            if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                if handle_null_run_split "$_CURRENT_MILESTONE" "CLAUDE.md"; then
                    _switch_to_sub_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"
                    local _depth
                    _depth=$(get_split_depth "$_CURRENT_MILESTONE")
                    warn "Auto-split after turn exhaustion — re-running for milestone ${_CURRENT_MILESTONE} (depth ${_depth}/${MILESTONE_MAX_SPLIT_DEPTH:-3})..."
                    run_stage_coder
                    return
                fi
            fi

            error "Coder did not produce CODER_SUMMARY.md and no substantive work detected."
            error "Check the log: ${LOG_FILE}"
            error "To resume at review stage once resolved: $0 --start-at review \"${TASK}\""
            # Reset claimed notes — coder didn't produce any work
            resolve_human_notes

            write_pipeline_state \
                "coder" \
                "turn_exhaustion_no_output" \
                "${MILESTONE_MODE:+--milestone }--start-at coder" \
                "$TASK" \
                "Coder used ${LAST_AGENT_TURNS} turns but produced no output. Likely spent turns exploring without implementing. Consider: narrower task, manual scout report, or milestone split."
            exit 1
        else
            error "Coder did not produce CODER_SUMMARY.md and no substantive work detected."
            error "Check the log: ${LOG_FILE}"
            error "To resume at review stage once resolved: $0 --start-at review \"${TASK}\""
            # Reset claimed notes — coder didn't produce any work
            resolve_human_notes
            exit 1
        fi
    fi

    # Resolve human notes based on coder's structured reporting
    # Only resolve if notes were actually claimed (marked [~]) for this run
    if [ "$HUMAN_NOTE_COUNT" -gt 0 ] && should_claim_notes; then
        resolve_human_notes
    fi

    # --- Post-coder clarification detection ------------------------------------

    if detect_clarifications "CODER_SUMMARY.md"; then
        if ! handle_clarifications; then
            # User aborted — save state for resume
            write_pipeline_state \
                "coder" \
                "clarification_abort" \
                "${MILESTONE_MODE:+--milestone }--start-at coder" \
                "$TASK" \
                "Clarification collection aborted by user. Partial answers in CLARIFICATIONS.md."
            error "Pipeline paused for clarification. Re-run to resume."
            exit 1
        fi

        # Re-run coder with clarification answers if blocking items were answered
        local blocking_file="${TEKHTON_SESSION_DIR}/clarify_blocking.txt"
        if [[ -s "$blocking_file" ]]; then
            log "Re-running coder with clarification answers..."

            # Reload clarifications into context
            load_clarifications_content
            export CLARIFICATIONS_CONTENT

            CODER_PROMPT=$(render_prompt "coder")

            run_agent \
                "Coder (post-clarification)" \
                "$CLAUDE_CODER_MODEL" \
                "${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS}" \
                "$CODER_PROMPT" \
                "$LOG_FILE" \
                "$AGENT_TOOLS_CODER"
            print_run_summary
            success "Post-clarification coder finished."

            # Update actual coder turns to reflect post-clarification run
            # so reviewer/tester recalibration uses the most recent data
            export ACTUAL_CODER_TURNS="${LAST_AGENT_TURNS:-0}"

            # --- Null run detection for post-clarification run ---
            if was_null_run; then
                error "Post-clarification coder was a null run — produced no meaningful work."
                write_pipeline_state \
                    "coder" \
                    "null_run_post_clarification" \
                    "--start-at coder" \
                    "$TASK" \
                    "Post-clarification coder used ${LAST_AGENT_TURNS} turn(s) and exited ${LAST_AGENT_EXIT_CODE}. Consider: clarification answers may be incomplete, or agent couldn't translate them into code changes."

                error "State saved with exit reason 'null_run_post_clarification'. Re-run to retry."
                exit 1
            fi

            # Re-check for CODER_SUMMARY.md
            if [[ ! -f "CODER_SUMMARY.md" ]]; then
                error "Post-clarification coder did not produce CODER_SUMMARY.md."
                exit 1
            fi
        fi
    fi

    # Check if coder left status as IN PROGRESS (hit turn limit mid-work)
    CODER_STATUS=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || echo "")
    if [[ "$CODER_STATUS" == *"IN PROGRESS"* ]]; then
        warn "Coder summary shows IN PROGRESS — coder hit turn limit before finishing."

        # --- Turn exhaustion continuation loop (Milestone 14) ---
        if [[ "${CONTINUATION_ENABLED:-true}" = "true" ]] && is_substantive_work; then
            local _cont_attempt=0
            local _cont_max="${MAX_CONTINUATION_ATTEMPTS:-3}"
            local _cumulative_turns="${ACTUAL_CODER_TURNS:-0}"

            while [[ "$_cont_attempt" -lt "$_cont_max" ]]; do
                _cont_attempt=$((_cont_attempt + 1))
                log "Coder hit turn limit with progress (attempt ${_cont_attempt}/${_cont_max}). Continuing..."

                # Build continuation context and inject into prompt
                local _next_budget="${ADJUSTED_CODER_TURNS:-$CODER_MAX_TURNS}"
                export CONTINUATION_CONTEXT
                CONTINUATION_CONTEXT=$(build_continuation_context "coder" "$_cont_attempt" "$_cont_max" "$_cumulative_turns" "$_next_budget")

                CODER_PROMPT=$(render_prompt "coder")

                run_agent \
                    "Coder (continuation ${_cont_attempt})" \
                    "$CLAUDE_CODER_MODEL" \
                    "$_next_budget" \
                    "$CODER_PROMPT" \
                    "$LOG_FILE" \
                    "$AGENT_TOOLS_CODER"
                print_run_summary

                _cumulative_turns=$((_cumulative_turns + ${LAST_AGENT_TURNS:-0}))
                export ACTUAL_CODER_TURNS="$_cumulative_turns"

                # Check for UPSTREAM errors in continuation
                if [[ "${AGENT_ERROR_CATEGORY:-}" = "UPSTREAM" ]]; then
                    error "Continuation coder hit an API error: ${AGENT_ERROR_MESSAGE}"
                    write_pipeline_state \
                        "coder" \
                        "upstream_error" \
                        "${MILESTONE_MODE:+--milestone }--start-at coder" \
                        "$TASK" \
                        "API error during continuation attempt ${_cont_attempt}: ${AGENT_ERROR_MESSAGE}."
                    error "State saved. Re-run the same command."
                    exit 1
                fi

                # Check if continuation completed
                if [[ ! -f "CODER_SUMMARY.md" ]]; then
                    warn "Continuation ${_cont_attempt} did not produce CODER_SUMMARY.md."
                    # Recover: if substantive work exists, synthesize a minimal summary
                    # so the pipeline can proceed to review instead of crashing.
                    if is_substantive_work; then
                        warn "Substantive work detected — reconstructing CODER_SUMMARY.md from git state."
                        _reconstruct_coder_summary
                    else
                        break
                    fi
                fi

                CODER_STATUS=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || echo "")
                if [[ "$CODER_STATUS" == *"COMPLETE"* ]]; then
                    success "Coder completed after ${_cont_attempt} continuation(s) (${_cumulative_turns} total turns)."
                    # Export for metrics
                    export CONTINUATION_ATTEMPTS="$_cont_attempt"
                    # Clear continuation context so it doesn't leak into downstream prompts
                    export CONTINUATION_CONTEXT=""
                    break 2  # Break out of both continuation while and the outer if
                fi

                # Check if continuation made substantive progress worth continuing further
                if ! is_substantive_work; then
                    warn "Continuation ${_cont_attempt} did not produce substantive additional work."
                    break
                fi
            done

            # Export continuation attempts for metrics regardless of outcome
            export CONTINUATION_ATTEMPTS="${_cont_attempt}"
            # Clear continuation context
            export CONTINUATION_CONTEXT=""

            # Re-check status after continuation loop
            CODER_STATUS=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || echo "")
            if [[ "$CODER_STATUS" == *"COMPLETE"* ]]; then
                # Continuation succeeded — fall through to completion gate
                :
            elif [[ "$_cont_attempt" -ge "$_cont_max" ]]; then
                warn "Coder exhausted all ${_cont_max} continuation attempts."
                # Escalate: milestone mode -> try auto-split, otherwise save state
                if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                    if handle_null_run_split "$_CURRENT_MILESTONE" "CLAUDE.md"; then
                        _switch_to_sub_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"
                        local _depth
                        _depth=$(get_split_depth "$_CURRENT_MILESTONE")
                        warn "Auto-split after continuation exhaustion — re-running for milestone ${_CURRENT_MILESTONE} (depth ${_depth}/${MILESTONE_MAX_SPLIT_DEPTH:-3})..."
                        run_stage_coder
                        return
                    fi
                fi
                # Fall through to save-state-and-exit below
            fi
        fi

        # If we reach here and status is still IN PROGRESS, check if we have
        # enough work to proceed to review instead of halting.
        CODER_STATUS=$(grep "^## Status" CODER_SUMMARY.md 2>/dev/null | head -1 || echo "")
        if [[ "$CODER_STATUS" == *"IN PROGRESS"* ]]; then
            IMPLEMENTED_LINES=$(grep -c "^- " CODER_SUMMARY.md 2>/dev/null || echo "0")
            IMPLEMENTED_LINES=$(echo "$IMPLEMENTED_LINES" | tr -d '[:space:]')

            GIT_DIFF_STAT=""
            if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
                GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -20)
            fi

            # If continuations were exhausted and substantive work exists,
            # proceed to review instead of halting. The reviewer catches gaps.
            if [[ "${_cont_attempt:-0}" -ge "${_cont_max:-3}" ]] && is_substantive_work; then
                warn "Continuations exhausted with IN PROGRESS status but substantive work exists."
                warn "Proceeding to review — reviewer will identify remaining gaps."
                # Skip the state-save-and-exit — fall through to completion gate
                :
            elif [[ "$IMPLEMENTED_LINES" -gt 3 ]]; then
                RESUME_FLAG="--milestone --start-at coder"
                RESUME_NOTE="Coder hit turn limit mid-implementation (${IMPLEMENTED_LINES} summary lines). Git diff shows partial work — coder should CONTINUE, not restart."

                local _state_notes="${RESUME_NOTE}"
                if [[ -n "$GIT_DIFF_STAT" ]]; then
                    _state_notes="${_state_notes}

## Partial Git Changes (files touched before turn limit)
\`\`\`
${GIT_DIFF_STAT}
\`\`\`"
                fi

                write_pipeline_state \
                    "coder" \
                    "turn_limit" \
                    "$RESUME_FLAG" \
                    "$TASK" \
                    "$_state_notes"

                warn "Check the log: ${LOG_FILE}"
                warn "State saved — re-run with no arguments to resume."
                exit 1
            else
                # Minimal output — try auto-split in milestone mode
                if [[ "$MILESTONE_MODE" = true ]] && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
                    if handle_null_run_split "$_CURRENT_MILESTONE" "CLAUDE.md"; then
                        _switch_to_sub_milestone "$_CURRENT_MILESTONE" "CLAUDE.md"
                        local _depth
                        _depth=$(get_split_depth "$_CURRENT_MILESTONE")
                        warn "Auto-split complete — re-running coder stage for milestone ${_CURRENT_MILESTONE} (depth ${_depth}/${MILESTONE_MAX_SPLIT_DEPTH:-3})..."
                        run_stage_coder
                        return
                    fi
                fi

                RESUME_FLAG="--milestone"
                RESUME_NOTE="Coder hit turn limit with minimal summary output — retry from scratch recommended."

                local _state_notes="${RESUME_NOTE}"
                if [[ -n "$GIT_DIFF_STAT" ]]; then
                    _state_notes="${_state_notes}

## Partial Git Changes (files touched before turn limit)
\`\`\`
${GIT_DIFF_STAT}
\`\`\`"
                fi

                write_pipeline_state \
                    "coder" \
                    "turn_limit" \
                    "$RESUME_FLAG" \
                    "$TASK" \
                    "$_state_notes"

                warn "Check the log: ${LOG_FILE}"
                warn "State saved — re-run with no arguments to resume."
                exit 1
            fi
        fi
    fi

    # --- Completion gate -----------------------------------------------------

    if ! run_completion_gate; then
        # If substantive work exists (files modified, meaningful diff), proceed
        # to review anyway. The reviewer will assess actual changes. This prevents
        # the pipeline from halting when the coder did real work but failed to
        # set the Status field correctly.
        if is_substantive_work; then
            warn "Completion gate failed but substantive work detected."
            warn "Proceeding to review — reviewer will assess actual changes."
            # Ensure CODER_SUMMARY.md exists for downstream stages
            if [[ ! -f "CODER_SUMMARY.md" ]]; then
                _reconstruct_coder_summary
            fi
        else
            warn "Coder did not complete — blocking reviewer and tester."

            GIT_DIFF_STAT=$(git diff --stat HEAD 2>/dev/null | tail -20 || echo "no changes")

            if [ "$MILESTONE_MODE" = true ]; then
                RESUME_FLAG="--milestone --start-at coder"
            else
                RESUME_FLAG="--start-at coder"
            fi

            write_pipeline_state \
                "coder" \
                "incomplete" \
                "$RESUME_FLAG" \
                "$TASK" \
                "Coder hit turn limit mid-implementation. Reviewer and tester were NOT run. Resume will continue coder work before proceeding."

            error "Pipeline halted at completion gate."
            error "State saved — re-run with no arguments to resume."
            exit 1
        fi
    fi

    # --- Build gate (with one retry) -----------------------------------------

    BUILD_GATE_RETRY=0
    if ! run_build_gate "post-coder"; then
        if [ "$BUILD_GATE_RETRY" -lt 1 ]; then
            BUILD_GATE_RETRY=1
            warn "Invoking coder to fix build errors (1 retry allowed)..."
            export BUILD_ERRORS_CONTENT
            BUILD_ERRORS_CONTENT=$(_wrap_file_content "BUILD_ERRORS" "$(_safe_read_file BUILD_ERRORS.md "BUILD_ERRORS")")
            BUILD_FIX_PROMPT=$(render_prompt "build_fix")

            run_agent \
                "Coder (build fix)" \
                "$CLAUDE_CODER_MODEL" \
                "$((CODER_MAX_TURNS / 3))" \
                "$BUILD_FIX_PROMPT" \
                "$LOG_FILE" \
                "$AGENT_TOOLS_BUILD_FIX"
            log "Build fix coder finished."

            if ! run_build_gate "post-coder-fix"; then
                error "Build gate failed again after fix attempt."
                write_pipeline_state \
                    "coder" \
                    "build_failure" \
                    "--start-at coder" \
                    "$TASK" \
                    "Build errors remain after auto-fix attempt. See BUILD_ERRORS.md."
                error "State saved. Review BUILD_ERRORS.md manually then re-run."
                exit 1
            fi
        fi
    fi

    # --- Record task→file association for personalized ranking (M7) ----------
    if [[ "${INDEXER_AVAILABLE:-false}" == "true" ]]; then
        local _modified_files
        _modified_files=$(extract_files_from_coder_summary "CODER_SUMMARY.md")
        if [[ -n "$_modified_files" ]]; then
            record_task_file_association "$TASK" "$_modified_files" || true
        fi
    fi
}
