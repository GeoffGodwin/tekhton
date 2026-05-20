#!/usr/bin/env bash
# =============================================================================
# stage_envelope.sh — m18 stage envelope emission helpers.
#
# Sourced by stages/*.sh (when present) and by tekhton.sh on demand. The
# emit_stage_envelope helper writes a tekhton.stage.result.v1 envelope to
# $TEKHTON_STAGE_RESULT_FILE — when set — by execing `tekhton stage emit`.
#
# When TEKHTON_STAGE_RESULT_FILE is unset (the legacy bash-orchestrator path)
# the helper is a no-op so the same stage scripts work whether driven by the
# Go runner (m18) or by the bash orchestrator (pre-m18).
#
# Why exec the binary instead of hand-rolling JSON in bash:
#   1. JSON escaping (newlines in exit-reason, unicode in filenames) is a
#      footgun bash gets wrong consistently.
#   2. Validation lives next to the proto definition in Go; bash callers
#      cannot drift.
#   3. The same code path produces stdout output for `tekhton stage emit`
#      callers that want the envelope without a file dance.
# =============================================================================

# Resolve the tekhton binary path. Honor TEKHTON_BIN, then look on PATH, then
# fall back to a wedge-audit-friendly placeholder that will exit non-zero if
# called — better than silently dropping envelopes.
_stage_envelope_tekhton_bin() {
    if [[ -n "${TEKHTON_BIN:-}" ]]; then
        printf '%s' "$TEKHTON_BIN"
        return 0
    fi
    if command -v tekhton &>/dev/null; then
        command -v tekhton
        return 0
    fi
    # Final fallback: assume sibling-of-tekhton.sh layout.
    if [[ -n "${TEKHTON_HOME:-}" ]] && [[ -x "$TEKHTON_HOME/bin/tekhton" ]]; then
        printf '%s' "$TEKHTON_HOME/bin/tekhton"
        return 0
    fi
    printf '%s' "tekhton"
}

# emit_stage_envelope STAGE VERDICT EXIT_REASON [AGENT_CALLS] [DURATION] [NEXT_ACTION] [FILES_TOUCHED]
# Writes a tekhton.stage.result.v1 envelope to $TEKHTON_STAGE_RESULT_FILE when
# the variable is set, otherwise no-ops. Safe to call multiple times — only
# the last call's envelope is preserved.
#
# All arguments after VERDICT are optional; pass empty strings for unused slots.
emit_stage_envelope() {
    local result_file="${TEKHTON_STAGE_RESULT_FILE:-}"
    [[ -z "$result_file" ]] && return 0

    local stage="$1"
    local verdict="$2"
    local exit_reason="${3:-}"
    local agent_calls="${4:-0}"
    local duration="${5:-0}"
    local next_action="${6:-}"
    local files_touched="${7:-}"
    local human_action="${TEKHTON_STAGE_HUMAN_ACTION:-false}"
    local error_msg="${TEKHTON_STAGE_ERROR:-}"

    local bin
    bin=$(_stage_envelope_tekhton_bin)

    # Build the argument list explicitly so empty fields are still sent
    # (Cobra defaults will fill them in).
    local -a args=(
        "stage" "emit"
        "--stage" "$stage"
        "--verdict" "$verdict"
        "--exit-reason" "$exit_reason"
        "--agent-calls" "$agent_calls"
        "--duration" "$duration"
        "--to-result-file"
    )
    if [[ -n "$next_action" ]]; then
        args+=("--next-action" "$next_action")
    fi
    if [[ -n "$files_touched" ]]; then
        args+=("--files-touched" "$files_touched")
    fi
    if [[ "$human_action" = "true" ]]; then
        args+=("--human-action")
    fi
    if [[ -n "$error_msg" ]]; then
        args+=("--error" "$error_msg")
    fi

    if ! "$bin" "${args[@]}" >/dev/null 2>&1; then
        # Best-effort fallback: write a minimal envelope directly so callers
        # don't crash when the binary is missing. _stage_envelope_json_fallback
        # JSON-escapes its arguments — printf %q is shell-escape and produces
        # malformed JSON.
        _stage_envelope_json_fallback "$stage" "$verdict" "$exit_reason" \
            "$agent_calls" "$duration" "$next_action" "$result_file"
    fi
}

# _stage_envelope_json_fallback STAGE VERDICT EXIT_REASON AGENT_CALLS DURATION NEXT_ACTION RESULT_FILE
# Writes a minimal stage.result.v1 envelope using bash-only JSON escaping.
# Used when the tekhton binary is unavailable. Escapes \, ", and control
# characters per RFC 8259.
_stage_envelope_json_fallback() {
    local stage="$1" verdict="$2" reason="$3"
    local calls="$4" duration="$5" next="$6" out="$7"
    local stage_e reason_e next_e
    stage_e=$(_stage_envelope_json_escape "$stage")
    reason_e=$(_stage_envelope_json_escape "$reason")
    next_e=$(_stage_envelope_json_escape "$next")
    {
        printf '{'
        printf '"proto":"tekhton.stage.result.v1",'
        printf '"stage":"%s",' "$stage_e"
        printf '"verdict":"%s",' "$verdict"
        printf '"exit_reason":"%s",' "$reason_e"
        printf '"agent_calls":%s,' "${calls:-0}"
        printf '"duration_sec":%s,' "${duration:-0}"
        printf '"human_action_required":false'
        if [[ -n "$next" ]]; then
            printf ',"next_action":"%s"' "$next_e"
        fi
        printf '}\n'
    } > "$out"
}

