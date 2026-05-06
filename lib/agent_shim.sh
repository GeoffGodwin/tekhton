#!/usr/bin/env bash
# =============================================================================
# agent_shim.sh — V4 supervisor-shim helpers for lib/agent.sh.
#
# Sourced by lib/agent.sh — do not run directly. m10 deleted the bash
# supervisor (agent_monitor*.sh, agent_retry*.sh) and flipped lib/agent.sh
# to call `tekhton supervise`. This file holds the pure helpers the shim
# uses to (a) build the agent.request.v1 envelope without jq, (b) parse
# the agent.response.v1 envelope without python, (c) initialize the V3
# globals + tool-profile exports the rest of the bash tree still depends on.
#
# Expects: _json_escape from common.sh, log/warn from common.sh.
# =============================================================================
set -euo pipefail

# --- V3 contract globals -----------------------------------------------------
# These survive the cutover because lib/orchestrate.sh and friends still read
# them; Phase 4's orchestrate port deletes them. Kept as bare assignments so
# tests that source agent.sh see deterministic defaults. shellcheck SC2034
# disables: every name is read by an external consumer (orchestrate.sh,
# metrics.sh, finalize_summary_collectors.sh, milestone_split_nullrun.sh, …).

# shellcheck disable=SC2034
LAST_AGENT_TURNS=0
# shellcheck disable=SC2034
LAST_AGENT_EXIT_CODE=0
# shellcheck disable=SC2034
LAST_AGENT_ELAPSED=0
# shellcheck disable=SC2034
LAST_AGENT_NULL_RUN=false
# shellcheck disable=SC2034
LAST_AGENT_RETRY_COUNT=0
# shellcheck disable=SC2034
TOTAL_AGENT_INVOCATIONS=0
# shellcheck disable=SC2034
AGENT_ERROR_CATEGORY=""
# shellcheck disable=SC2034
AGENT_ERROR_SUBCATEGORY=""
# shellcheck disable=SC2034
AGENT_ERROR_TRANSIENT=""
# shellcheck disable=SC2034
AGENT_ERROR_MESSAGE=""
# shellcheck disable=SC2034
_RWR_EXIT=0
# shellcheck disable=SC2034
_RWR_TURNS=0
# shellcheck disable=SC2034
_RWR_WAS_ACTIVITY_TIMEOUT=false

: "${TOTAL_TURNS:=0}"
: "${TOTAL_TIME:=0}"
: "${STAGE_SUMMARY:=}"

# --- Tool profiles (--allowedTools per role) ---------------------------------
# Preserved verbatim from V3 — callers pass these through as the 6th arg to
# run_agent. Stays here rather than agent.sh so the shim itself can stay tiny.

export AGENT_TOOLS_SCOUT="Read Glob Grep Bash(find:*) Bash(head:*) Bash(wc:*) Bash(cat:*) Bash(ls:*) Bash(tail:*) Bash(file:*) Write"
export AGENT_TOOLS_CODER="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_JR_CODER="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_REVIEWER="Read Glob Grep Write"
export AGENT_TOOLS_TESTER="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_ARCHITECT="Read Glob Grep Write"
export AGENT_TOOLS_BUILD_FIX="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_SEED="Read Write Edit Glob Grep Bash"
export AGENT_TOOLS_CLEANUP="Read Write Edit Glob Grep Bash"
export AGENT_DISALLOWED_TOOLS="WebFetch WebSearch Bash(git push:*) Bash(git remote:*) Bash(rm -rf /:*) Bash(rm -rf ~:*) Bash(rm -rf .:*) Bash(rm -rf ..:*) Bash(curl:*) Bash(wget:*) Bash(ssh:*) Bash(scp:*) Bash(nc:*) Bash(ncat:*)"

# --- Resolution -------------------------------------------------------------

# _shim_resolve_binary — locate the tekhton binary. $TEKHTON_BIN wins; then
# $PATH; then the make-build artifact under TEKHTON_HOME/bin. Prints the path
# on success, returns 1 on failure. Callers warn + fall through to a
# soft-error AgentResultV1 rather than abort the pipeline.
_shim_resolve_binary() {
    if [[ -n "${TEKHTON_BIN:-}" ]] && [[ -x "$TEKHTON_BIN" ]]; then
        printf '%s\n' "$TEKHTON_BIN"; return 0
    fi
    if command -v tekhton >/dev/null 2>&1; then
        command -v tekhton; return 0
    fi
    if [[ -x "${TEKHTON_HOME:-}/bin/tekhton" ]]; then
        printf '%s\n' "${TEKHTON_HOME}/bin/tekhton"; return 0
    fi
    return 1
}

# --- Envelope I/O -----------------------------------------------------------

