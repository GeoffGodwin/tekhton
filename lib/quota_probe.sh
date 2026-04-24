#!/usr/bin/env bash
# =============================================================================
# quota_probe.sh — Layered probe + back-off helpers for quota pauses (M125)
#
# Sourced by lib/quota.sh — do not run directly. Provides:
#   _quota_detect_probe_mode  — selects version / zero_turn / fallback once
#                               per pipeline invocation and caches in
#                               _QUOTA_PROBE_MODE.
#   _quota_probe              — executes the selected probe; returns 0 when
#                               quota appears available, 1 when still
#                               rate-limited.
#   _quota_next_probe_delay   — returns seconds until the next probe using
#                               the mild exponential back-off + ±10% jitter
#                               described in M125.
#   _quota_fmt_duration       — renders seconds as "5h15m" / "47m" / "30s"
#                               for human-readable pause-entry logs.
# =============================================================================
set -euo pipefail

_QUOTA_PROBE_MODE="${_QUOTA_PROBE_MODE:-}"
_QUOTA_PROBE_LAST_TS="${_QUOTA_PROBE_LAST_TS:-0}"

# _quota_detect_probe_mode — picks the cheapest probe supported by the
# installed claude CLI and caches the result. Runs at most once per
# pipeline. Logs the chosen mode at info level for operator confirmation.
_quota_detect_probe_mode() {
    [[ -n "$_QUOTA_PROBE_MODE" ]] && return 0

    if ! command -v claude &>/dev/null; then
        _QUOTA_PROBE_MODE="fallback"
        return 0
    fi

    # Version probe: zero tokens, zero auth. Cheapest.
    if timeout 10 claude --version </dev/null >/dev/null 2>&1; then
        _QUOTA_PROBE_MODE="version"
        log "[quota] Probe mode: version (zero-token)"
        return 0
    fi

    # Zero-turn probe: requires --max-turns support in the installed CLI.
    local _help
    _help=$(timeout 10 claude --help 2>/dev/null || true)
    if printf '%s' "$_help" | grep -q -- '--max-turns'; then
        _QUOTA_PROBE_MODE="zero_turn"
        log "[quota] Probe mode: zero_turn (~zero tokens)"
        return 0
    fi

    _QUOTA_PROBE_MODE="fallback"
    log "[quota] Probe mode: fallback (real-cost probe, min-interval ${QUOTA_PROBE_MIN_INTERVAL:-600}s)"
}

# _quota_probe — returns 0 if the probe succeeds (quota possibly available),
# 1 if the probe's stderr matches is_rate_limit_error (still exhausted).
_quota_probe() {
    _quota_detect_probe_mode

    local probe_stderr
    probe_stderr=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/quota_probe_XXXXXX.txt")

    local probe_exit=0
    case "$_QUOTA_PROBE_MODE" in
        version)
            timeout 10 claude --version </dev/null >/dev/null 2>"$probe_stderr" || probe_exit=$?
            ;;
        zero_turn)
            timeout 15 claude --max-turns 0 --output-format text -p "" \
                </dev/null >/dev/null 2>"$probe_stderr" || probe_exit=$?
            ;;
        *)
            # Fallback: rate-limited to at most one call per QUOTA_PROBE_MIN_INTERVAL
            # seconds regardless of QUOTA_RETRY_INTERVAL, so probe cost stays bounded.
            local _now _floor="${QUOTA_PROBE_MIN_INTERVAL:-600}"
            _now=$(date +%s)
            if [[ "$_QUOTA_PROBE_LAST_TS" -gt 0 ]] \
               && [[ $(( _now - _QUOTA_PROBE_LAST_TS )) -lt "$_floor" ]]; then
                rm -f "$probe_stderr" 2>/dev/null || true
                return 1
            fi
            _QUOTA_PROBE_LAST_TS="$_now"
            timeout 30 claude --max-turns 1 --output-format json \
                -p "respond with OK" \
                </dev/null >/dev/null 2>"$probe_stderr" || probe_exit=$?
            ;;
    esac

    local result=0
    if [[ "$probe_exit" -ne 0 ]]; then
        if command -v is_rate_limit_error &>/dev/null \
           && is_rate_limit_error "$probe_exit" "$probe_stderr"; then
            result=1
        fi
        # Non-rate-limit errors: assume quota may be available, let the
        # real call either succeed or re-enter the pause with a fresh
        # Retry-After hint.
    fi

    rm -f "$probe_stderr" 2>/dev/null || true
    return "$result"
}

# _quota_next_probe_delay PROBE_NUM PREV_DELAY
# PROBE_NUM is 1-based: probe 1 runs at the Retry-After delay (caller
# supplies it), probes 2 uses QUOTA_RETRY_INTERVAL, probes 3+ use mild
# 1.5× back-off on top of PREV_DELAY, capped by QUOTA_PROBE_MAX_INTERVAL.
# ±10% uniform jitter applied on every non-trivial delay so many pipelines
# refreshing against the same window don't thundering-herd the API.
_quota_next_probe_delay() {
    local probe_num="${1:-2}"
    local prev_delay="${2:-0}"
    local base="${QUOTA_RETRY_INTERVAL:-300}"
    local cap="${QUOTA_PROBE_MAX_INTERVAL:-1800}"
    local delay

    if [[ "$probe_num" -le 2 ]]; then
        delay="$base"
    else
        # 1.5× the previous delay → prev_delay * 3 / 2
        delay=$(( prev_delay * 3 / 2 ))
        [[ "$delay" -lt "$base" ]] && delay="$base"
    fi

    [[ "$delay" -gt "$cap" ]] && delay="$cap"

    # ±10% jitter: (90 + RANDOM % 21) / 100 → 90..110 inclusive.
    delay=$(( delay * (90 + RANDOM % 21) / 100 ))
    [[ "$delay" -lt 1 ]] && delay=1
    echo "$delay"
}

# _quota_fmt_duration SECONDS — human-readable form: "5h15m", "47m", "30s".
_quota_fmt_duration() {
    local s="${1:-0}"
    [[ "$s" =~ ^[0-9]+$ ]] || s=0
    local h=$(( s / 3600 ))
    local m=$(( (s % 3600) / 60 ))
    local sec=$(( s % 60 ))
    if [[ "$h" -gt 0 ]]; then
        if [[ "$m" -gt 0 ]]; then
            echo "${h}h${m}m"
        else
            echo "${h}h"
        fi
    elif [[ "$m" -gt 0 ]]; then
        echo "${m}m"
    else
        echo "${sec}s"
    fi
}
