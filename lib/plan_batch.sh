#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_batch.sh — Batch planning call helper and template parser
#
# Provides _call_planning_batch() for invoking the planning agent via the
# tekhton supervise seam (provider-aware as of m19), and
# _extract_template_sections() for parsing design doc templates.
#
# Extracted from plan.sh for size management. Sourced by plan.sh — do not
# run directly.
# =============================================================================

# Ensure _shim_resolve_binary and _shim_write_request are available.
# In the normal pipeline, agent_shim.sh is sourced by agent.sh before plan_batch.sh.
# For standalone contexts (--plan mode, tests sourcing plan.sh directly), source lazily.
if ! declare -f _shim_resolve_binary >/dev/null 2>&1; then
    # shellcheck source=agent_shim.sh disable=SC1091
    source "${TEKHTON_HOME}/lib/agent_shim.sh"
fi

# _call_planning_batch — Invoke the planning agent and print response to stdout.
#
# Routes through `tekhton supervise` (provider-aware) using agent.request.v1
# envelopes built by _shim_write_request from lib/agent_shim.sh. Callers that
# set PROVIDER=codex or PROVIDER=qwen-local will route through those providers
# instead of the Claude CLI, honoring PROVIDER_<LABEL> overrides.
#
# Public contract (unchanged from the pre-m20 batch path):
#   stdout  — response text (StdoutTail from the response envelope), tee'd
#             to log_file. Callers that use the _disk_rescued pattern detect
#             when the agent wrote files via the Write tool and use those
#             instead of the stdout capture.
#   return  — agent exit code (from response envelope exit_code field)
#   /dev/tty — progress spinner while the agent runs (suppressed by
#              TEKHTON_TEST_MODE and _TUI_ACTIVE)
#
# Usage:
#   output=$(_call_planning_batch model max_turns prompt log_file [label])
#   rc=$?   # agent exit code
#
# label (5th arg, optional) — agent.request.v1 label used for PROVIDER_<LABEL>
# routing. Defaults to "planning". Use "plan_interview", "plan_generate", or
# "replan" to enable per-stage provider overrides.
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"; : "$max_turns"
    local prompt="$3"
    local log_file="$4"
    local label="${5:-planning}"

    # Resolve the tekhton binary. Without it the supervise seam cannot run.
    local _bin
    if ! _bin=$(_shim_resolve_binary); then
        warn "[${label}] tekhton binary not found on PATH or in TEKHTON_HOME/bin — planning batch call cannot run."
        return 127
    fi

    # Start an in-place spinner on /dev/tty (visible even inside $() capture).
    # Animates a single line with elapsed time so the user knows it's working
    # without flooding the terminal with output over 20+ minute runs.
    # Suppressed when the TUI sidecar is active — the sidecar owns /dev/tty
    # and direct writes bleed through its alternate-screen buffer.
    local spinner_pid=""
    if [[ -z "${TEKHTON_TEST_MODE:-}" ]] \
        && [[ "${_TUI_ACTIVE:-false}" != "true" ]] \
        && [[ -e /dev/tty ]]; then
        (
            local chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
            local start_ts
            start_ts=$(date +%s)
            local i=0
            while true; do
                local now
                now=$(date +%s)
                local elapsed=$(( now - start_ts ))
                local mins=$(( elapsed / 60 ))
                local secs=$(( elapsed % 60 ))
                printf '\r\033[0;36m[tekhton]\033[0m %s Generating... %dm%02ds ' \
                    "${chars:i%${#chars}:1}" "$mins" "$secs" > /dev/tty
                i=$(( i + 1 ))
                sleep 0.2
            done
        ) &
        spinner_pid=$!
    fi

    # Write prompt to a temp file in the session dir.
    local _sd="${TEKHTON_SESSION_DIR:-/tmp}"
    mkdir -p "$_sd"
    local _pf="${_sd}/tekhton_plan_prompt_$$.txt"
    local _rf="${_sd}/tekhton_plan_request_$$.json"
    local _zf="${_sd}/tekhton_plan_response_$$.json"
    printf '%s' "$prompt" > "$_pf"

    # Save existing traps so we can restore them after cleanup instead of
    # clearing globally with `trap - INT TERM` (which could mask signals
    # received during spinner teardown).
    local _prev_trap_int _prev_trap_term
    _prev_trap_int=$(trap -p INT 2>/dev/null || true)
    _prev_trap_term=$(trap -p TERM 2>/dev/null || true)

    trap 'rm -f "$_pf" "$_rf" "$_zf"; [[ -n "${spinner_pid:-}" ]] && kill "$spinner_pid" 2>/dev/null; exit 130' INT TERM

    # Build and emit the agent.request.v1 envelope.
    # Pass AGENT_TOOLS_CODER so the agent can use the Write tool to produce
    # output files when running under a non-text-output provider (codex/qwen).
    _shim_write_request "$_rf" "${RUN_ID:-}" "$label" "$model" \
        "$max_turns" "$_pf" "${PROJECT_DIR:-$PWD}" \
        "${AGENT_TIMEOUT:-7200}" "${AGENT_ACTIVITY_TIMEOUT:-600}" \
        "${AGENT_TOOLS_CODER:-Read Write Edit Glob Grep Bash}"

    # Run the supervisor. Response envelope goes to $_zf; supervisor's own
    # stderr (not the agent's stderr) goes to the log.
    local _exec_rc=0
    "$_bin" supervise --request-file "$_rf" > "$_zf" 2>>"$log_file" || _exec_rc=$?

    # Extract the agent exit code from the response envelope.
    local _resp_rc
    _resp_rc=$(_shim_field "$_zf" exit_code)
    if [[ "$_resp_rc" =~ ^-?[0-9]+$ ]]; then
        _exec_rc="$_resp_rc"
    fi

    # Emit StdoutTail to stdout and log. In stream-json mode the tail contains
    # the last 50 JSON event lines (not the raw document text). Callers that
    # use the _disk_rescued pattern detect this (content doesn't start with '#')
    # and fall back to the file the agent wrote via the Write tool.
    set +o pipefail
    _plan_batch_emit_tail "$_zf" | tee -a "$log_file"
    set -o pipefail

    rm -f "$_pf" "$_rf" "$_zf"

    # Restore previous signal handlers (not `trap - INT TERM` which clears globally)
    if [[ -n "$_prev_trap_int" ]]; then
        eval "$_prev_trap_int"
    else
        trap - INT
    fi
    if [[ -n "$_prev_trap_term" ]]; then
        eval "$_prev_trap_term"
    else
        trap - TERM
    fi

    # Stop spinner and clear the line
    if [[ -n "$spinner_pid" ]]; then
        kill "$spinner_pid" 2>/dev/null || true
        wait "$spinner_pid" 2>/dev/null || true
        printf '\r\033[K' > /dev/tty 2>/dev/null || true
    fi

    return "$_exec_rc"
}