# _stage_envelope_json_escape <string>
# Escapes a string for JSON inclusion. Handles \, ", and control characters
# 0x00–0x1f. Newlines become \n; tabs become \t.
_stage_envelope_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

# stage_envelope_record_files_touched <git-status-since-epoch>
# Best-effort capture of files touched during a stage run. Stages that want a
# precise list can pass it directly to emit_stage_envelope; this helper is for
# the common "git status --porcelain after the stage" case.
stage_envelope_record_files_touched() {
    git status --porcelain 2>/dev/null \
        | awk '{print $2}' \
        | tr '\n' ',' \
        | sed 's/,$//'
}

# stage_envelope_wrap <stage>
# Replaces run_stage_<stage> with a wrapper that:
#   1. Records the start timestamp.
#   2. Calls the original implementation.
#   3. Maps its exit code to a verdict (0 → pass, otherwise → fail).
#   4. Emits a stage.result.v1 envelope via emit_stage_envelope.
#   5. Re-returns the original exit code.
#
# Stages that need richer verdicts (review's "rework", security's "block",
# tester's "fix") can set _STAGE_ENVELOPE_<NAME>_VERDICT or
# _STAGE_ENVELOPE_NEXT_ACTION before returning to override the default
# pass/fail mapping. The wrapper reads these single-shot variables and
# clears them after emit.
stage_envelope_wrap() {
    local stage="$1"
    if ! declare -f "run_stage_${stage}" &>/dev/null; then
        return 0
    fi
    local orig
    orig=$(declare -f "run_stage_${stage}")
    # Replace the function name: "run_stage_<x> ()" → "_orig_run_stage_<x> ()"
    eval "${orig/run_stage_${stage} /_orig_run_stage_${stage} }"
    # Define the wrapper.
    eval "
run_stage_${stage}() {
    local _se_start; _se_start=\$(date +%s 2>/dev/null || echo 0)
    local _se_ec=0
    _orig_run_stage_${stage} \"\$@\" || _se_ec=\$?
    local _se_dur=\$(( \$(date +%s 2>/dev/null || echo 0) - _se_start ))
    local _se_verdict_var=\"_STAGE_ENVELOPE_${stage^^}_VERDICT\"
    local _se_verdict=\"\${!_se_verdict_var:-}\"
    if [[ -z \"\$_se_verdict\" ]]; then
        if [[ \"\$_se_ec\" -eq 0 ]]; then _se_verdict=pass; else _se_verdict=fail; fi
    fi
    local _se_next=\"\${_STAGE_ENVELOPE_NEXT_ACTION:-}\"
    local _se_reason=\"\${_STAGE_ENVELOPE_EXIT_REASON:-exit=\$_se_ec}\"
    local _se_calls=\"\${_STAGE_ENVELOPE_AGENT_CALLS:-0}\"
    # Only fill in an envelope when the stage didn't write one itself.
    # Stages that hand-roll their envelope (e.g. with a sha256 exit_reason
    # for parity tests, or a richer verdict than pass/fail) populate
    # TEKHTON_STAGE_RESULT_FILE directly; overwriting their work would
    # silently destroy data the runner is about to consume.
    if declare -f emit_stage_envelope &>/dev/null \
       && { [[ -z \"\${TEKHTON_STAGE_RESULT_FILE:-}\" ]] || [[ ! -s \"\$TEKHTON_STAGE_RESULT_FILE\" ]]; }; then
        emit_stage_envelope \"${stage}\" \"\$_se_verdict\" \"\$_se_reason\" \"\$_se_calls\" \"\$_se_dur\" \"\$_se_next\"
    fi
    unset _STAGE_ENVELOPE_${stage^^}_VERDICT _STAGE_ENVELOPE_NEXT_ACTION _STAGE_ENVELOPE_EXIT_REASON _STAGE_ENVELOPE_AGENT_CALLS
    return \"\$_se_ec\"
}
"
}

# stage_envelope_install_all
# Wraps all known stage entry functions in the current process. Idempotent —
# safe to call multiple times.
stage_envelope_install_all() {
    local stage
    for stage in intake coder security review tester cleanup docs; do
        if declare -f "run_stage_${stage}" &>/dev/null \
            && ! declare -f "_orig_run_stage_${stage}" &>/dev/null; then
            stage_envelope_wrap "$stage"
        fi
    done
}
