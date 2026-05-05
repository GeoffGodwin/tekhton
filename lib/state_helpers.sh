#!/usr/bin/env bash
# =============================================================================
# state_helpers.sh — Writer + bash-fallback reader for lib/state.sh
#
# Sourced by lib/state.sh — do not run directly. Encapsulates everything
# state.sh used to do inline (heredoc + awk) and the bash-fallback path that
# kicks in when the `tekhton` Go binary is not on PATH (test sandboxes,
# fresh clones before `make build`).
#
# Provides:
#   _state_write_snapshot     — main writer (Go preferred, bash fallback)
#   _state_bash_read_field    — pure-bash JSON reader for first-class +
#                               extra fields (only used when Go binary absent)
# =============================================================================

# _state_write_snapshot stage reason resume_flag resume_task [extra_notes] [milestone]
# Maps the legacy 6-positional API to the JSON envelope. Includes auxiliary
# environment values (HUMAN_*, _ORCH_*, AGENT_ERROR_*) so resume handlers
# read the same fields the heredoc used to expose.
_state_write_snapshot() {
    local exit_stage="$1" exit_reason="$2" resume_flag="$3" resume_task="$4"
    local extra_notes="${5:-}" milestone_num="${6:-}"

    # Strip surrounding quotes — the pre-m03 heredoc tripped on them; preserve
    # the same defensive cleanup so callers don't have to.
    resume_task="${resume_task#\"}"; resume_task="${resume_task%\"}"
    resume_flag="${resume_flag//\"/}"

    local _state_dir; _state_dir="$(dirname "$PIPELINE_STATE_FILE")"
    if ! mkdir -p "$_state_dir" 2>/dev/null; then
        warn "Could not create state directory: $_state_dir"
        return 1
    fi

    local recovery=""
    if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]] && declare -f suggest_recovery &>/dev/null; then
        recovery=$(suggest_recovery "${AGENT_ERROR_CATEGORY}" "${AGENT_ERROR_SUBCATEGORY:-unknown}" 2>/dev/null || echo "Check run log.")
    fi

    local last_output=""
    if [[ -n "${AGENT_ERROR_CATEGORY:-}" ]]; then
        local last_file="${TEKHTON_SESSION_DIR:-/tmp}/agent_last_output.txt"
        if [[ -f "$last_file" ]]; then
            if command -v redact_sensitive &>/dev/null; then
                last_output=$(tail -10 "$last_file" 2>/dev/null | redact_sensitive 2>/dev/null || true)
            else
                last_output=$(tail -10 "$last_file" 2>/dev/null || true)
            fi
        else
            last_output="(no output captured)"
        fi
    fi

    local -a fields=(
        --field "exit_stage=${exit_stage}"
        --field "exit_reason=${exit_reason}"
        --field "resume_flag=${resume_flag}"
        --field "resume_task=${resume_task}"
        --field "notes=${extra_notes}"
        --field "milestone_id=${milestone_num:-}"
        --field "pipeline_order=${PIPELINE_ORDER:-standard}"
        --field "tester_mode=${TESTER_MODE:-verify_passing}"
        --field "human_mode=${HUMAN_MODE:-false}"
        --field "human_notes_tag=${HUMAN_NOTES_TAG:-}"
        --field "current_note_line=${CURRENT_NOTE_LINE:-}"
        --field "current_note_id=${CURRENT_NOTE_ID:-}"
        --field "human_single_note=${HUMAN_SINGLE_NOTE:-false}"
        --field "pipeline_attempt=${_ORCH_ATTEMPT:-0}"
        --field "agent_calls_total=${_ORCH_AGENT_CALLS:-0}"
        --field "cumulative_turns=${TOTAL_TURNS:-0}"
        --field "wall_clock_elapsed=${_ORCH_ELAPSED:-0}"
        --field "attempt_log=${_ORCH_ATTEMPT_LOG:-}"
        --field "agent_error_category=${AGENT_ERROR_CATEGORY:-}"
        --field "agent_error_subcategory=${AGENT_ERROR_SUBCATEGORY:-}"
        --field "agent_error_transient=${AGENT_ERROR_TRANSIENT:-}"
        --field "agent_error_recovery=${recovery}"
        --field "agent_error_last_output=${last_output}"
        --field "git_diff_stat=${GIT_DIFF_STAT:-}"
    )

    if command -v tekhton >/dev/null 2>&1; then
        tekhton state update --path "$PIPELINE_STATE_FILE" "${fields[@]}"
        return $?
    fi
    _state_bash_write_fields fields
}

