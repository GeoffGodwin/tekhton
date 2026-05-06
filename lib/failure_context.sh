#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# failure_context.sh — Primary/secondary failure-cause slots (M129)
#
# Sourced by tekhton.sh BEFORE lib/diagnose_output.sh so the slot variables
# exist by the time any stage tries to populate them. Other libs (writer,
# orchestrate_classify, finalize_dashboard_hooks) consume these slots via
# the helpers below; the variables themselves are exported so cross-stage
# subshells observe the same values.
#
# Provides:
#   reset_failure_cause_context     — zeroes all eight slot vars
#   set_primary_cause   CAT SUB SIG SRC
#   set_secondary_cause CAT SUB SIG SRC
#   format_failure_cause_summary    — 0/1/2-line plain text for state notes
#   emit_cause_objects_json         — pretty-printed nested JSON fragments
#                                     consumed by the writer in
#                                     diagnose_output.sh (Goal 1 contract)
# =============================================================================

# --- Slot variables (module-level, exported for cross-stage visibility) -----
# Initialized to empty strings so `set -u` doesn't fault when consumers read
# them before any stage has set anything.

PRIMARY_ERROR_CATEGORY="${PRIMARY_ERROR_CATEGORY:-}"
PRIMARY_ERROR_SUBCATEGORY="${PRIMARY_ERROR_SUBCATEGORY:-}"
PRIMARY_ERROR_SIGNAL="${PRIMARY_ERROR_SIGNAL:-}"
PRIMARY_ERROR_SOURCE="${PRIMARY_ERROR_SOURCE:-}"
SECONDARY_ERROR_CATEGORY="${SECONDARY_ERROR_CATEGORY:-}"
SECONDARY_ERROR_SUBCATEGORY="${SECONDARY_ERROR_SUBCATEGORY:-}"
SECONDARY_ERROR_SIGNAL="${SECONDARY_ERROR_SIGNAL:-}"
SECONDARY_ERROR_SOURCE="${SECONDARY_ERROR_SOURCE:-}"
export PRIMARY_ERROR_CATEGORY PRIMARY_ERROR_SUBCATEGORY \
    PRIMARY_ERROR_SIGNAL PRIMARY_ERROR_SOURCE \
    SECONDARY_ERROR_CATEGORY SECONDARY_ERROR_SUBCATEGORY \
    SECONDARY_ERROR_SIGNAL SECONDARY_ERROR_SOURCE

# --- Slot management ---------------------------------------------------------

# reset_failure_cause_context
# Zeros all eight slot vars. Called at run start, at each run_complete_loop
# iteration, and after a successful finalize. See M129 Goal 5.
reset_failure_cause_context() {
    PRIMARY_ERROR_CATEGORY=""
    PRIMARY_ERROR_SUBCATEGORY=""
    PRIMARY_ERROR_SIGNAL=""
    PRIMARY_ERROR_SOURCE=""
    SECONDARY_ERROR_CATEGORY=""
    SECONDARY_ERROR_SUBCATEGORY=""
    SECONDARY_ERROR_SIGNAL=""
    SECONDARY_ERROR_SOURCE=""
    export PRIMARY_ERROR_CATEGORY PRIMARY_ERROR_SUBCATEGORY \
        PRIMARY_ERROR_SIGNAL PRIMARY_ERROR_SOURCE \
        SECONDARY_ERROR_CATEGORY SECONDARY_ERROR_SUBCATEGORY \
        SECONDARY_ERROR_SIGNAL SECONDARY_ERROR_SOURCE
}

# set_primary_cause CATEGORY SUBCATEGORY SIGNAL SOURCE
# Populates the four PRIMARY_* slot vars. Stages call this when they know
# the upstream cause (e.g. UI gate detecting interactive reporter).
set_primary_cause() {
    PRIMARY_ERROR_CATEGORY="${1:-}"
    PRIMARY_ERROR_SUBCATEGORY="${2:-}"
    PRIMARY_ERROR_SIGNAL="${3:-}"
    PRIMARY_ERROR_SOURCE="${4:-}"
    export PRIMARY_ERROR_CATEGORY PRIMARY_ERROR_SUBCATEGORY \
        PRIMARY_ERROR_SIGNAL PRIMARY_ERROR_SOURCE
}

# set_secondary_cause CATEGORY SUBCATEGORY SIGNAL SOURCE
# Populates the four SECONDARY_* slot vars. Stages call this when they only
# see the downstream effect (e.g. max_turns timeout in build-fix loop).
set_secondary_cause() {
    SECONDARY_ERROR_CATEGORY="${1:-}"
    SECONDARY_ERROR_SUBCATEGORY="${2:-}"
    SECONDARY_ERROR_SIGNAL="${3:-}"
    SECONDARY_ERROR_SOURCE="${4:-}"
    export SECONDARY_ERROR_CATEGORY SECONDARY_ERROR_SUBCATEGORY \
        SECONDARY_ERROR_SIGNAL SECONDARY_ERROR_SOURCE
}

# --- Notes summary -----------------------------------------------------------

