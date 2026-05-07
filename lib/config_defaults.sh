#!/usr/bin/env bash
# =============================================================================
# config_defaults.sh — m16 wedge shim for the Tekhton config defaults set.
#
# Pre-m16 this file held ~250 `: "${KEY:=VALUE}"` assignments plus the calls
# into config_defaults_ci.sh. m16 ports the entire defaults table into Go
# (internal/config). This shim execs `tekhton config defaults --emit shell`
# and evals the resulting environment. Sourced by:
#
#   - lib/express.sh (express-mode auto-config builder)
#   - tekhton.sh    (early-stage paths that need defaults before pipeline.conf)
#
# The legacy CI-detection helpers (_detect_runtime_ci_environment, et al.)
# were deleted in m16 along with config_defaults_ci.sh; the same logic now
# runs inside `tekhton config load` / `tekhton config defaults` automatically.
# =============================================================================
set -euo pipefail

_resolve_tekhton_bin_for_defaults() {
    [[ -n "${TEKHTON_BIN:-}" ]] && { echo "${TEKHTON_BIN}"; return 0; }
    [[ -x "${TEKHTON_HOME:-}/bin/tekhton" ]] && { echo "${TEKHTON_HOME}/bin/tekhton"; return 0; }
    command -v tekhton >/dev/null 2>&1 && { echo "tekhton"; return 0; }
    return 1
}

_emit_config_defaults() {
    local _bin _emit
    if ! _bin=$(_resolve_tekhton_bin_for_defaults); then
        # Pre-build / first-clone path: silently no-op rather than crash. The
        # loader path (lib/config.sh) is the supported entry; this shim is a
        # convenience for callers that need defaults without pipeline.conf.
        return 0
    fi
    # Intentionally omit --project-dir: callers source this file before
    # load_config and expect the *unresolved* relative paths so they can
    # apply their own resolution rules (test_tekhton_dir_root_cleanliness.sh
    # asserts every _FILE default sits under .tekhton/, which only holds for
    # the unresolved form). Path resolution belongs to lib/config.sh::load_config.
    if ! _emit=$("$_bin" config defaults --emit shell 2>/dev/null); then
        return 0
    fi
    eval "$_emit"
}

_emit_config_defaults
