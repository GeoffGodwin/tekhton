#!/usr/bin/env bash
# =============================================================================
# tui_ops.sh — TUI state update operations.
#
# Sourced by lib/tui.sh — do not run directly. Provides the public update API
# called from agent.sh and other stages (tui_update_stage, tui_finish_stage,
# tui_update_agent, tui_append_event) plus run_op(), the long-running-command
# wrapper introduced in M104.
#
# M115: run_op is now built on the M113 substage API. The label a run_op
# registers travels through the substage globals and is rendered by the
# breadcrumb logic in tui_render_timings.py.
#
# Lifecycle model: see docs/tui-lifecycle-model.md for stage classes,
# pill/timings/events ownership, and the auto-close-and-warn rule. Invariants
# are enforced by tests/test_tui_lifecycle_invariants.sh.
# =============================================================================
set -euo pipefail
# shellcheck source=lib/tui.sh
# shellcheck source=lib/tui_ops_pause.sh
source "${TEKHTON_HOME}/lib/tui_ops_pause.sh"

# --- Update functions --------------------------------------------------------

# tui_update_stage NUM TOTAL LABEL MODEL — set current stage.
tui_update_stage() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    _TUI_CURRENT_STAGE_NUM="${1:-0}"
    _TUI_CURRENT_STAGE_TOTAL="${2:-0}"
    _TUI_CURRENT_STAGE_LABEL="${3:-}"
    _TUI_CURRENT_STAGE_MODEL="${4:-}"
    _TUI_AGENT_STATUS="running"
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_STAGE_START_TS=$(date +%s)
    _tui_write_status
}

# tui_finish_stage LABEL MODEL TURNS TIME VERDICT — mark stage complete.
tui_finish_stage() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    local entry
    entry=$(_tui_json_stage "$label" "$model" "$turns" "$time_str" "$verdict")
    _TUI_STAGES_COMPLETE+=("$entry")
    _TUI_AGENT_STATUS="idle"
    _tui_write_status
}

# tui_update_agent TURNS_USED TURNS_MAX ELAPSED_SECS [LIFECYCLE_ID] — tick from spinner.
# Safe to call at high frequency; writes atomically. Under TUI_LIFECYCLE_V2, an
# optional 4th arg carries the caller's captured lifecycle id; if it no longer
# matches the current owner (stage ended / transitioned), the update is dropped
# so late ticks cannot leak into the next stage.
tui_update_agent() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    if [[ "${TUI_LIFECYCLE_V2:-true}" == "true" ]]; then
        local _cap_id="${4:-}"
        if [[ -n "$_cap_id" && "$_cap_id" != "${_TUI_CURRENT_LIFECYCLE_ID:-}" ]]; then
            return 0
        fi
        if [[ -n "$_cap_id" && -n "${_TUI_CLOSED_LIFECYCLE_IDS[$_cap_id]:-}" ]]; then
            return 0
        fi
    fi
    _TUI_AGENT_TURNS_USED="${1:-0}"
    _TUI_AGENT_TURNS_MAX="${2:-0}"
    _TUI_AGENT_ELAPSED_SECS="${3:-0}"
    _TUI_AGENT_STATUS="running"
    _tui_write_status
}

