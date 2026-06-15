#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# milestone_acceptance.sh — Milestone acceptance criteria checking
#
# Sourced by tekhton.sh via milestone_ops.sh — do not run directly.
# Expects: milestones.sh to be sourced first (parse_milestones, get_milestone_title)
# Expects: TEST_CMD, ANALYZE_CMD from config
# Expects: log(), warn(), success(), header() from common.sh
# Expects: run_build_gate() from gates.sh
#
# Provides:
#   check_milestone_acceptance — run automatable acceptance criteria
#   _milestone_substantive_file_count — count non-artifact changed files
# =============================================================================

# _milestone_substantive_file_count
# m27 — Echoes the number of changed/new files in the working tree that are NOT
# pure pipeline artifacts (state, logs, manifest, milestone files, version,
# changelog, session dir). Nothing commits mid-milestone, so at acceptance time
# the working-tree diff vs HEAD plus untracked files IS the milestone's complete
# output. A count of 0 means the agent produced no real work — the signal that
# distinguishes a genuine completion from a no-op self-reported COMPLETE.
# S2 deliverable-gate helpers (_milestone_declared_files / _milestone_changed_set).
if ! declare -f _milestone_declared_files >/dev/null 2>&1; then
    # shellcheck source=milestone_acceptance_deliverable.sh disable=SC1091
    source "${TEKHTON_HOME}/lib/milestone_acceptance_deliverable.sh"
fi

_milestone_substantive_file_count() {
    local _session_base
    _session_base=$(basename "${TEKHTON_SESSION_DIR:-__nosession__}")
    # Artifact prefixes the pipeline itself writes — these never count as work.
    local _excl='^\.tekhton/|^\.claude/logs/|^\.claude/milestones/|^\.claude/project_version\.cfg$|^VERSION$|^CHANGELOG\.md$'
    if [[ "$_session_base" != "__nosession__" ]]; then
        _excl="${_excl}|^${_session_base}/"
    fi
    {
        git diff --name-only HEAD 2>/dev/null || true
        git ls-files --others --exclude-standard 2>/dev/null || true
    } | grep -vE "$_excl" | grep -c '.' || true
}

