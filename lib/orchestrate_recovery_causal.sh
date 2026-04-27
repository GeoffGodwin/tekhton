#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# orchestrate_recovery_causal.sh — M130 causal-context state + loader
#
# Sourced by orchestrate_recovery.sh — do not run directly.
#
# Provides:
#   _load_failure_cause_context  — populate _ORCH_PRIMARY_*/SECONDARY_* from
#                                  LAST_FAILURE_CONTEXT.json (schema v1 or v2)
#   _reset_orch_recovery_state   — reset persistent retry guards + route slot
#
# Module-level state (two lifetimes — see m130 Goal 5):
#   Lifetime A — refreshed by _load_failure_cause_context on every call:
#     _ORCH_PRIMARY_CAT, _ORCH_PRIMARY_SUB, _ORCH_PRIMARY_SIGNAL
#     _ORCH_SECONDARY_CAT, _ORCH_SECONDARY_SUB, _ORCH_SECONDARY_SIGNAL
#     _ORCH_SCHEMA_VERSION
#   Lifetime B — persistent across iterations within one run_complete_loop:
#     _ORCH_ENV_GATE_RETRIED       (env-gate retry guard)
#     _ORCH_MIXED_BUILD_RETRIED    (mixed_uncertain build-fix retry guard)
#     _ORCH_RECOVERY_ROUTE_TAKEN   (last action returned — m132 read site)
# =============================================================================

# --- Module-level state ------------------------------------------------------

_ORCH_PRIMARY_CAT=""
_ORCH_PRIMARY_SUB=""
_ORCH_PRIMARY_SIGNAL=""
_ORCH_SECONDARY_CAT=""
_ORCH_SECONDARY_SUB=""
_ORCH_SECONDARY_SIGNAL=""
_ORCH_SCHEMA_VERSION=0
_ORCH_ENV_GATE_RETRIED=0
_ORCH_MIXED_BUILD_RETRIED=0
_ORCH_RECOVERY_ROUTE_TAKEN=""

# --- Reset helper ------------------------------------------------------------

# _reset_orch_recovery_state
# Zeroes the persistent (Lifetime B) retry guards. Called once per
# run_complete_loop invocation (see lib/orchestrate.sh), NOT per iteration —
# resetting per-iteration breaks the retry-once semantic. The Lifetime A
# cause vars are owned by _load_failure_cause_context and refreshed there.
_reset_orch_recovery_state() {
    _ORCH_ENV_GATE_RETRIED=0
    _ORCH_MIXED_BUILD_RETRIED=0
    _ORCH_RECOVERY_ROUTE_TAKEN=""
}

# --- Failure-context loader --------------------------------------------------

# _load_failure_cause_context
# Reads LAST_FAILURE_CONTEXT.json (schema v1 or v2) and populates the
# Lifetime A cause vars. Honors ORCH_CONTEXT_FILE_OVERRIDE so tests can
# point the loader at a fixture without manipulating $PROJECT_DIR.
#
# Behavior matrix:
#   v2 file    — populate _ORCH_PRIMARY_* + _ORCH_SECONDARY_*
#   v1 file    — leave _ORCH_PRIMARY_* empty, populate _ORCH_SECONDARY_*
#                from top-level category/subcategory
#   absent     — all vars empty, _ORCH_SCHEMA_VERSION=0
#
# Always re-reads disk (not cached). Safe to call multiple times.
_load_failure_cause_context() {
    _ORCH_PRIMARY_CAT=""
    _ORCH_PRIMARY_SUB=""
    _ORCH_PRIMARY_SIGNAL=""
    _ORCH_SECONDARY_CAT=""
    _ORCH_SECONDARY_SUB=""
    _ORCH_SECONDARY_SIGNAL=""
    _ORCH_SCHEMA_VERSION=0

    local ctx_file="${ORCH_CONTEXT_FILE_OVERRIDE:-${PROJECT_DIR:-.}/.claude/LAST_FAILURE_CONTEXT.json}"
    [[ -f "$ctx_file" ]] || return 0

    local schema_str
    schema_str=$(grep -oP '"schema_version"\s*:\s*\K[0-9]+' "$ctx_file" 2>/dev/null || true)
    if [[ -z "$schema_str" ]]; then
        _ORCH_SCHEMA_VERSION=1
    else
        _ORCH_SCHEMA_VERSION="$schema_str"
    fi

    if [[ "$_ORCH_SCHEMA_VERSION" -ge 2 ]]; then
        _causal_parse_v2 "$ctx_file"
    else
        _ORCH_SECONDARY_CAT=$(grep -oP '"category"\s*:\s*"\K[^"]+' "$ctx_file" 2>/dev/null || true)
        _ORCH_SECONDARY_SUB=$(grep -oP '"subcategory"\s*:\s*"\K[^"]+' "$ctx_file" 2>/dev/null || true)
    fi
}

# _causal_parse_v2 CTX_FILE
# Line-state-machine parser for the m129 v2 pretty-print contract:
# one key per line, nested objects close with `}` on their own line.
# Avoids a jq runtime dependency; depends on the writer's pretty-print
# guarantee (m129 "Pretty-print contract — NON-NEGOTIABLE").
_causal_parse_v2() {
    local ctx_file="$1"
    local line
    local in_primary=0 in_secondary=0
    while IFS= read -r line; do
        if [[ "$line" == *'"primary_cause"'* ]]; then
            in_primary=1
            in_secondary=0
            continue
        fi
        if [[ "$line" == *'"secondary_cause"'* ]]; then
            in_secondary=1
            in_primary=0
            continue
        fi
        if [[ "$in_primary" -eq 1 ]]; then
            _causal_extract_field "$line" _ORCH_PRIMARY_CAT _ORCH_PRIMARY_SUB _ORCH_PRIMARY_SIGNAL
            [[ "$line" == *'}'* ]] && in_primary=0
            continue
        fi
        if [[ "$in_secondary" -eq 1 ]]; then
            _causal_extract_field "$line" _ORCH_SECONDARY_CAT _ORCH_SECONDARY_SUB _ORCH_SECONDARY_SIGNAL
            [[ "$line" == *'}'* ]] && in_secondary=0
            continue
        fi
    done < "$ctx_file"
}

# _causal_extract_field LINE CAT_VAR SUB_VAR SIG_VAR
# Helper for _causal_parse_v2 — extracts category/subcategory/signal from a
# single JSON line into the named vars. Uses bash regex (no fork).
_causal_extract_field() {
    local line="$1"
    local cat_var="$2" sub_var="$3" sig_var="$4"
    if [[ "$line" =~ \"category\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        printf -v "$cat_var" '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$line" =~ \"subcategory\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        printf -v "$sub_var" '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    if [[ "$line" =~ \"signal\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
        printf -v "$sig_var" '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    return 0
}

# --- Opt-out gate ------------------------------------------------------------

# _causal_env_retry_allowed
# Returns 0 unless the user explicitly set TEKHTON_UI_GATE_FORCE_NONINTERACTIVE=0
# in pipeline.conf (key present in _CONF_KEYS_SET, value "0"). When the key is
# unset or set to anything other than "0", the env-gate retry is permitted.
_causal_env_retry_allowed() {
    if [[ " ${_CONF_KEYS_SET:-} " == *" TEKHTON_UI_GATE_FORCE_NONINTERACTIVE "* ]] \
       && [[ "${TEKHTON_UI_GATE_FORCE_NONINTERACTIVE:-0}" = "0" ]]; then
        return 1
    fi
    return 0
}
