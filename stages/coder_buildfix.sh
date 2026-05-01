#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
# =============================================================================
# stages/coder_buildfix.sh — Build-fix routing (M127) + continuation loop (M128)
#
# Sourced by stages/coder.sh — do not run directly.
#
# M127 (mixed-log routing) classifies build errors into one of four tokens
# (code_dominant / noncode_dominant / mixed_uncertain / unknown_only) emitted
# by lib/error_patterns_classify.sh. Token policy:
#
#   noncode_dominant  → skip build-fix, route to human action, exit
#   code_dominant     → run build-fix coder with code-filtered errors
#   mixed_uncertain   → emit BUILD_ROUTING_DIAGNOSIS.md, then run build-fix
#                       with code-filtered errors plus a non-code context block
#   unknown_only      → run build-fix with low-confidence guidance,
#                       preserving pre-M127 fallback semantics
#
# M128 (continuation loop) wraps the dispatch in an attempt-bounded loop
# with adaptive turn budgets and progress gating. Top-level entry is
# run_build_fix_loop. Pure helpers live in coder_buildfix_helpers.sh.
# =============================================================================

# shellcheck source=stages/coder_buildfix_helpers.sh
source "${TEKHTON_HOME}/stages/coder_buildfix_helpers.sh"

# _bf_read_raw_errors — Read raw error stream, preferring BUILD_RAW_ERRORS_FILE
# over the annotated BUILD_ERRORS_FILE. Annotated markdown contains
# classification headers (e.g. "## Classified as Code Error") whose own text
# matches code patterns and would skew routing toward code_dominant.
_bf_read_raw_errors() {
    if [[ -f "${BUILD_RAW_ERRORS_FILE}" ]]; then
        _safe_read_file "${BUILD_RAW_ERRORS_FILE}" "BUILD_RAW_ERRORS"
    else
        _safe_read_file "${BUILD_ERRORS_FILE}" "BUILD_ERRORS"
    fi
}

# _bf_invoke_build_fix LABEL EXTRA_CONTEXT RAW_ERRORS BUDGET — render
# build_fix prompt and invoke the coder agent with an explicit turn
# budget. EXTRA_CONTEXT is appended to BUILD_ERRORS_CONTENT so per-route
# guidance (mixed-uncertain non-code summary, unknown-only low-confidence
# note) is visible to the agent. BUDGET overrides the legacy base/3
# default — the caller (M128 loop) computes adaptive budgets via
# _compute_build_fix_budget.
_bf_invoke_build_fix() {
    local label="$1"
    local extra_context="${2:-}"
    local raw="$3"
    local budget="${4:-}"

    local body
    if command -v filter_code_errors &>/dev/null; then
        body=$(filter_code_errors "$raw")
    else
        body="$raw"
    fi
    if [[ -n "$extra_context" ]]; then
        body="${body}"$'\n\n'"${extra_context}"
    fi

    export BUILD_ERRORS_CONTENT
    BUILD_ERRORS_CONTENT=$(_wrap_file_content "BUILD_ERRORS" "$body")
    local prompt
    prompt=$(render_prompt "build_fix")

    local _bf_base="${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}}"
    local turns="${budget:-$(( _bf_base / 3 ))}"
    if (( turns < 8 )); then turns=8; fi

    run_agent \
        "Coder (build fix${label:+ — $label})" \
        "$CLAUDE_CODER_MODEL" \
        "$turns" \
        "$prompt" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_BUILD_FIX"
    log "Build fix coder finished."
}

