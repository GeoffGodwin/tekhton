#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
# =============================================================================
# error_patterns_classify.sh — Confidence-based mixed-log routing classifier
#
# Sourced by lib/error_patterns.sh — do not run directly.
# Provides:
#   _is_non_diagnostic_line          — allow-list-first noise filter
#   classify_build_errors_with_stats — multi-line stats classifier (no implicit
#                                      code fallback for unmatched lines)
#   has_explicit_code_errors         — true only when a line matched a code pattern
#   classify_routing_decision        — emits one of four routing tokens AND
#                                      exports LAST_BUILD_CLASSIFICATION
#
# Milestone 127: Mixed-log classification hardening & confidence-based routing.
#
# Token vocabulary (cross-milestone contract — see m127 Watch For):
#   code_dominant | noncode_dominant | mixed_uncertain | unknown_only
# M130's _classify_failure reads ${LAST_BUILD_CLASSIFICATION:-code_dominant}
# and branches on these exact tokens. Do not rename or extend without M130
# coordination.
# =============================================================================

# --- Routing thresholds ------------------------------------------------------
# Minimum noncode-line confidence (% of total matched + unmatched lines)
# required to route a code-free log to noncode_dominant. Below this, fall
# through to unknown_only so the build-fix loop still gets a chance to run
# with low-confidence guidance.
_NONCODE_CONFIDENCE_THRESHOLD=60

# --- Noise-line denylist ----------------------------------------------------
# Patterns whose lines should be excluded from classification statistics
# UNLESS the line also contains a failure term (allow-list precedence).
_NOISE_LINE_PATTERNS=(
    '^[[:space:]]*npm[[:space:]]+warn'
    '^[[:space:]]*npm[[:space:]]+notice'
    '^[[:space:]]*pnpm[[:space:]]+warn'
    '^[[:space:]]*yarn[[:space:]]+warn'
    '^[[:space:]]*\[[0-9]+/[0-9]+\]'
    '^[[:space:]]*[0-9]+%[[:space:]]'
    'serving html report at'
    'press[[:space:]]+ctrl[+-]?c[[:space:]]+to[[:space:]]+quit'
    'audit[[:space:]]+hint'
    '^[[:space:]]*\([0-9]+/[0-9]+\)'
    'progress:[[:space:]]*[0-9]+%'
    'reporter:[[:space:]]+'
)

# Failure-term allow-list: lines containing any of these terms are always
# treated as diagnostic, regardless of denylist matches. Keep narrow —
# adding common words inflates the noncode signal and breaks routing.
_FAILURE_TERM_PATTERN='error|failed|timeout|ECONNREFUSED|TS[0-9]+'

# --- _is_non_diagnostic_line ------------------------------------------------
# Returns 0 (true) when LINE should be excluded from classification stats.
# Allow-list runs first so failure lines are never silently dropped.
#
# Usage: if _is_non_diagnostic_line "$line"; then continue; fi
_is_non_diagnostic_line() {
    local line="$1"

    # Whitespace / blank line → noise.
    if [[ -z "${line//[[:space:]]/}" ]]; then
        return 0
    fi

    # ALLOW-LIST FIRST: failure terms always diagnostic. This must run before
    # the deny-list to avoid silently dropping lines like "[1/8] timeout" or
    # "npm warn: TSxxxx detected".
    if printf '%s' "$line" | grep -qiE "$_FAILURE_TERM_PATTERN" 2>/dev/null; then
        return 1
    fi

    # ANSI-only after stripping escape sequences → noise.
    local stripped _esc=$'\033'
    stripped=$(printf '%s' "$line" | sed -E "s/${_esc}\[[0-9;]*[a-zA-Z]//g")
    if [[ -z "${stripped//[[:space:]]/}" ]]; then
        return 0
    fi

    # Deny-list scan.
    local pat
    for pat in "${_NOISE_LINE_PATTERNS[@]}"; do
        if printf '%s' "$line" | grep -qiE -- "$pat" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# --- classify_build_errors_with_stats ---------------------------------------
# Multi-line classifier with explicit unknown semantics. Unmatched lines are
# counted as unknown/noise, not silently emitted as code.
#
# Output format (one record per unique category+diagnosis match):
#   CAT|SAFETY|REMED|DIAG|MATCH_COUNT|TOTAL_MATCHED|TOTAL_LINES|UNMATCHED_LINES
#
# Where TOTAL_MATCHED, TOTAL_LINES, and UNMATCHED_LINES are summary counters
# repeated on each record so any single record carries the full picture.
# Lines flagged by _is_non_diagnostic_line are excluded from TOTAL_LINES.
classify_build_errors_with_stats() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && return 0

    load_error_patterns

    local -a _keys=()
    local -A _count=() _meta=()
    local total_lines=0 total_matched=0 unmatched_lines=0
    local line i key matched

    while IFS= read -r line; do
        if _is_non_diagnostic_line "$line"; then
            continue
        fi
        total_lines=$((total_lines + 1))

        matched=false
        for i in "${!_EP_PATTERNS[@]}"; do
            if printf '%s\n' "$line" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
                matched=true
                total_matched=$((total_matched + 1))
                key="${_EP_CATEGORIES[$i]}|${_EP_DIAGNOSES[$i]}"
                if [[ -z "${_count[$key]+x}" ]]; then
                    _keys+=("$key")
                    _count[$key]=1
                    _meta[$key]="${_EP_CATEGORIES[$i]}|${_EP_SAFETIES[$i]}|${_EP_REMEDIATIONS[$i]}|${_EP_DIAGNOSES[$i]}"
                else
                    _count[$key]=$((_count[$key] + 1))
                fi
                break
            fi
        done

        if [[ "$matched" == "false" ]]; then
            unmatched_lines=$((unmatched_lines + 1))
        fi
    done <<< "$raw"

    for key in "${_keys[@]}"; do
        echo "${_meta[$key]}|${_count[$key]}|${total_matched}|${total_lines}|${unmatched_lines}"
    done
}