# _shim_write_request OUT_PATH RUN_ID LABEL MODEL MAX_TURNS PROMPT_FILE WORKING_DIR TIMEOUT ACTIVITY_TIMEOUT
# Emits a tekhton.agent.request.v1 envelope. Strings are escaped via
# _json_escape; ints are printed bare. No jq dependency.
_shim_write_request() {
    local out="$1" run_id="$2" label="$3" model="$4"
    local max_turns="$5" prompt_file="$6" working_dir="$7"
    local timeout_secs="$8" activity_timeout_secs="$9"
    {
        printf '{"proto":"tekhton.agent.request.v1"'
        printf ',"run_id":"%s"' "$(_json_escape "$run_id")"
        printf ',"label":"%s"' "$(_json_escape "$label")"
        printf ',"model":"%s"' "$(_json_escape "$model")"
        printf ',"max_turns":%d' "$max_turns"
        printf ',"prompt_file":"%s"' "$(_json_escape "$prompt_file")"
        printf ',"working_dir":"%s"' "$(_json_escape "$working_dir")"
        printf ',"timeout_secs":%d' "$timeout_secs"
        printf ',"activity_timeout_secs":%d' "$activity_timeout_secs"
        printf '}\n'
    } > "$out"
}

# _shim_apply_response RESPONSE_FILE EXEC_RC — parse the agent.response.v1
# envelope and set the V3 contract globals (LAST_AGENT_*, _RWR_*,
# AGENT_ERROR_*) plus null-run classification. Pulled out so run_agent stays
# under the lib/agent.sh 80-line ceiling. _RWR_WAS_ACTIVITY_TIMEOUT is
# expressly set per call (not just for activity_timeout) so a happy-path run
# clears any stale value the caller's locals might still hold.
_shim_apply_response() {
    local f="$1" exec_rc="$2"
    local _ec _tu _oc _msg _cat _sub _tr
    _ec=$(_shim_field "$f" exit_code)
    _tu=$(_shim_field "$f" turns_used)
    _oc=$(_shim_field "$f" outcome)
    _msg=$(_shim_field "$f" error_message)
    _cat=$(_shim_field "$f" error_category)
    _sub=$(_shim_field "$f" error_subcategory)
    _tr=$(_shim_field "$f" error_transient)
    [[ "$_ec" =~ ^-?[0-9]+$ ]] || _ec="$exec_rc"
    [[ "$_tu" =~ ^[0-9]+$ ]] || _tu=0
    # shellcheck disable=SC2034  # consumed by callers
    _RWR_EXIT="$_ec"; _RWR_TURNS="$_tu"
    if [[ "$_oc" = "activity_timeout" ]]; then
        # shellcheck disable=SC2034
        _RWR_WAS_ACTIVITY_TIMEOUT=true
    else
        # shellcheck disable=SC2034
        _RWR_WAS_ACTIVITY_TIMEOUT=false
    fi
    # shellcheck disable=SC2034  # consumed by run_agent + downstream stages
    AGENT_ERROR_CATEGORY="$_cat"
    # shellcheck disable=SC2034
    AGENT_ERROR_SUBCATEGORY="$_sub"
    # shellcheck disable=SC2034
    AGENT_ERROR_TRANSIENT="$_tr"
    # shellcheck disable=SC2034
    AGENT_ERROR_MESSAGE="$_msg"
    export LAST_AGENT_TURNS="$_tu" LAST_AGENT_EXIT_CODE="$_ec"
    # shellcheck disable=SC2034
    LAST_AGENT_NULL_RUN=false
    local _thr="${AGENT_NULL_RUN_THRESHOLD:-2}"
    if [[ "$_ec" -ne 0 ]] && [[ "$_tu" -le "$_thr" ]]; then
        # shellcheck disable=SC2034
        LAST_AGENT_NULL_RUN=true
    elif [[ "$_tu" -eq 0 ]]; then
        # shellcheck disable=SC2034
        LAST_AGENT_NULL_RUN=true
    fi
}

# _shim_field RESPONSE_FILE FIELD — extract a top-level scalar field from the
# agent.response.v1 JSON. Handles both "field":"value" (string) and
# "field":number forms. Empty/absent → empty string. Pure bash + awk —
# tolerant of cmd/tekhton/supervise.go's pretty-printed indented form.
_shim_field() {
    local f="$1" key="$2"
    [[ -f "$f" ]] || return 0
    # Strings: "key": "..." (quoted). Capture the contents up to the next
    # unescaped quote, with very-light unescape for \" and \\.
    local val
    val=$(awk -v k="$key" '
        BEGIN { pat="\"" k "\":" }
        {
            idx=index($0, pat)
            if (idx==0) next
            rest=substr($0, idx+length(pat))
            sub(/^[ \t]+/, "", rest)
            if (substr(rest,1,1)=="\"") {
                rest=substr(rest, 2)
                out=""
                i=1
                while (i<=length(rest)) {
                    c=substr(rest, i, 1)
                    if (c=="\\" && i<length(rest)) {
                        n=substr(rest, i+1, 1)
                        if (n=="\"") { out=out "\""; i+=2; continue }
                        if (n=="\\") { out=out "\\"; i+=2; continue }
                        if (n=="n")  { out=out "\n"; i+=2; continue }
                        if (n=="t")  { out=out "\t"; i+=2; continue }
                        out=out n; i+=2; continue
                    }
                    if (c=="\"") { print out; exit }
                    out=out c
                    i++
                }
                print out; exit
            }
            # Numeric / bool / null. Strip up to the next , } or whitespace.
            n=length(rest)
            out=""
            for (i=1;i<=n;i++) {
                c=substr(rest,i,1)
                if (c=="," || c=="}" || c==" " || c=="\t" || c=="\n") break
                out=out c
            }
            print out; exit
        }
    ' "$f")
    printf '%s' "$val"
}
