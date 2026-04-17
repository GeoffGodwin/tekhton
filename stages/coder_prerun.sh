#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# stages/coder_prerun.sh — Pre-coder clean sweep (M92)
#
# When tests fail before the coder runs, spawn a restricted Jr Coder fix agent
# to restore a clean baseline. If the fix succeeds, the coder starts from a
# passing test suite and capture_test_baseline is re-invoked so the baseline
# reflects the clean state. If the fix fails, the pipeline warns loudly and
# proceeds — "can't fix everything" is acknowledged; silent acceptance is not.
#
# Sourced by stages/coder.sh — do not run directly.
#
# Provides:
#   run_prerun_clean_sweep   — orchestrator called at top of run_stage_coder
#   _run_prerun_fix_agent    — inner fix loop (mirrors _try_preflight_fix)
# =============================================================================

# _run_prerun_fix_agent PRERUN_OUTPUT PRERUN_EXIT
# Returns 0 if tests pass after fix, 1 if fix attempts are exhausted.
# The shell runs TEST_CMD independently after each attempt — the agent never
# sees its own test output.
_run_prerun_fix_agent() {
    local _pr_output="$1"
    local _pr_exit="$2"

    local _pr_max="${PRE_RUN_FIX_MAX_ATTEMPTS:-1}"
    local _pr_model="${PREFLIGHT_FIX_MODEL:-${CLAUDE_JR_CODER_MODEL:-claude-sonnet-4-6}}"
    local _pr_turns="${PRE_RUN_FIX_MAX_TURNS:-${JR_CODER_MAX_TURNS:-20}}"
    local _pr_attempt=0

    # Pre-run fix has no "changed files" context — this is the state *before*
    # the coder runs, so the diff would be stale from the previous milestone.
    local _pr_changed_files=""

    local _pr_initial_fail_count
    _pr_initial_fail_count=$(printf '%s\n' "$_pr_output" | grep -ciE '(FAIL|ERROR|error|failure)' || echo "0")

    while [[ "$_pr_attempt" -lt "$_pr_max" ]]; do
        _pr_attempt=$(( _pr_attempt + 1 ))
        warn "[coder/prerun] Fix attempt ${_pr_attempt}/${_pr_max}..."

        if declare -f emit_event &>/dev/null; then
            emit_event "prerun_fix_start" "prerun_fix" \
                "attempt ${_pr_attempt}/${_pr_max}" "" "" "" > /dev/null 2>&1 || true
        fi

        # Reuse the preflight_fix template — same shape (test output + rules).
        export PREFLIGHT_TEST_OUTPUT
        PREFLIGHT_TEST_OUTPUT=$(printf '%s\n' "$_pr_output" | tail -120)
        export PREFLIGHT_CHANGED_FILES="$_pr_changed_files"

        local _pr_prompt
        _pr_prompt=$(render_prompt "preflight_fix")

        run_agent \
            "Pre-Run Fix (attempt ${_pr_attempt})" \
            "$_pr_model" \
            "$_pr_turns" \
            "$_pr_prompt" \
            "$LOG_FILE" \
            "$AGENT_TOOLS_BUILD_FIX"

        log "[coder/prerun] Shell verifying with ${TEST_CMD}..."
        local _pr_verify_exit=0
        local _pr_verify_output=""
        _pr_verify_output=$(bash -c "${TEST_CMD}" 2>&1) || _pr_verify_exit=$?
        printf '%s\n' "$_pr_verify_output" >> "$LOG_FILE"

        if [[ "$_pr_verify_exit" -eq 0 ]]; then
            success "[coder/prerun] Tests pass after attempt ${_pr_attempt}."
            if declare -f emit_event &>/dev/null; then
                emit_event "prerun_fix_end" "prerun_fix" \
                    "fixed on attempt ${_pr_attempt}" "" "" "" > /dev/null 2>&1 || true
            fi
            return 0
        fi

        local _pr_new_fail_count
        _pr_new_fail_count=$(printf '%s\n' "$_pr_verify_output" | grep -ciE '(FAIL|ERROR|error|failure)' || echo "0")
        # +2 threshold matches _try_preflight_fix: tolerates noisy "0 errors"-style
        # lines from frameworks while still catching real regressions.
        if [[ "$_pr_new_fail_count" -gt "$(( _pr_initial_fail_count + 2 ))" ]]; then
            warn "[coder/prerun] Attempt ${_pr_attempt} introduced new failures (${_pr_new_fail_count} vs ${_pr_initial_fail_count}). Aborting."
            break
        fi

        _pr_output="$_pr_verify_output"
        warn "[coder/prerun] Attempt ${_pr_attempt} did not resolve failures."
    done

    if declare -f emit_event &>/dev/null; then
        emit_event "prerun_fix_end" "prerun_fix" \
            "exhausted ${_pr_max} attempts" "" "" "" > /dev/null 2>&1 || true
    fi
    return 1
}

# run_prerun_clean_sweep
# Called at the top of run_stage_coder() before the scout/coder agents.
# If PRE_RUN_CLEAN_ENABLED=true and tests are failing, spawn a restricted fix
# agent. On success, re-capture the test baseline so downstream gates see the
# clean state. On failure, warn loudly and let the pipeline proceed — the
# stricter post-run gates (with PASS_ON_PREEXISTING=false default) will
# surface the breakage anyway.
run_prerun_clean_sweep() {
    if [[ "${PRE_RUN_CLEAN_ENABLED:-true}" != "true" ]]; then
        return 0
    fi
    if [[ -z "${TEST_CMD:-}" ]] || [[ "${TEST_CMD}" = "true" ]]; then
        return 0
    fi

    log "[coder/prerun] Checking pre-coder test state..."
    local _prerun_exit=0
    local _prerun_output=""
    _prerun_output=$(bash -c "${TEST_CMD}" 2>&1) || _prerun_exit=$?

    if [[ "$_prerun_exit" -eq 0 ]]; then
        log "[coder/prerun] Tests pass — coder will work from a clean state."
        return 0
    fi

    warn "[coder/prerun] Tests failing before coder runs (exit ${_prerun_exit}) — attempting pre-run fix."
    if _run_prerun_fix_agent "$_prerun_output" "$_prerun_exit"; then
        # Re-capture baseline so it reflects the achieved clean state, not the
        # dirty pre-fix state. Delete the old baseline file first so
        # _should_capture_test_baseline / capture_test_baseline run fresh.
        if declare -f capture_test_baseline &>/dev/null; then
            local _baseline_json="${PROJECT_DIR:-.}/.claude/TEST_BASELINE.json"
            [[ -f "$_baseline_json" ]] && rm -f "$_baseline_json"
            capture_test_baseline "${_CURRENT_MILESTONE:-}" || true
            log "[coder/prerun] Baseline re-captured after successful fix."
        fi
        return 0
    fi

    warn "[coder/prerun] Pre-run fix incomplete. Coder will work from a non-pristine state."
    warn "[coder/prerun] Set PRE_RUN_CLEAN_ENABLED=false to skip this check."
    return 0
}
