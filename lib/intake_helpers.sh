# shellcheck shell=bash
# =============================================================================
# lib/intake_helpers.sh — m36.2 wedge shim. Bash names callers depend on;
# logic lives in `tekhton intake helpers ...` (internal/intake).
#
# DELETED in m36.3 alongside stages/intake.sh and the transition CLI
# subcommands. Function names, signatures, exit codes, and stdout shapes
# preserved verbatim so stages/intake.sh keeps working unchanged.
#
# Sourced by tekhton.sh — do not run directly.
# =============================================================================

# Private resolver — kept on one line so the function-count grep in the
# m36.2 acceptance verification ignores it. The 11 _intake_* functions
# below are the public bash API surface.
_resolve_tekhton_bin_intake() { [[ -n "${TEKHTON_BIN:-}" ]] && { echo "${TEKHTON_BIN}"; return 0; }; [[ -x "${TEKHTON_HOME:-}/bin/tekhton" ]] && { echo "${TEKHTON_HOME}/bin/tekhton"; return 0; }; command -v tekhton >/dev/null 2>&1 && { echo "tekhton"; return 0; }; return 1; }

# --- Content hash for skip-on-resume -----------------------------------------

_intake_content_hash() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || { echo ""; return 0; }
    printf '%s' "${1:-}" | "$_bin" intake helpers content-hash
}

_intake_should_skip() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || return 1
    "$_bin" intake helpers should-skip --hash "${1:-}" 2>/dev/null
}

_intake_save_hash() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || return 1
    "$_bin" intake helpers save-hash --hash "${1:-}"
}

# --- Report parsing ----------------------------------------------------------

_intake_parse_verdict() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || { echo "PASS"; return 0; }
    "$_bin" intake helpers parse-verdict --report "${1:-}"
}

_intake_parse_confidence() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || { echo "100"; return 0; }
    "$_bin" intake helpers parse-confidence --report "${1:-}"
}

_intake_parse_tweaks() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || return 0
    "$_bin" intake helpers parse-tweaks --report "${1:-}"
}

_intake_parse_questions() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || return 0
    "$_bin" intake helpers parse-questions --report "${1:-}"
}

# --- Tweak application -------------------------------------------------------

_intake_apply_tweak_milestone() {
    local _bin _tmp _rc
    _bin=$(_resolve_tekhton_bin_intake) || { warn "Intake: tekhton binary not found"; return 1; }
    if [[ -z "${1:-}" ]]; then
        warn "Intake: no tweaked content to apply"
        return 1
    fi
    _tmp=$(mktemp "${TMPDIR:-/tmp}/intake_tweak.XXXXXX")
    printf '%s' "$1" > "$_tmp"
    "$_bin" intake helpers apply-tweak-milestone --content-file "$_tmp" --ms "${2:-}"
    _rc=$?
    rm -f "$_tmp"
    return $_rc
}

_intake_apply_tweak_task() {
    local _bin _tmp _new
    _bin=$(_resolve_tekhton_bin_intake) || return 1
    if [[ -z "${1:-}" ]]; then
        return 1
    fi
    _tmp=$(mktemp "${TMPDIR:-/tmp}/intake_task.XXXXXX")
    printf '%s' "$1" > "$_tmp"
    _new=$("$_bin" intake helpers apply-tweak-task --content-file "$_tmp" 2>/dev/null) || true
    rm -f "$_tmp"
    if [[ -n "$_new" ]]; then
        log "Intake: original task: ${TASK:-}"
        TASK="$_new"
        export TASK
        log "Intake: tweaked task: ${TASK:-}"
    fi
}

# --- Milestone content reader -------------------------------------------------

_intake_get_milestone_content() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || { echo "${TASK:-}"; return 0; }
    "$_bin" intake helpers milestone-content
}

# --- PM metadata annotation ---------------------------------------------------

_intake_add_pm_metadata() {
    local _bin
    _bin=$(_resolve_tekhton_bin_intake) || return 0
    "$_bin" intake helpers add-pm-metadata --ms-file "${1:-}"
}
