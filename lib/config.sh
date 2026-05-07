#!/usr/bin/env bash
# =============================================================================
# config.sh — m16 wedge shim for the Tekhton pipeline.conf loader.
#
# Sourced by tekhton.sh. The loader, defaulter, validator, clamper, and CI
# auto-detector live in Go under internal/config and are reached via
# `tekhton config load --emit shell`. This file resolves the binary, locates
# pipeline.conf, and sources the resolved environment.
#
# Provides: load_config(), apply_milestone_overrides()
# =============================================================================
set -euo pipefail

_CONF_FILE="${PROJECT_DIR}/.claude/pipeline.conf"

_resolve_tekhton_bin() {
    [[ -n "${TEKHTON_BIN:-}" ]] && { echo "${TEKHTON_BIN}"; return 0; }
    [[ -x "${TEKHTON_HOME}/bin/tekhton" ]] && { echo "${TEKHTON_HOME}/bin/tekhton"; return 0; }
    command -v tekhton >/dev/null 2>&1 && { echo "tekhton"; return 0; }
    return 1
}

_run_config_load() {
    local _bin _emit
    if ! _bin=$(_resolve_tekhton_bin); then
        echo "[✗] tekhton binary not found; run 'make build' or set TEKHTON_BIN." >&2
        exit 1
    fi
    if ! _emit=$("$_bin" config load --path "$_CONF_FILE" --project-dir "$PROJECT_DIR" "$@"); then
        exit 1
    fi
    eval "$_emit"
}

load_config() {
    if [[ ! -f "$_CONF_FILE" ]]; then
        echo "[✗] pipeline.conf not found at: $_CONF_FILE" >&2
        echo "    Run 'tekhton --init' from your project root to create one." >&2
        exit 1
    fi
    _run_config_load --emit shell
}

apply_milestone_overrides() {
    _run_config_load --milestone-mode --emit shell --no-warn
}