# check_milestone_acceptance MILESTONE_NUM [CLAUDE_MD_PATH]
# Runs automatable acceptance criteria for a milestone.
# Returns 0 if all automatable criteria pass, 1 if any fail.
# Prints a report of checked criteria.
check_milestone_acceptance() {
    local milestone_num="$1"
    local claude_md="${2:-${PROJECT_RULES_FILE:-CLAUDE.md}}"

    header "Checking acceptance criteria — Milestone ${milestone_num}"

    local all_pass=true

    # Acceptance lint moved to authoring time (see draft_milestones_validate_output
    # in lib/draft_milestones_write.sh). Runtime acceptance checking is pass/fail only.

    # --- Automatable check 1: Test command passes ---
    if [[ -n "${TEST_CMD:-}" ]]; then
        # m42: short-circuit when TEST_CMD is a recognized no-op so milestone
        # acceptance does not silently tick green on `bash -c "true"`. Surfaces
        # the same honest "tests: skipped" line run_final_checks emits, and
        # records the false state so RUN_RESULT.json reflects the gap.
        if declare -f _is_noop_test_cmd &>/dev/null && _is_noop_test_cmd "${TEST_CMD:-}"; then
            warn "tests: skipped (no-op TEST_CMD: '${TEST_CMD:-}') — milestone acceptance is not exercising the project's tests."
            if declare -f _record_tests_run_state &>/dev/null; then
                _record_tests_run_state "false"
            fi
        else
        log "Running test command: ${TEST_CMD:-true}"
        local test_output=""
        local test_exit=0
        if declare -f test_dedup_can_skip &>/dev/null && test_dedup_can_skip; then
            log "[dedup] Tests passed with no file changes since last run — skipping"
            if command -v emit_event &>/dev/null; then
                emit_event "test_dedup_skip" "${_CURRENT_STAGE:-milestone_acceptance}" \
                    "fingerprint_match=true" "" "" "" >/dev/null 2>&1 || true
            fi
            test_output="[dedup] Cached pass — no files changed since last successful test run"
            test_exit=0
        else
            test_output=$(run_op "Running acceptance tests" bash -c "${TEST_CMD:-true}" 2>&1) || test_exit=$?
            if [[ "$test_exit" -eq 0 ]] && declare -f test_dedup_record_pass &>/dev/null; then
                test_dedup_record_pass
            fi
        fi

        if [[ "$test_exit" -eq 0 ]]; then
            success "Tests pass"
        else
            # Save output for Tier 2 stuck detection
            if command -v save_acceptance_test_output &>/dev/null; then
                save_acceptance_test_output "$test_output" "$test_exit"
            fi

            # Tier 1: compare against baseline
            local _baseline_assessment="none"
            if [[ "${TEST_BASELINE_ENABLED:-true}" = "true" ]] \
               && declare -f compare_test_with_baseline &>/dev/null \
               && declare -f has_test_baseline &>/dev/null \
               && has_test_baseline; then
                _baseline_assessment=$(compare_test_with_baseline "$test_output" "$test_exit")
            fi

            case "$_baseline_assessment" in
                pre_existing)
                    if [[ "${TEST_BASELINE_PASS_ON_PREEXISTING:-false}" = "true" ]]; then
                        warn "Tests FAILED (exit ${test_exit}) — ALL failures match pre-existing baseline"
                        warn "Treating as PASS for acceptance (PASS_ON_PREEXISTING=true opt-in)"
                        if command -v emit_event &>/dev/null; then
                            emit_event "acceptance_preexisting_pass" "acceptance" \
                                "test_exit=${test_exit}, assessment=pre_existing" \
                                "" "" "" >/dev/null 2>&1 || true
                        fi
                    else
                        warn "Tests FAILED (exit ${test_exit}) — pre-existing failures no longer auto-pass (M92)"
                        warn "All tests must pass. Set TEST_BASELINE_PASS_ON_PREEXISTING=true to opt out."
                        echo "$test_output" | tail -20
                        all_pass=false
                    fi
                    ;;
                new_failures)
                    warn "Tests FAILED (exit ${test_exit}) — NEW failures detected since baseline"
                    echo "$test_output" | tail -20
                    all_pass=false
                    ;;
                *)
                    # inconclusive or no baseline — standard failure behavior
                    warn "Tests FAILED (exit ${test_exit})"
                    echo "$test_output" | tail -20
                    all_pass=false
                    ;;
            esac
        fi
        fi  # /m42 noop short-circuit
    else
        log "No TEST_CMD configured — skipping test check"
    fi

    # --- Automatable check 2: Build gate passes ---
    if [[ -n "${ANALYZE_CMD:-}" ]]; then
        if run_build_gate "milestone-acceptance" 2>/dev/null; then
            success "Build gate passes"
        else
            warn "Build gate FAILED"
            all_pass=false
        fi
    else
        log "No ANALYZE_CMD configured — skipping build gate check"
    fi

    # --- Automatable check 3: Check for files mentioned in acceptance criteria ---
    # S5 — read criteria from the active milestone's DAG .md file first; CLAUDE.md
    # carries no inline milestone criteria under DAG mode, so the pre-S5 read
    # always came back empty and check 3 silently no-op'd. Fall back to the inline
    # CLAUDE.md parse for non-DAG projects.
    local criteria_line=""
    if [[ "${MILESTONE_DAG_ENABLED:-true}" = true ]] \
       && declare -f _milestone_criteria_semijoined &>/dev/null; then
        criteria_line=$(_milestone_criteria_semijoined "$milestone_num")
    fi
    if [[ -z "$criteria_line" ]]; then
        local all_ms_data
        all_ms_data=$(parse_milestones "$claude_md" 2>/dev/null) || true
        criteria_line=$(echo "$all_ms_data" | awk -F'|' -v n="$milestone_num" '$1 == n {print $3; exit}')
    fi

    if [[ -n "$criteria_line" ]]; then
        _run_automatable_criteria "$criteria_line" || all_pass=false
    fi

    # --- Automatable check 4: Docs strict mode — block on unresolved doc findings ---
    if [[ "${DOCS_STRICT_MODE:-false}" = "true" ]] \
       && [[ -f "${REVIEWER_REPORT_FILE:-}" ]]; then
        # Use -E (extended regex) for portable alternation (BRE | is GNU-only).
        # Patterns are intentionally broad to catch varied reviewer phrasing:
        #   "Docs Updated: missing", "documentation not updated", "docs absent", etc.
        local docs_block
        docs_block=$(grep -ciE 'docs? (updated?|change|section).*missing|doc(umentation)? (not |un)updated?|doc(umentation|s)? absent|missing doc(umentation|s)? update' \
            "${REVIEWER_REPORT_FILE:-.tekhton/REVIEWER_REPORT.md}" 2>/dev/null || true)
        if [[ "$docs_block" -gt 0 ]]; then
            warn "DOCS_STRICT_MODE: reviewer flagged missing doc updates (${docs_block} finding(s))"
            all_pass=false
        fi
    fi

    # --- Automatable check 5: Substantive-work backstop (m27) ---
    # Pre-m27 acceptance passed on TEST_CMD + ANALYZE_CMD alone, so a no-op
    # agent that self-reported "Status: COMPLETE" left the suite green and was
    # falsely marked done (the m21/m22/m24 false completions). A milestone must
    # produce real (non-artifact) file changes to complete. Set
    # MILESTONE_REQUIRE_SUBSTANTIVE_WORK=false to revert to pre-m27 behavior.
    if [[ "${MILESTONE_MODE:-false}" = true ]] \
       && [[ "${MILESTONE_REQUIRE_SUBSTANTIVE_WORK:-true}" = true ]]; then
        local _subst_count
        _subst_count=$(_milestone_substantive_file_count)
        _subst_count="${_subst_count:-0}"
        if [[ "$_subst_count" -lt 1 ]]; then
            warn "Acceptance FAILED — milestone ${milestone_num} produced no substantive file changes (only pipeline artifacts)."
            warn "A no-op cannot complete a milestone. Set MILESTONE_REQUIRE_SUBSTANTIVE_WORK=false to override."
            if command -v emit_event &>/dev/null; then
                emit_event "acceptance_failed_no_substantive_work" "acceptance" \
                    "milestone=${milestone_num}, substantive_files=0" "" "" "" >/dev/null 2>&1 || true
            fi
            all_pass=false
        else
            success "Substantive work present (${_subst_count} non-artifact file(s) changed)"
        fi
    fi

    # --- Automatable check 6: Declared-deliverable gate (S2) ---
    # m27 proves SOME file changed; this proves the milestone's DECLARED
    # deliverables exist. A "Create"/"Add" file that is absent is a hard block
    # (this is exactly how m22 self-completed without building profile.go). A
    # declared "Modify" target that wasn't touched is a non-blocking drift note
    # (the change may legitimately have landed elsewhere). Set
    # MILESTONE_DELIVERABLE_GATE_ENABLED=false to revert.
    if [[ "${MILESTONE_MODE:-false}" = true ]] \
       && [[ "${MILESTONE_DELIVERABLE_GATE_ENABLED:-true}" = true ]]; then
        local _decl _changed _missing=() _drift=() _dpath _dtype
        _decl=$(_milestone_declared_files "$milestone_num")
        if [[ -z "$_decl" ]]; then
            log "Deliverable gate: no parseable '## Files Modified' table — skipping."
        else
            _changed=$(_milestone_changed_set)
            while IFS=$'\t' read -r _dpath _dtype; do
                [[ -z "$_dpath" ]] && continue
                case "$_dtype" in
                    Delete|delete) continue ;;
                    Create|create|Add|add)
                        [[ -e "$_dpath" ]] || _missing+=( "$_dpath" ) ;;
                    *)
                        grep -qxF "$_dpath" <<< "$_changed" || _drift+=( "$_dpath" ) ;;
                esac
            done <<< "$_decl"

            if [[ ${#_drift[@]} -gt 0 ]]; then
                warn "Deliverable gate: ${#_drift[@]} declared 'Modify' file(s) not in the changeset (drift, non-blocking): ${_drift[*]}"
            fi
            if [[ ${#_missing[@]} -gt 0 ]]; then
                warn "Acceptance FAILED — milestone ${milestone_num} declares file(s) it never created: ${_missing[*]}"
                warn "Build the declared deliverables or correct the milestone's Files Modified table. Set MILESTONE_DELIVERABLE_GATE_ENABLED=false to override."
                if command -v emit_event &>/dev/null; then
                    emit_event "acceptance_failed_missing_deliverable" "acceptance" \
                        "milestone=${milestone_num}, missing=${_missing[*]}" "" "" "" >/dev/null 2>&1 || true
                fi
                all_pass=false
            else
                success "Declared deliverables present"
            fi
        fi
    fi

    echo

    if [[ "$all_pass" = true ]]; then
        success "All automatable acceptance criteria PASS for milestone ${milestone_num}"
        return 0
    else
        warn "Some acceptance criteria FAILED for milestone ${milestone_num}"
        return 1
    fi
}