# tui_append_event LEVEL MSG [TYPE] [SOURCE] — append to ring buffer and flush status.
# LEVEL: info | warn | error | success
# TYPE: runtime (default) | summary. Summary events carry run-epilogue
# metadata that the hold view renders in a separate block so recap fields
# never appear as late chronological runtime events (M110).
# SOURCE (M117): optional breadcrumb attribution of the form
# "stage » substage" or "stage", computed by _tui_compute_source() in
# lib/common.sh. Empty string (or omitted) means the event is unattributed.
# Msg is serialised last in the entry string so it may contain '|' safely.
tui_append_event() {
    [[ "$_TUI_ACTIVE" == "true" ]] || return 0
    local level="${1:-info}"
    local msg="${2:-}"
    local type="${3:-runtime}"
    local source="${4:-}"
    case "$type" in runtime|summary) ;; *) type="runtime" ;; esac
    local ts
    ts=$(date +"%H:%M:%S")
    _TUI_RECENT_EVENTS+=("${ts}|${level}|${type}|${source}|${msg}")
    local max="${TUI_EVENT_LINES:-60}"
    local overflow=$(( ${#_TUI_RECENT_EVENTS[@]} - max ))
    if (( overflow > 0 )); then
        _TUI_RECENT_EVENTS=("${_TUI_RECENT_EVENTS[@]:overflow}")
    fi
    _tui_write_status
}

# tui_append_summary_event LEVEL MSG — convenience wrapper that routes the
# message as a summary (epilogue) event rather than runtime chronology.
tui_append_summary_event() {
    tui_append_event "${1:-info}" "${2:-}" "summary"
}

# --- run_op: long-running-command wrapper (M104, M115 substage migration) ----

# run_op LABEL CMD [ARGS...]
# Wraps CMD in TUI "working" state with a heartbeat subprocess so the watchdog
# never fires during long operations (tests, build analysis). Transparent
# passthrough when TUI is inactive. Preserves CMD exit code.
# M115: label travels through the M113 substage API — renderer picks it up via
# current_substage_label and displays a "parent » label" breadcrumb.
run_op() {
    local _label="$1"; shift
    if [[ "${_TUI_ACTIVE:-false}" != "true" ]]; then
        "$@"
        return
    fi

    _TUI_AGENT_STATUS="working"
    tui_substage_begin "$_label"

    # Heartbeat: re-write status every ~10s so watchdog never fires during
    # long commands. TERM trap lets `kill` return without a stuck sleeper.
    (
        trap 'exit 0' TERM INT
        while true; do
            sleep 10 &
            wait $!
            _tui_write_status 2>/dev/null || true
        done
    ) &
    local _hb_pid=$!

    local _rc=0
    "$@" || _rc=$?

    kill "$_hb_pid" 2>/dev/null || true
    wait "$_hb_pid" 2>/dev/null || true

    local _verdict="PASS"
    [[ "$_rc" -ne 0 ]] && _verdict="FAIL"
    # Set idle BEFORE tui_substage_end so the substage-end write already carries
    # the final status. Otherwise tui_substage_end flushes a frame with status
    # still "working" and an empty substage label, creating a transitional
    # "Working…" render between the real working frame and the final idle one.
    _TUI_AGENT_STATUS="idle"
    tui_substage_end "$_label" "$_verdict"
    _tui_write_status 2>/dev/null || true

    return "$_rc"
}

# --- Per-milestone reset -----------------------------------------------------

# tui_reset_for_next_milestone — clear per-milestone completion + progress
# state on auto-advance transitions so pills start grey for the next
# milestone. Cleared globals are listed by the function body below.
# Preserved (sidecar-lifetime): _TUI_ACTIVE, _TUI_STAGE_CYCLE (per-label
# monotonic lifecycle-id counter), _TUI_CLOSED_LIFECYCLE_IDS (seen-and-closed
# set), stage-order pill list, overall pipeline start ts. These must stay
# intact across the whole sidecar session so stale late spinner ticks from
# prior milestones continue to be dropped. When adding a new TUI global,
# decide whether its scope is per-milestone (clear here) or sidecar-lifetime
# (preserve here, document above).
# NOTE: _TUI_CURRENT_SUBSTAGE_LABEL is zeroed directly rather than via
# _tui_autoclose_substage_if_open. In practice the substage is always closed
# inside tui_stage_end before the milestone boundary, so no auto-close warn
# event is expected; the silent path is deliberately asymmetric from the
# normal close protocol. If a caller ever crosses a milestone boundary with
# a substage still open, reroute through the auto-close helper.
# Safe no-op when inactive.
tui_reset_for_next_milestone() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    _TUI_STAGES_COMPLETE=()
    _TUI_RECENT_EVENTS=()
    _TUI_CURRENT_STAGE_LABEL=""
    _TUI_CURRENT_STAGE_MODEL=""
    _TUI_CURRENT_STAGE_NUM=0
    _TUI_CURRENT_STAGE_TOTAL=0
    _TUI_AGENT_TURNS_USED=0
    _TUI_AGENT_TURNS_MAX=0
    _TUI_AGENT_ELAPSED_SECS=0
    _TUI_AGENT_STATUS="idle"
    _TUI_STAGE_START_TS=0
    _TUI_CURRENT_LIFECYCLE_ID=""
    _TUI_CURRENT_SUBSTAGE_LABEL=""
    _TUI_CURRENT_SUBSTAGE_START_TS=0
    _tui_write_status
}

# --- Protocol API: stage lifecycle wrappers (M106, M110 lifecycle IDs) -------

# _tui_alloc_lifecycle_id LABEL — allocate next "<label>#<cycle>" id and set
# as current owner. Keyed off _TUI_STAGE_CYCLE (per-label monotonic).
_tui_alloc_lifecycle_id() {
    local label="${1:-}"
    [[ -z "$label" ]] && return 0
    local cur="${_TUI_STAGE_CYCLE[$label]:-0}"
    cur=$((cur + 1))
    _TUI_STAGE_CYCLE[$label]=$cur
    _TUI_CURRENT_LIFECYCLE_ID="${label}#${cur}"
}

# tui_current_lifecycle_id — echo the current owner's lifecycle id.
# Used by spinners to capture an id before sleeping so late updates can be
# rejected when the id has since closed or advanced.
tui_current_lifecycle_id() { printf '%s' "${_TUI_CURRENT_LIFECYCLE_ID:-}"; }

# tui_stage_begin DISPLAY_LABEL [MODEL]
# Begin a stage: allocate a fresh lifecycle id, ensure its pill exists, mark
# it running. DISPLAY_LABEL must come from get_stage_display_label(); callers
# must not pass raw internal stage names.
# NOTE: _TUI_STAGE_ORDER is a single-writer array (main process only). When
# parallel stages are introduced in a future milestone, this will require a
# lock or a migration to an atomic update via the JSON status file.
tui_stage_begin() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    local label="${1:-}"
    local model="${2:-}"
    _tui_alloc_lifecycle_id "$label"
    # Append to _TUI_STAGE_ORDER only when the stage's policy has pill=yes.
    # Sub-stages (scout, architect-remediation, rework) are invisible in the
    # pill row by design; their begin calls still allocate a lifecycle id and
    # drive the active-stage frame, but must not mutate the pill-row array
    # that was seeded deterministically at bootstrap (M110).
    local _pill="yes"
    if declare -f get_stage_policy &>/dev/null; then
        local _pol
        _pol=$(get_stage_policy "$label")
        _pill="${_pol#*|}"
        _pill="${_pill%%|*}"
    fi
    if [[ "$_pill" == "yes" ]]; then
        local _found=false
        local _s
        for _s in "${_TUI_STAGE_ORDER[@]:-}"; do
            [[ "$_s" == "$label" ]] && { _found=true; break; }
        done
        [[ "$_found" == "false" ]] && _TUI_STAGE_ORDER+=("$label")
    elif [[ "$_pill" == "conditional" ]]; then
        # Architect is conditional: include only if already seeded by the
        # deterministic plan (which happens when promoted via FORCE_AUDIT or
        # drift thresholds).
        :
    fi
    local _idx=0 _i
    for _i in "${!_TUI_STAGE_ORDER[@]}"; do
        [[ "${_TUI_STAGE_ORDER[$_i]}" == "$label" ]] && { _idx=$((_i + 1)); break; }
    done
    # When the stage is not in the pill row (sub), use the existing active
    # index so the header stays anchored on the parent pipeline stage rather
    # than jumping to 0/N.
    if (( _idx == 0 )); then
        _idx="${_TUI_CURRENT_STAGE_NUM:-0}"
    fi
    tui_update_stage "$_idx" "${#_TUI_STAGE_ORDER[@]}" "$label" "$model"
}

