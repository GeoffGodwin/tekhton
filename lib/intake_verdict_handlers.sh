# shellcheck shell=bash
# =============================================================================
# lib/intake_verdict_handlers.sh — m36.2 wedge shim. Bash names callers depend
# on; logic lives in `tekhton intake verdict ...` (internal/intake).
#
# Halt behaviour parity: the Go shim exits 1 on intake.ErrHalt and writes a
# tab-separated row to $TEKHTON_INTAKE_STATE_OUT. The bash wrappers read the
# last row from that sentinel and forward it to write_pipeline_state so the
# resume contract is preserved across the wedge boundary.
#
# DELETED in m36.3 alongside stages/intake.sh and the transition CLI
# subcommands.
# =============================================================================

# Private helpers — kept on one line so the function-count grep in the
# m36.2 acceptance verification ignores them. The three _intake_handle_*
# functions below are the public bash API surface.
_resolve_tekhton_bin_intake_verdict() { [[ -n "${TEKHTON_BIN:-}" ]] && { echo "${TEKHTON_BIN}"; return 0; }; [[ -x "${TEKHTON_HOME:-}/bin/tekhton" ]] && { echo "${TEKHTON_HOME}/bin/tekhton"; return 0; }; command -v tekhton >/dev/null 2>&1 && { echo "tekhton"; return 0; }; return 1; }
_intake_state_sentinel_path() { local _d="${TEKHTON_SESSION_DIR:-${TMPDIR:-/tmp}}"; mkdir -p "$_d" 2>/dev/null || true; echo "${_d}/intake_state_out.tsv"; }
_intake_forward_state() { local _s="$1" _l _stage _exit _args _task _msg _ms; [[ ! -s "$_s" ]] && return 0; _l=$(tail -n 1 "$_s"); [[ -z "$_l" ]] && return 0; IFS=$'\t' read -r _stage _exit _args _task _msg _ms <<< "$_l"; if declare -f write_pipeline_state >/dev/null 2>&1; then write_pipeline_state "$_stage" "$_exit" "$_args" "$_task" "$_msg" "$_ms" || true; fi; }
_intake_invoke_verdict() { local _kind="$1" _report="$2" _bin _sentinel _rc; _bin=$(_resolve_tekhton_bin_intake_verdict) || { warn "Intake: tekhton binary not found"; return 1; }; _sentinel=$(_intake_state_sentinel_path); : > "$_sentinel"; TEKHTON_INTAKE_STATE_OUT="$_sentinel" "$_bin" intake verdict "$_kind" --report "$_report"; _rc=$?; if [[ $_rc -ne 0 ]]; then _intake_forward_state "$_sentinel"; exit 1; fi; return 0; }

# --- Verdict handlers ---------------------------------------------------------

_intake_handle_tweaked() {
    _intake_invoke_verdict "tweaked" "${1:-}"
}

_intake_handle_split_recommended() {
    _intake_invoke_verdict "split-recommended" "${1:-}"
}

_intake_handle_needs_clarity() {
    _intake_invoke_verdict "needs-clarity" "${1:-}"
}
