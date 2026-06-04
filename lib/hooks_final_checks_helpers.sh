#!/usr/bin/env bash
# shellcheck shell=bash
# =============================================================================
# hooks_final_checks_helpers.sh — m42. Pure helpers for the final-checks hook.
#
# Extracted from lib/hooks_final_checks.sh so the parent file stays under the
# 300-line ceiling after the m42 no-op TEST_CMD guard landed.
#
# Sourced by lib/hooks_final_checks.sh — do not run directly.
# =============================================================================

# _is_noop_test_cmd — Returns 0 when $1 is a recognized no-op (true / : /
# empty after trimming). Mirrors internal/preflight.IsNoopCommand in Go so
# the preflight warning and the runtime gate agree on what counts as no-op.
# Operationally `${TEST_CMD:-true}` runs `true` for unset, "", and "true" —
# all three count.
_is_noop_test_cmd() {
    local raw="${1-}"
    # Strip surrounding whitespace without invoking sed.
    raw="${raw#"${raw%%[![:space:]]*}"}"
    raw="${raw%"${raw##*[![:space:]]}"}"
    case "$raw" in
        ""|"true"|"/bin/true"|"/usr/bin/true"|":") return 0 ;;
    esac
    return 1
}

# _record_tests_run_state — Persist the "did we actually run tests?" signal
# so the run-level envelope can carry it. Two writers:
#
#  1. ${TEKHTON_DIR}/.tests_run_state — single line "true" or "false". Cheap
#     for downstream bash readers; the dashboard / metrics emit also pick
#     this up without re-parsing RUN_RESULT.json.
#  2. RUN_RESULT.json — splice in `"tests_run": false`. The Go runner wrote
#     the file before this hook ran (writeResult happens before
#     BashHookRunner.Finalize); jq is the lowest-friction patch path.
#
# Both writes are best-effort: missing dirs or absent jq fall through
# silently so the run still finalizes.
_record_tests_run_state() {
    local state="$1"        # "true" or "false"
    local tekhton_dir="${TEKHTON_DIR:-.tekhton}"
    if [[ ! -d "$tekhton_dir" ]]; then
        return 0
    fi
    printf '%s\n' "$state" > "${tekhton_dir}/.tests_run_state" 2>/dev/null || true

    local rr_file="${TEKHTON_RUN_RESULT_FILE:-${tekhton_dir}/RUN_RESULT.json}"
    if [[ ! -f "$rr_file" ]]; then
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        return 0
    fi
    local bool_state="true"
    [[ "$state" = "false" ]] && bool_state="false"
    local tmp="${rr_file}.tmp.$$"
    if jq --argjson v "$bool_state" '. + {tests_run: $v}' "$rr_file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$rr_file"
    else
        rm -f "$tmp"
    fi
}