# tui_stage_end DISPLAY_LABEL [MODEL] [TURNS_STR] [TIME_STR] [VERDICT]
# End a stage: freeze the timer, mark the lifecycle id closed so late spinner
# updates drop, and append a completion record. DISPLAY_LABEL must match what
# was passed to tui_stage_begin.
tui_stage_end() {
    [[ "${_TUI_ACTIVE:-false}" == "true" ]] || return 0
    # Coalesce writes: auto-close + tui_finish_stage + final state mutations
    # would otherwise issue three separate status-file writes. Suppress the
    # intermediate writes and issue a single final one.
    _TUI_SUPPRESS_WRITE=$(( ${_TUI_SUPPRESS_WRITE:-0} + 1 ))
    declare -f _tui_autoclose_substage_if_open &>/dev/null && _tui_autoclose_substage_if_open
    local label="${1:-}"
    local model="${2:-}"
    local turns="${3:-}"
    local time_str="${4:-}"
    local verdict="${5:-}"
    local _final_elapsed=0
    if [[ "${_TUI_STAGE_START_TS:-0}" -gt 0 ]]; then
        _final_elapsed=$(( $(date +%s) - _TUI_STAGE_START_TS ))
    fi
    _TUI_STAGE_START_TS=0
    _TUI_AGENT_ELAPSED_SECS="$_final_elapsed"
    local _closing_id="${_TUI_CURRENT_LIFECYCLE_ID:-}"
    tui_finish_stage "$label" "$model" "$turns" "$time_str" "$verdict"
    if [[ -n "$_closing_id" ]]; then
        _TUI_CLOSED_LIFECYCLE_IDS[$_closing_id]=1
    fi
    _TUI_CURRENT_LIFECYCLE_ID=""
    _TUI_SUPPRESS_WRITE=$(( ${_TUI_SUPPRESS_WRITE:-1} - 1 ))
    _tui_write_status
}

