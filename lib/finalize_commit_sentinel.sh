#!/usr/bin/env bash
# =============================================================================
# finalize_commit_sentinel.sh — Sentinel-file readers for the commit gate
#
# Sourced by lib/finalize_commit.sh — do not run directly.
#
# Provides:
#   _final_check_result_read   — first line of .final_check_result as numeric
#   _final_check_reason_read   — `# <reason>` comment line (m41), de-marked
#
# The sentinel is written by lib/common.sh::trip_commit_gate as two lines:
#   1) the exit code (`1`)
#   2) `# <reason>` (e.g. `# coder_did_not_produce_summary`)
# Idempotent — first reason wins (see trip_commit_gate body).
# =============================================================================
set -euo pipefail

# _final_check_result_read
# Returns the persisted FINAL_CHECK_RESULT (0 when no failure was recorded).
# Each finalize hook runs in its own bash subprocess under the Go shim, so
# the in-memory FINAL_CHECK_RESULT set by _hook_final_checks does not
# survive to _hook_commit — the sentinel file (.tekhton/.final_check_result)
# is what carries the verdict between hooks.
_final_check_result_read() {
    local f="${TEKHTON_DIR:-.tekhton}/.final_check_result"
    [[ -f "$f" ]] || { echo 0; return 0; }
    local v
    v=$(head -1 "$f" 2>/dev/null | tr -d '[:space:]')
    [[ -z "$v" ]] && { echo 0; return 0; }
    echo "$v"
}

# _final_check_reason_read
# Returns the persisted block reason from the sentinel file (the `# <reason>`
# comment line written by trip_commit_gate). Empty when no reason recorded
# or no sentinel exists. m41: surfaced by _hook_commit so the operator sees
# the actual cause (e.g. coder_did_not_produce_summary,
# completion_gate_failed_substantive_work_only) instead of the
# contradictory FINAL_CHECK_RESULT=0 / persisted=1 pair the previous
# diagnostic printed.
_final_check_reason_read() {
    local f="${TEKHTON_DIR:-.tekhton}/.final_check_result"
    [[ -f "$f" ]] || return 0
    local raw
    raw=$(sed -n '2p' "$f" 2>/dev/null) || return 0
    # Strip leading "# " comment marker written by trip_commit_gate.
    raw="${raw#\# }"
    raw="${raw#\#}"
    # Trim surrounding whitespace.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    printf '%s' "$raw"
}