# _plan_batch_emit_tail — Extract and print lines from the stdout_tail array
# in an agent.response.v1 JSON file produced by `tekhton supervise`.
# Pure awk — no jq dependency. Handles MarshalIndented format (2-space indent,
# one JSON-string element per line). Prints nothing when the file is absent or
# stdout_tail is empty.
_plan_batch_emit_tail() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    awk '
        /^[[:space:]]*"stdout_tail"[[:space:]]*:[[:space:]]*\[[[:space:]]*\]/ { next }
        /^[[:space:]]*"stdout_tail"[[:space:]]*:[[:space:]]*\[/ { in_tail=1; next }
        in_tail && /^[[:space:]]*\][[:space:]]*,?[[:space:]]*$/ { in_tail=0; next }
        in_tail {
            line=$0
            sub(/^[[:space:]]*"/, "", line)
            sub(/"[[:space:]]*,?[[:space:]]*$/, "", line)
            # Stash escaped backslashes as a placeholder so later \n / \t / \"
            # rules cannot mis-match a sequence whose backslash was already a
            # literal escape (e.g. JSON "\\n" must decode to literal "\n",
            # not a newline).
            gsub(/\\\\/, "\001", line)
            gsub(/\\n/, "\n", line)
            gsub(/\\t/, "\t", line)
            gsub(/\\"/, "\"", line)
            gsub(/\001/, "\\", line)
            print line
        }
    ' "$f"
}

# _trim_document_preamble — Strip leading non-document lines before the first
# top-level markdown heading (`^# `).
#
# Claude sometimes emits a preamble sentence ("I have enough context...",
# "Here is the generated document...") before the actual markdown document.
# This function removes those lines so the on-disk file starts cleanly.
#
# Reads content from stdin, writes trimmed content to stdout.
# If no `^# ` heading is found, returns the input unchanged.
# If the first line already starts with `# `, returns unchanged (fast path).
_trim_document_preamble() {
    local content
    content=$(cat)

    # Fast path: already starts with a heading
    local first_line
    first_line=$(printf '%s\n' "$content" | head -1)
    if [[ "$first_line" == "#"* ]]; then
        printf '%s\n' "$content"
        return 0
    fi

    # Find the first line that starts with "# " (top-level heading)
    local heading_line
    heading_line=$(printf '%s\n' "$content" | grep -n '^# ' | head -1 | cut -d: -f1)

    if [[ -z "$heading_line" ]]; then
        # No heading found — return unchanged
        printf '%s\n' "$content"
        return 0
    fi

    # Strip everything before the heading
    printf '%s\n' "$content" | tail -n +"$heading_line"
}

# _extract_template_sections — Parse a template file and print section data.
#
# Output format (one line per section):   NAME|REQUIRED|GUIDANCE|PHASE
#   NAME     — section heading (without "## " prefix)
#   REQUIRED — "true" or "false"
#   GUIDANCE — single-line concatenation of <!-- ... --> guidance comments
#   PHASE    — integer (1, 2, or 3) from <!-- PHASE:N --> marker; default 1
#
# Usage:
#   while IFS='|' read -r name required guidance phase; do
#       ...
#   done < <(_extract_template_sections "$template_file")
_extract_template_sections() {
    local template="$1"
    awk '
    BEGIN { section = ""; required = "false"; guidance = ""; phase = "1" }
    /^## / {
        if (section != "") {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", guidance)
            print section "|" required "|" guidance "|" phase
        }
        section = $0
        sub(/^## /, "", section)
        required = "false"
        guidance = ""
        phase = "1"
        if (section ~ /<!-- REQUIRED -->/) {
            required = "true"
            gsub(/[[:space:]]*<!-- REQUIRED -->[[:space:]]*/, "", section)
        }
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", section)
        next
    }
    section != "" && /^<!-- REQUIRED -->/ { required = "true"; next }
    section != "" && /^<!-- PHASE:[0-9]+ -->/ {
        line = $0
        gsub(/^<!-- PHASE:/, "", line)
        gsub(/[[:space:]]*-->.*/, "", line)
        phase = line
        next
    }
    section != "" && /^<!--/ {
        line = $0
        gsub(/^<!--[[:space:]]*/, "", line)
        gsub(/[[:space:]]*-->$/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (length(line) > 0 && line != "REQUIRED") {
            guidance = (guidance == "") ? line : guidance " " line
        }
        next
    }
    END {
        if (section != "") {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", guidance)
            print section "|" required "|" guidance "|" phase
        }
    }
    ' "$template"
}
