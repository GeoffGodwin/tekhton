#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# plan_batch.sh — Batch planning call helper and template parser
#
# Provides _call_planning_batch() for invoking claude in batch mode during
# planning, and _extract_template_sections() for parsing design doc templates.
#
# Extracted from plan.sh for size management. Sourced by plan.sh — do not
# run directly.
# =============================================================================

# _call_planning_batch — Call claude in batch mode and print text content to stdout.
#
# Uses --output-format text so the response is plain text with no JSON parsing.
# Uses --dangerously-skip-permissions to prevent Claude's permission system from
# intercepting the prompt and returning a permission request message instead of
# content. The caller (shell) is responsible for writing any files — Claude only
# generates text output here.
#
# The response is tee'd to the log file and also passed through to stdout so
# the caller can capture it with output=$(_call_planning_batch ...).
#
# Shows a progress indicator on /dev/tty while claude is running so the user
# knows the operation hasn't stalled. Skipped in TEKHTON_TEST_MODE.
#
# Usage:
#   output=$(_call_planning_batch model max_turns prompt log_file)
#   rc=$?   # claude's exit code
#
# Prints the full text response to stdout. Returns claude's exit code.
_call_planning_batch() {
    local model="$1"
    local max_turns="$2"
    local prompt="$3"
    local log_file="$4"

    # Start an in-place spinner on /dev/tty (visible even inside $() capture).
    # Animates a single line with elapsed time so the user knows it's working
    # without flooding the terminal with output over 20+ minute runs.
    local spinner_pid=""
    if [[ -z "${TEKHTON_TEST_MODE:-}" ]] && [[ -e /dev/tty ]]; then
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

    # Write prompt to temp file to avoid MAX_ARG_STRLEN (128KB) limit on Linux.
    # The -p flag (print mode) reads the prompt from stdin when no positional
    # argument is provided.
    local _prompt_file="${TMPDIR:-/tmp}/tekhton_prompt_$$.txt"
    printf '%s' "$prompt" > "$_prompt_file"

    # Save existing traps so we can restore them after cleanup instead of
    # clearing globally with `trap - INT TERM` (which could mask signals
    # received during spinner teardown).
    local _prev_trap_int _prev_trap_term
    _prev_trap_int=$(trap -p INT 2>/dev/null || true)
    _prev_trap_term=$(trap -p TERM 2>/dev/null || true)

    # Clean up temp file on interrupt (matches the abort trap on the FIFO path)
    trap 'rm -f "$_prompt_file"; [[ -n "${spinner_pid:-}" ]] && kill "$spinner_pid" 2>/dev/null; exit 130' INT TERM

    set +o pipefail
    claude \
        --model "$model" \
        --max-turns "$max_turns" \
        --output-format text \
        --dangerously-skip-permissions \
        -p \
        < "$_prompt_file" \
        2>&1 | tee -a "$log_file"
    local -a _pst=("${PIPESTATUS[@]}")
    set -o pipefail

    rm -f "$_prompt_file"

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

    return "${_pst[0]}"
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