# format_failure_cause_summary
# 0/1/2-line plain-text summary of the current cause slots.
#   - empty when both primary and secondary slots are unset
#   - one line when only primary is set
#   - one line when only secondary is set
#   - two lines when both are set
# Caller is responsible for prefixing/joining with a newline before appending
# to a Notes block.
format_failure_cause_summary() {
    local out=""
    if [[ -n "$PRIMARY_ERROR_CATEGORY" ]] || [[ -n "$PRIMARY_ERROR_SUBCATEGORY" ]] || [[ -n "$PRIMARY_ERROR_SIGNAL" ]]; then
        local pcat="${PRIMARY_ERROR_CATEGORY:-?}"
        local psub="${PRIMARY_ERROR_SUBCATEGORY:-?}"
        local psig="${PRIMARY_ERROR_SIGNAL:-}"
        if [[ -n "$psig" ]]; then
            out="Primary cause: ${pcat}/${psub} (${psig})"
        else
            out="Primary cause: ${pcat}/${psub}"
        fi
    fi
    if [[ -n "$SECONDARY_ERROR_CATEGORY" ]] || [[ -n "$SECONDARY_ERROR_SUBCATEGORY" ]] || [[ -n "$SECONDARY_ERROR_SIGNAL" ]]; then
        local scat="${SECONDARY_ERROR_CATEGORY:-?}"
        local ssub="${SECONDARY_ERROR_SUBCATEGORY:-?}"
        local ssig="${SECONDARY_ERROR_SIGNAL:-}"
        local sline
        if [[ -n "$ssig" ]]; then
            sline="Secondary cause: ${scat}/${ssub} (${ssig})"
        else
            sline="Secondary cause: ${scat}/${ssub}"
        fi
        if [[ -n "$out" ]]; then
            out="${out}"$'\n'"${sline}"
        else
            out="$sline"
        fi
    fi
    printf '%s' "$out"
}

# --- JSON fragment emitter ---------------------------------------------------
#
# Pretty-print contract (Goal 1, NON-NEGOTIABLE):
#   - One inner key per line, terminated by `}` on its own line.
#   - Closing brace gets a trailing comma when more keys follow at the
#     parent level. The writer in diagnose_output.sh manages that comma; this
#     function emits the bare object only.
# Downstream parsers (m130/m132/m133) use grep -oP line scans, NOT jq.

# _fc_json_escape STRING — minimal JSON string escape for cause-slot values.
# Slot values are all simple ASCII tokens in practice (signal vocabulary), but
# we still escape backslashes and double quotes defensively.
_fc_json_escape() {
    local s="${1:-}"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    printf '%s' "$s"
}

# _fc_emit_cause_object INDENT KEY [CAT SUB SIG SRC]
# Internal: emits one nested cause object preceded by `INDENT"KEY": {`.
# Returns 1 if all four cause fields are empty (caller should skip emission).
_fc_emit_cause_object() {
    local indent="$1" key="$2"
    local cat="${3:-}" sub="${4:-}" sig="${5:-}" src="${6:-}"
    if [[ -z "$cat" ]] && [[ -z "$sub" ]] && [[ -z "$sig" ]] && [[ -z "$src" ]]; then
        return 1
    fi
    local inner="${indent}  "
    printf '%s"%s": {\n' "$indent" "$key"
    printf '%s"category": "%s",\n' "$inner" "$(_fc_json_escape "$cat")"
    printf '%s"subcategory": "%s",\n' "$inner" "$(_fc_json_escape "$sub")"
    printf '%s"signal": "%s",\n' "$inner" "$(_fc_json_escape "$sig")"
    printf '%s"source": "%s"\n' "$inner" "$(_fc_json_escape "$src")"
    printf '%s}' "$indent"
    return 0
}

# emit_cause_objects_json INDENT
# Emits both nested cause objects (when populated) at the given indent. Each
# emitted object is followed by ",\n" so the writer can append further keys
# after them. If no slots are populated, prints nothing (writer skips the
# section entirely). Indent defaults to two spaces (matches the writer's
# top-level indent).
emit_cause_objects_json() {
    local indent="${1:-  }"
    if _fc_emit_cause_object "$indent" "primary_cause" \
        "$PRIMARY_ERROR_CATEGORY" "$PRIMARY_ERROR_SUBCATEGORY" \
        "$PRIMARY_ERROR_SIGNAL" "$PRIMARY_ERROR_SOURCE"; then
        printf ',\n'
    fi
    if _fc_emit_cause_object "$indent" "secondary_cause" \
        "$SECONDARY_ERROR_CATEGORY" "$SECONDARY_ERROR_SUBCATEGORY" \
        "$SECONDARY_ERROR_SIGNAL" "$SECONDARY_ERROR_SOURCE"; then
        printf ',\n'
    fi
}

# --- Alias helpers (writer-side) --------------------------------------------
#
# Top-level `category`/`subcategory` aliases follow this precedence:
#   1. SECONDARY_* values when secondary slot populated
#   2. AGENT_ERROR_CATEGORY / AGENT_ERROR_SUBCATEGORY when only those exist
#   3. omitted otherwise (writer must not emit empty-string aliases)
#
# Returns the values via two named echoes so the writer can build the alias
# JSON lines without duplicating the precedence logic.

# resolve_alias_category — echo the alias category or empty string
resolve_alias_category() {
    if [[ -n "$SECONDARY_ERROR_CATEGORY" ]]; then
        printf '%s' "$SECONDARY_ERROR_CATEGORY"
        return 0
    fi
    printf '%s' "${AGENT_ERROR_CATEGORY:-}"
}

# resolve_alias_subcategory — echo the alias subcategory or empty string
resolve_alias_subcategory() {
    if [[ -n "$SECONDARY_ERROR_SUBCATEGORY" ]]; then
        printf '%s' "$SECONDARY_ERROR_SUBCATEGORY"
        return 0
    fi
    printf '%s' "${AGENT_ERROR_SUBCATEGORY:-}"
}
