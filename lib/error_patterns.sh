#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# error_patterns.sh — Declarative error pattern registry & classification engine
#
# Sourced by tekhton.sh — do not run directly.
# Provides: load_error_patterns(), classify_build_error(),
#           classify_build_errors_all(), get_pattern_count()
#
# Milestone 53: Error Pattern Registry & Build Gate Classification.
#
# Each registry entry: REGEX_PATTERN|CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS
# Categories: env_setup, service_dep, toolchain, resource, test_infra, code
# Safety: safe, prompt, manual, code
#
# Registry data lives in error_patterns_registry.sh (provides _build_pattern_registry).
# =============================================================================

# Source registry data
source "${TEKHTON_HOME:?}/lib/error_patterns_registry.sh"

# --- Pattern storage (parallel arrays) --------------------------------------
_EP_PATTERNS=()
_EP_CATEGORIES=()
_EP_SAFETIES=()
_EP_REMEDIATIONS=()
_EP_DIAGNOSES=()
_EP_LOADED=false

# --- _build_pattern_registry lives in error_patterns_registry.sh -----------

# --- load_error_patterns ----------------------------------------------------
# Parse the registry into parallel arrays. Cached: only loads once.
load_error_patterns() {
    if [[ "$_EP_LOADED" == "true" ]]; then
        return 0
    fi

    _EP_PATTERNS=()
    _EP_CATEGORIES=()
    _EP_SAFETIES=()
    _EP_REMEDIATIONS=()
    _EP_DIAGNOSES=()

    local line
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ -z "$line" ]] && continue
        [[ "$line" == \#* ]] && continue

        local pattern category safety remediation diagnosis
        pattern=$(echo "$line" | cut -d'|' -f1)
        category=$(echo "$line" | cut -d'|' -f2)
        safety=$(echo "$line" | cut -d'|' -f3)
        remediation=$(echo "$line" | cut -d'|' -f4)
        diagnosis=$(echo "$line" | cut -d'|' -f5)

        [[ -z "$pattern" ]] && continue

        _EP_PATTERNS+=("$pattern")
        _EP_CATEGORIES+=("$category")
        _EP_SAFETIES+=("$safety")
        _EP_REMEDIATIONS+=("$remediation")
        _EP_DIAGNOSES+=("$diagnosis")
    done < <(_build_pattern_registry)

    _EP_LOADED=true
}

# --- get_pattern_count ------------------------------------------------------
# Returns the number of loaded patterns.
get_pattern_count() {
    load_error_patterns
    echo "${#_EP_PATTERNS[@]}"
}

# --- classify_build_error ---------------------------------------------------
# Takes error output string, returns FIRST matching classification.
# Output: CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS
# Falls back to code|code||Unclassified build error if no match.
#
# Usage: classify_build_error "error text line"
classify_build_error() {
    local error_text="${1:-}"
    [[ -z "$error_text" ]] && { echo "code|code||Empty error input"; return 0; }

    load_error_patterns

    local i
    for i in "${!_EP_PATTERNS[@]}"; do
        if printf '%s\n' "$error_text" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
            echo "${_EP_CATEGORIES[$i]}|${_EP_SAFETIES[$i]}|${_EP_REMEDIATIONS[$i]}|${_EP_DIAGNOSES[$i]}"
            return 0
        fi
    done

    echo "code|code||Unclassified build error"
}

# --- classify_build_errors_all ----------------------------------------------
# Returns ALL matching patterns from multi-line error output.
# Processes line-by-line with deduplication by category+diagnosis.
# Output: one CATEGORY|SAFETY|REMEDIATION_CMD|DIAGNOSIS line per unique match.
#
# Usage: classify_build_errors_all "$multi_line_error_output"
classify_build_errors_all() {
    local error_output="${1:-}"
    [[ -z "$error_output" ]] && return 0

    load_error_patterns

    # Track seen classifications to deduplicate
    local -A _seen=()
    local line i key

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local matched=false
        for i in "${!_EP_PATTERNS[@]}"; do
            if printf '%s\n' "$line" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
                key="${_EP_CATEGORIES[$i]}|${_EP_DIAGNOSES[$i]}"
                if [[ -z "${_seen[$key]+x}" ]]; then
                    _seen[$key]=1
                    echo "${_EP_CATEGORIES[$i]}|${_EP_SAFETIES[$i]}|${_EP_REMEDIATIONS[$i]}|${_EP_DIAGNOSES[$i]}"
                fi
                matched=true
                break  # First match per line, then next line
            fi
        done

        # Unmatched lines default to code category (deduplicated to single entry)
        if [[ "$matched" == "false" ]]; then
            key="code|code||Unclassified build error"
            if [[ -z "${_seen[$key]+x}" ]]; then
                _seen[$key]=1
                echo "code|code||Unclassified build error"
            fi
        fi
    done <<< "$error_output"
}

# --- filter_code_errors -----------------------------------------------------
# Filters ${BUILD_ERRORS_FILE} content to extract only code-category errors.
# Returns a markdown block with non-code errors summarized and code errors
# preserved in full.
#
# Usage: filter_code_errors "$build_errors_content"
filter_code_errors() {
    local content="${1:-}"
    [[ -z "$content" ]] && return 0

    load_error_patterns

    local code_lines="" non_code_summaries=""
    local line

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local is_code=true
        local i
        for i in "${!_EP_PATTERNS[@]}"; do
            if printf '%s\n' "$line" | grep -qiE "${_EP_PATTERNS[$i]}" 2>/dev/null; then
                if [[ "${_EP_CATEGORIES[$i]}" != "code" ]]; then
                    is_code=false
                    local _diag="${_EP_DIAGNOSES[$i]}"
                    local _cat="${_EP_CATEGORIES[$i]}"
                    non_code_summaries+="- ${_cat}: ${_diag}"$'\n'
                fi
                break
            fi
        done

        if [[ "$is_code" == "true" ]]; then
            code_lines+="${line}"$'\n'
        fi
    done <<< "$content"

    # Emit filtered output
    if [[ -n "$non_code_summaries" ]]; then
        echo "## Already Handled (not code errors)"
        # Deduplicate summary lines
        echo "$non_code_summaries" | sort -u
        echo ""
    fi

    if [[ -n "$code_lines" ]]; then
        echo "## Code Errors to Fix"
        echo "$code_lines"
    fi
}

# --- annotate_build_errors --------------------------------------------------
# Takes raw error output and stage label, returns annotated ${BUILD_ERRORS_FILE}
# content with classification headers.
#
# Usage: annotate_build_errors "$raw_output" "$stage_label"
# NOTE: Raw error text is NOT included in output. Callers must write raw errors
# separately (see gates.sh: ${BUILD_RAW_ERRORS_FILE}).
annotate_build_errors() {
    local raw_output="${1:-}"
    local stage_label="${2:-unknown}"

    load_error_patterns

    local classifications
    classifications=$(classify_build_errors_all "$raw_output")

    local has_env=false has_code=false
    local classification_block=""
    local env_count=0 code_count=0

    while IFS='|' read -r cat safety remed diag; do
        [[ -z "$cat" ]] && continue
        if [[ "$cat" == "code" ]]; then
            has_code=true
            code_count=$((code_count + 1))
            classification_block+="- **${cat}** (${safety}): ${diag}"$'\n'
        else
            has_env=true
            env_count=$((env_count + 1))
            if [[ -n "$remed" ]]; then
                classification_block+="- **${cat}** (${safety}): ${diag}"$'\n'
                classification_block+="  -> Auto-fix: \`${remed}\`"$'\n'
            else
                classification_block+="- **${cat}** (${safety}): ${diag}"$'\n'
            fi
        fi
    done <<< "$classifications"

    # Build annotated output
    echo "# Build Errors — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "## Stage"
    echo "${stage_label}"
    echo ""

    if [[ -n "$classification_block" ]]; then
        echo "## Error Classification"
        printf '%s' "$classification_block"
        echo ""
    fi

    if [[ "$has_env" == "true" ]]; then
        echo "## Classified as Environment/Setup (${env_count} issue(s))"
    fi
    if [[ "$has_code" == "true" ]]; then
        echo "## Classified as Code Error (${code_count} issue(s))"
    fi
}

# --- has_only_noncode_errors ------------------------------------------------
# Returns 0 if ALL classifications are non-code, 1 otherwise.
#
# Usage: has_only_noncode_errors "$raw_error_output"
has_only_noncode_errors() {
    local raw_output="${1:-}"
    [[ -z "$raw_output" ]] && return 1

    local classifications
    classifications=$(classify_build_errors_all "$raw_output")

    while IFS='|' read -r cat _safety _remed _diag; do
        [[ -z "$cat" ]] && continue
        if [[ "$cat" == "code" ]]; then
            return 1
        fi
    done <<< "$classifications"

    return 0
}