# run_build_fix_loop — Top-level entry replacing the legacy single-attempt
# build-fix path. Returns 0 on success (gate passes), exits 1 on terminal
# failure with state saved. Always exports the four Goal-7 env vars.
#
# Outcomes (BUILD_FIX_OUTCOME): passed | exhausted | no_progress | not_run
#  - not_run     loop did not execute (gate already passed, BUILD_FIX_ENABLED
#                =false, or M127 short-circuited via noncode_dominant)
#  - passed      gate passed during the loop
#  - exhausted   loop ran BUILD_FIX_MAX_ATTEMPTS without a passing gate
#  - no_progress loop bailed early because the progress signal stalled
run_build_fix_loop() {
    # Reset Goal-7 stats. Caller (run_stage_coder) already resets at stage
    # start; we re-initialize here so the loop's own counters are clean
    # whether or not the caller did the right thing.
    export BUILD_FIX_ATTEMPTS=0
    export BUILD_FIX_TURN_BUDGET_USED=0
    export BUILD_FIX_PROGRESS_GATE_FAILURES=0
    _export_build_fix_stats "not_run"

    if [[ "${BUILD_FIX_ENABLED:-true}" != "true" ]]; then
        warn "BUILD_FIX_ENABLED=false — skipping build-fix continuation loop."
        write_pipeline_state \
            "coder" \
            "build_failure" \
            "$(_build_resume_flag coder)" \
            "$TASK" \
            "Build errors remain; build-fix loop disabled (BUILD_FIX_ENABLED=false). See ${BUILD_ERRORS_FILE}."
        error "State saved. Review ${BUILD_ERRORS_FILE} manually then re-run."
        exit 1
    fi

    local raw_errors
    raw_errors=$(_bf_read_raw_errors)

    local decision="code_dominant"
    if command -v classify_routing_decision &>/dev/null; then
        decision=$(classify_routing_decision "$raw_errors")
        # The function's own export is bound to the cmd-sub subshell.
        # Re-export so M128/M130 consumers in the parent shell observe it.
        export LAST_BUILD_CLASSIFICATION="$decision"
    fi
    log "Build-fix routing decision: ${decision}"

    if [[ "$decision" == "noncode_dominant" ]]; then
        warn "Build errors classified as noncode_dominant: skipping build-fix loop."
        warn "These errors require environment remediation, not code changes."
        if command -v append_human_action &>/dev/null; then
            append_human_action "build_gate" \
                "Non-code build errors detected (routing=noncode_dominant). See ${BUILD_ERRORS_FILE} for details."
        fi
        # not_run stats already exported above.
        write_pipeline_state \
            "coder" \
            "env_failure" \
            "$(_build_resume_flag coder)" \
            "$TASK" \
            "Build failed with environment errors (not code bugs). See ${BUILD_ERRORS_FILE}."
        error "State saved. Fix environment issues in ${BUILD_ERRORS_FILE} then re-run."
        exit 1
    fi

    if [[ "$decision" == "mixed_uncertain" ]]; then
        _bf_emit_routing_diagnosis "$raw_errors"
    fi

    # Surface unrecognized tokens. Known tokens (code_dominant, mixed_uncertain,
    # unknown_only) all fall through to the build-fix loop; an unknown token
    # also falls through, but we emit a warn line so reviewer / dashboard /
    # diagnose can spot a routing classifier drift between M127, M128 and M130.
    case "$decision" in
        code_dominant|mixed_uncertain|unknown_only) ;;
        *) warn "Build-fix loop received unrecognized routing token '${decision}'; treating as code_dominant." ;;
    esac

    local extra_context
    extra_context=$(_bf_extra_context_for_decision "$decision")

    local max_attempts="${BUILD_FIX_MAX_ATTEMPTS:-3}"
    local require_progress="${BUILD_FIX_REQUIRE_PROGRESS:-true}"
    local effective_max="${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}}"
    local divisor="${BUILD_FIX_BASE_TURN_DIVISOR:-3}"
    local base_turns=$(( effective_max / (divisor > 0 ? divisor : 3) ))
    if (( base_turns < 8 )); then base_turns=8; fi

    local prev_count new_count prev_tail new_tail
    prev_count=$(_bf_count_errors "${BUILD_RAW_ERRORS_FILE}")
    prev_tail=$(_bf_get_error_tail "${BUILD_RAW_ERRORS_FILE}")

    local attempt=0
    local outcome="exhausted"
    local final_progress="n/a"
    local final_delta="n/a"

    while (( attempt < max_attempts )); do
        attempt=$(( attempt + 1 ))
        BUILD_FIX_ATTEMPTS="$attempt"

        local budget
        budget=$(_compute_build_fix_budget "$attempt" "$base_turns" \
            "${BUILD_FIX_TURN_BUDGET_USED}")
        if (( budget == 0 )); then
            log "Build-fix cumulative turn cap reached after ${BUILD_FIX_TURN_BUDGET_USED} turns; halting loop."
            attempt=$(( attempt - 1 ))
            BUILD_FIX_ATTEMPTS="$attempt"
            outcome="exhausted"
            break
        fi

        log "Build-fix attempt ${attempt}/${max_attempts} (budget=${budget} turns, used=${BUILD_FIX_TURN_BUDGET_USED})."
        _bf_invoke_build_fix "$decision" "$extra_context" "$raw_errors" "$budget"
        BUILD_FIX_TURN_BUDGET_USED=$(( BUILD_FIX_TURN_BUDGET_USED + budget ))

        local terminal_class
        terminal_class=$(_build_fix_terminal_class \
            "${LAST_AGENT_EXIT_CODE:-0}" "${LAST_AGENT_TURNS:-0}" "$budget")

        local gate_result="fail"
        if run_build_gate "post-coder-fix-${attempt}"; then
            gate_result="pass"
            new_count=$(_bf_count_errors "${BUILD_RAW_ERRORS_FILE}")
            final_delta="${prev_count}→${new_count}"
            _append_build_fix_report "$attempt" "$budget" "$terminal_class" \
                "$gate_result" "n/a" "$final_delta" "$decision"
            outcome="passed"
            break
        fi

        new_count=$(_bf_count_errors "${BUILD_RAW_ERRORS_FILE}")
        new_tail=$(_bf_get_error_tail "${BUILD_RAW_ERRORS_FILE}")
        local progress
        progress=$(_build_fix_progress_signal "$prev_count" "$new_count" \
            "$prev_tail" "$new_tail")
        final_progress="$progress"
        final_delta="${prev_count}→${new_count}"

        _append_build_fix_report "$attempt" "$budget" "$terminal_class" \
            "$gate_result" "$progress" "$final_delta" "$decision"

        # Re-read raw errors so subsequent attempts get the fresh stream;
        # the routing decision is fixed at loop entry per Watch For.
        raw_errors=$(_bf_read_raw_errors)

        if [[ "$require_progress" == "true" ]] && (( attempt >= 2 )); then
            if [[ "$progress" == "unchanged" ]] || [[ "$progress" == "worsened" ]]; then
                warn "Build-fix halted early: no measurable progress after attempt ${attempt}."
                BUILD_FIX_PROGRESS_GATE_FAILURES=$(( BUILD_FIX_PROGRESS_GATE_FAILURES + 1 ))
                outcome="no_progress"
                break
            fi
        fi

        prev_count="$new_count"
        prev_tail="$new_tail"
    done

    case "$outcome" in
        passed)
            _export_build_fix_stats "passed"
            return 0
            ;;
        no_progress)
            _export_build_fix_stats "no_progress"
            _build_fix_set_secondary_cause
            error "Build gate failed after ${attempt} attempt(s); progress stalled."
            write_pipeline_state \
                "coder" \
                "build_failure" \
                "$(_build_resume_flag coder)" \
                "$TASK" \
                "Build-fix loop halted after ${attempt} attempt(s) with no measurable progress. terminated_early_no_progress=true. Final progress=${final_progress}, delta=${final_delta}, classification=${decision}. See ${BUILD_FIX_REPORT_FILE} and ${BUILD_ERRORS_FILE}."
            error "State saved. Review ${BUILD_FIX_REPORT_FILE} and ${BUILD_ERRORS_FILE} then re-run."
            exit 1
            ;;
        *)
            _export_build_fix_stats "exhausted"
            _build_fix_set_secondary_cause
            error "Build gate failed after ${attempt} build-fix attempt(s) (max=${max_attempts})."
            write_pipeline_state \
                "coder" \
                "build_failure" \
                "$(_build_resume_flag coder)" \
                "$TASK" \
                "Build-fix loop exhausted ${attempt}/${max_attempts} attempt(s). Final progress=${final_progress}, delta=${final_delta}, classification=${decision}. See ${BUILD_FIX_REPORT_FILE} and ${BUILD_ERRORS_FILE}."
            error "State saved. Review ${BUILD_FIX_REPORT_FILE} and ${BUILD_ERRORS_FILE} then re-run."
            exit 1
            ;;
    esac
}