# _state_bash_write_fields ARRAY_NAME
# Pure-bash JSON writer. Reads from a pre-built --field K=V array (passed by
# name to avoid duplicating the field list) and emits a JSON file matching
# what the Go writer would produce. Atomic via tmpfile + mv.
# shellcheck disable=SC2154  # pairs is set via eval below from caller's array
_state_bash_write_fields() {
    local arr_name="$1"
    local -a pairs=()
    eval "pairs=( \"\${${arr_name}[@]}\" )"
    local tmp; tmp="$(mktemp "${PIPELINE_STATE_FILE}.tmp.XXXXXX" 2>/dev/null \
        || mktemp /tmp/pipeline_state.XXXXXX)"

    {
        printf '{\n  "proto":"tekhton.state.v1"'
        printf ',\n  "updated_at":"%s"' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

        local -A scalars=(
            [exit_stage]=str [exit_reason]=str [resume_flag]=str
            [resume_task]=str [notes]=str [milestone_id]=str
            [pipeline_attempt]=int [agent_calls_total]=int
        )
        local -A extras=()
        local key val type i
        for ((i=0; i<${#pairs[@]}; i+=2)); do
            [[ "${pairs[i]}" = "--field" ]] || continue
            key="${pairs[i+1]%%=*}"
            val="${pairs[i+1]#*=}"
            if [[ -n "${scalars[$key]:-}" ]]; then
                type="${scalars[$key]}"
                if [[ "$type" = "int" ]]; then
                    # Zero omitted — matches `omitempty` on the corresponding
                    # first-class int fields in internal/proto/state_v1.go;
                    # keeps the bash-fallback writer byte-equivalent to Go.
                    if ! [[ "$val" =~ ^[0-9]+$ ]] || [[ "$val" = "0" ]]; then
                        continue
                    fi
                    printf ',\n  "%s":%s' "$key" "$val"
                elif [[ -n "$val" ]]; then
                    printf ',\n  "%s":"%s"' "$key" "$(_json_escape "$val")"
                fi
            else
                [[ -n "$val" ]] && extras[$key]="$val"
            fi
        done

        if [[ "${#extras[@]}" -gt 0 ]]; then
            printf ',\n  "extra":{'
            local first=1
            for key in "${!extras[@]}"; do
                if [[ "$first" -eq 1 ]]; then first=0
                else                          printf ','
                fi
                printf '\n    "%s":"%s"' "$key" "$(_json_escape "${extras[$key]}")"
            done
            printf '\n  }'
        fi

        printf '\n}\n'
    } > "$tmp"

    mv -f "$tmp" "$PIPELINE_STATE_FILE"
}

# _state_bash_read_field path field — best-effort JSON field reader.
# Handles both first-class fields ("exit_stage":"…") and extra members
# ("extra":{ … "current_note_id":"…" …}). Also recognizes legacy markdown
# files (heading-delimited) so a fresh shim can read a pre-m03 state file.
#
# Limitation: the awk scanner stops at the first inner double-quote, so a
# value containing escaped quotes (e.g. resume_task='key="val"') will be
# truncated. Acceptable in the bash-fallback path — the Go reader is
# authoritative; this branch only fires before `make build`.
_state_bash_read_field() {
    local path="$1" field="$2"
    [[ -f "$path" ]] || return 0
    local first_char
    first_char=$(head -c 1 "$path" 2>/dev/null || true)

    if [[ "$first_char" = "{" ]]; then
        # JSON: try first-class then extra. Use perl-free awk that stops at
        # first match per file. Covers both string and integer values.
        local val
        val=$(awk -v key="$field" '
            BEGIN { found=0 }
            {
                pat="\"" key "\":\""
                if ((idx=index($0, pat))>0) {
                    rest=substr($0, idx+length(pat))
                    end=index(rest, "\"")
                    if (end>0) { print substr(rest, 1, end-1); exit }
                }
                ipat="\"" key "\":"
                if ((idx=index($0, ipat))>0) {
                    rest=substr($0, idx+length(ipat))
                    val=""
                    for (i=1; i<=length(rest); i++) {
                        c=substr(rest, i, 1)
                        if (c~/[0-9-]/) { val=val c }
                        else if (val!="") { print val; exit }
                        else if (c!=" ") break
                    }
                    if (val!="") { print val; exit }
                }
            }
        ' "$path")
        printf '%s' "$val"
        return 0
    fi

    # Legacy markdown: map field → "## Heading" then read the next line.
    local heading
    case "$field" in
        exit_stage)         heading="## Exit Stage" ;;
        exit_reason)        heading="## Exit Reason" ;;
        resume_flag)        heading="## Resume Command" ;;
        resume_task)        heading="## Task" ;;
        notes)              heading="## Notes" ;;
        milestone_id)       heading="## Milestone" ;;
        human_mode)         heading="## Human Mode" ;;
        human_notes_tag)    heading="## Human Notes Tag" ;;
        current_note_line)  heading="## Current Note Line" ;;
        current_note_id)    heading="## Current Note ID" ;;
        human_single_note)  heading="## Human Single Note" ;;
        pipeline_attempt)
            awk '/^Pipeline attempt:/{print $NF; exit}' "$path" 2>/dev/null
            return 0 ;;
        agent_calls_total)
            awk '/^Cumulative agent calls:/{print $NF; exit}' "$path" 2>/dev/null
            return 0 ;;
        agent_error_category)
            awk '/^Category:/{sub(/^Category:[[:space:]]*/, ""); print; exit}' "$path" 2>/dev/null
            return 0 ;;
        agent_error_subcategory)
            awk '/^Subcategory:/{sub(/^Subcategory:[[:space:]]*/, ""); print; exit}' "$path" 2>/dev/null
            return 0 ;;
        agent_error_transient)
            awk '/^Transient:/{sub(/^Transient:[[:space:]]*/, ""); print; exit}' "$path" 2>/dev/null
            return 0 ;;
        *) return 0 ;;
    esac
    awk -v h="$heading" '$0==h{getline; print; exit}' "$path" 2>/dev/null
}
