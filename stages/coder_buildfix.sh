#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
# =============================================================================
# stages/coder_buildfix.sh — Confidence-based build-fix routing (M127)
#
# Sourced by stages/coder.sh — do not run directly.
#
# Replaces the legacy binary has_only_noncode_errors() bypass with a four-token
# routing decision (code_dominant / noncode_dominant / mixed_uncertain /
# unknown_only) emitted by lib/error_patterns_classify.sh. Token policy:
#
#   noncode_dominant  → skip build-fix, route to human action, exit
#   code_dominant     → run build-fix coder with code-filtered errors
#   mixed_uncertain   → emit BUILD_ROUTING_DIAGNOSIS.md, then run build-fix with
#                       code-filtered errors plus a non-code context block
#   unknown_only      → run bounded build-fix with low-confidence guidance,
#                       preserving pre-M127 fallback semantics
#
# Provides:
#   _run_buildfix_routing — orchestrator called from run_stage_coder
#   _bf_emit_routing_diagnosis — writes BUILD_ROUTING_DIAGNOSIS.md
# =============================================================================

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

# _bf_emit_routing_diagnosis RAW_ERRORS — write BUILD_ROUTING_DIAGNOSIS.md
# with category counts and the top diagnoses for the mixed_uncertain path.
# Schema kept simple (header + counts + top three) so downstream parsers
# (notes pipeline, watchtower) stay trivial.
_bf_emit_routing_diagnosis() {
    local raw="$1"
    local stats
    stats=$(classify_build_errors_with_stats "$raw" 2>/dev/null) || stats=""

    local total_matched=0 total_lines=0 unmatched_lines=0
    if [[ -n "$stats" ]]; then
        IFS='|' read -r _c _s _r _d _mc total_matched total_lines unmatched_lines \
            <<< "$(printf '%s\n' "$stats" | head -1)"
    fi

    {
        echo "# Build Routing Diagnosis — $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "## Routing Decision"
        echo "mixed_uncertain — both code and non-code signals present."
        echo
        echo "## Line Stats"
        echo "- considered: ${total_lines}"
        echo "- matched: ${total_matched}"
        echo "- unmatched: ${unmatched_lines}"
        echo
        echo "## Top Diagnoses"
        if [[ -n "$stats" ]]; then
            local rec cat safety diag count
            local i=0
            while IFS= read -r rec; do
                [[ -z "$rec" ]] && continue
                IFS='|' read -r cat safety _remed diag count _tm _tl _ul <<< "$rec"
                echo "- ${cat} (${safety}) ×${count}: ${diag}"
                i=$((i + 1))
                [[ $i -ge 3 ]] && break
            done <<< "$stats"
        else
            echo "- (no recognized signatures)"
        fi
    } > "${BUILD_ROUTING_DIAGNOSIS_FILE}"
}

# _bf_invoke_build_fix CONTEXT_LABEL EXTRA_CONTEXT — render build_fix prompt
# and invoke the coder agent. EXTRA_CONTEXT is appended to BUILD_ERRORS_CONTENT
# so per-route guidance (mixed-uncertain non-code summary, unknown-only
# low-confidence note) is visible to the agent.
_bf_invoke_build_fix() {
    local label="$1"
    local extra_context="${2:-}"
    local raw="$3"

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

    local _bf_base="${EFFECTIVE_CODER_MAX_TURNS:-$CODER_MAX_TURNS}"
    run_agent \
        "Coder (build fix${label:+ — $label})" \
        "$CLAUDE_CODER_MODEL" \
        "$((_bf_base / 3))" \
        "$prompt" \
        "$LOG_FILE" \
        "$AGENT_TOOLS_BUILD_FIX"
    log "Build fix coder finished."
}

# _run_buildfix_routing — orchestrator. Returns 0 on success, exits 1 on
# terminal failure with state saved. Mutates pipeline state, runs sub-agents.
_run_buildfix_routing() {
    local _raw_errors
    _raw_errors=$(_bf_read_raw_errors)

    local _decision="code_dominant"
    if command -v classify_routing_decision &>/dev/null; then
        _decision=$(classify_routing_decision "$_raw_errors")
        # The function's own export is bound to the command-substitution
        # subshell. Re-export here so the value reaches downstream M128/M130
        # consumers running later in the parent shell.
        export LAST_BUILD_CLASSIFICATION="$_decision"
    fi
    log "Build-fix routing decision: ${_decision}"

    case "$_decision" in
        noncode_dominant)
            warn "Build errors classified as ${_decision}: skipping build-fix agent."
            warn "These errors require environment remediation, not code changes."
            if command -v append_human_action &>/dev/null; then
                append_human_action "build_gate" \
                    "Non-code build errors detected (routing=${_decision}). See ${BUILD_ERRORS_FILE} for details."
            fi
            write_pipeline_state \
                "coder" \
                "env_failure" \
                "$(_build_resume_flag coder)" \
                "$TASK" \
                "Build failed with environment errors (not code bugs). See ${BUILD_ERRORS_FILE}."
            error "State saved. Fix environment issues in ${BUILD_ERRORS_FILE} then re-run."
            exit 1
            ;;
        mixed_uncertain)
            warn "Build errors classified as ${_decision}: writing diagnosis and invoking build-fix coder with mixed-context guidance."
            _bf_emit_routing_diagnosis "$_raw_errors"
            local _mu_extra
            _mu_extra="## Routing Context (mixed_uncertain)"$'\n'"Both code and non-code error signals were detected in this run. See ${BUILD_ROUTING_DIAGNOSIS_FILE} for category counts and top diagnoses. Fix code errors first; if the build still fails, the remaining issues may be environmental and should be flagged for human action rather than retried."
            _bf_invoke_build_fix "mixed" "$_mu_extra" "$_raw_errors"
            ;;
        unknown_only)
            warn "Build errors classified as ${_decision}: no recognized signatures."
            warn "Running bounded build-fix; manual triage may still be required."
            local _uo_extra
            _uo_extra="## Routing Context (unknown_only)"$'\n'"No recognized error signatures matched the build output. This is the bounded fallback path: attempt one fix pass, then surface for human triage if it does not converge."
            _bf_invoke_build_fix "unknown" "$_uo_extra" "$_raw_errors"
            ;;
        code_dominant|*)
            warn "Invoking coder to fix build errors (1 retry allowed)..."
            _bf_invoke_build_fix "" "" "$_raw_errors"
            ;;
    esac

    if ! run_build_gate "post-coder-fix"; then
        error "Build gate failed again after fix attempt."
        write_pipeline_state \
            "coder" \
            "build_failure" \
            "$(_build_resume_flag coder)" \
            "$TASK" \
            "Build errors remain after auto-fix attempt. See ${BUILD_ERRORS_FILE}."
        error "State saved. Review ${BUILD_ERRORS_FILE} manually then re-run."
        exit 1
    fi

    return 0
}