# --- has_explicit_code_errors -----------------------------------------------
# Returns 0 only when at least one line matched an explicit code-category
# pattern. Unmatched/unknown lines do NOT count as code evidence — that is
# the whole point of M127.
has_explicit_code_errors() {
    local raw="${1:-}"
    [[ -z "$raw" ]] && return 1

    load_error_patterns

    local line i
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if _is_non_diagnostic_line "$line"; then
            continue
        fi
        for i in "${!_EP_PATTERNS[@]}"; do
            if printf '%s\n' "$line" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
                if [[ "${_EP_CATEGORIES[$i]}" == "code" ]]; then
                    return 0
                fi
                break
            fi
        done
    done <<< "$raw"

    return 1
}

# --- classify_routing_decision ----------------------------------------------
# Emits one of four routing tokens (stdout) AND exports
# LAST_BUILD_CLASSIFICATION for downstream consumers (M128 build-fix loop,
# M130 causal-context recovery routing).
#
# Decision rules (order matters — see Watch For in m127):
#   1. matched_code > 0 AND matched_code >= matched_noncode → code_dominant
#   2. matched_code == 0 AND matched_noncode > 0 AND
#      matched_noncode/total >= 60%                          → noncode_dominant
#   3. matched_code > 0 AND matched_noncode > 0              → mixed_uncertain
#   4. all other shapes (no signal, low-confidence noncode)  → unknown_only
classify_routing_decision() {
    local raw="${1:-}"
    local matched_code=0 matched_noncode=0 unmatched=0

    if [[ -z "$raw" ]]; then
        export LAST_BUILD_CLASSIFICATION="unknown_only"
        echo "unknown_only"
        return 0
    fi

    load_error_patterns

    local line i matched
    while IFS= read -r line; do
        if _is_non_diagnostic_line "$line"; then
            continue
        fi
        matched=false
        for i in "${!_EP_PATTERNS[@]}"; do
            if printf '%s\n' "$line" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
                if [[ "${_EP_CATEGORIES[$i]}" == "code" ]]; then
                    matched_code=$((matched_code + 1))
                else
                    matched_noncode=$((matched_noncode + 1))
                fi
                matched=true
                break
            fi
        done
        if [[ "$matched" == "false" ]]; then
            unmatched=$((unmatched + 1))
        fi
    done <<< "$raw"

    local total=$((matched_code + matched_noncode + unmatched))
    local token

    # Rule 1: any code evidence + dominates non-code → code_dominant.
    if (( matched_code > 0 && matched_code >= matched_noncode )); then
        token="code_dominant"
    # Rule 2: pure noncode at >= _NONCODE_CONFIDENCE_THRESHOLD%. Integer
    # arithmetic: bash has no floating-point math; do not introduce a `bc`
    # dependency.
    elif (( matched_noncode > 0 && matched_code == 0 && total > 0 )) \
         && (( matched_noncode * 100 / total >= _NONCODE_CONFIDENCE_THRESHOLD )); then
        token="noncode_dominant"
    # Rule 3: both signals present but code is outnumbered → mixed_uncertain.
    elif (( matched_code > 0 && matched_noncode > 0 )); then
        token="mixed_uncertain"
    # Rule 4: no recognizable signal (or low-confidence noncode below threshold).
    else
        token="unknown_only"
    fi

    export LAST_BUILD_CLASSIFICATION="$token"
    echo "$token"
}
