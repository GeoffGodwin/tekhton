#!/usr/bin/env bash
set -euo pipefail

# shellcheck shell=bash
# =============================================================================
# milestone_acceptance_lint.sh — Acceptance criteria quality linter
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn() from common.sh
#
# Provides:
#   lint_acceptance_criteria              — main entry: lint a milestone file
#   _lint_has_behavioral_criterion        — check for behavioral keywords
#   _lint_refactor_has_completeness_check — refactor milestone check
#   _lint_config_has_self_referential_check — config milestone check
# =============================================================================

# _lint_extract_criteria FILE
# Extracts acceptance criteria text from a milestone file.
# Strips fenced code blocks to avoid matching patterns inside code snippets.
# Reads from "## Acceptance Criteria" heading to the next "##" heading.
_lint_extract_criteria() {
    local file="$1"
    local in_criteria=false
    local in_code_block=false
    local criteria=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^##[[:space:]]+Acceptance[[:space:]]+Criteria ]]; then
            in_criteria=true
            continue
        fi
        if [[ "$in_criteria" = true ]]; then
            # Toggle code block state on fenced delimiters (handles indented fences)
            if [[ "$line" =~ ^[[:space:]]*\`\`\` ]]; then
                if [[ "$in_code_block" = true ]]; then
                    in_code_block=false
                else
                    in_code_block=true
                fi
                continue
            fi
            if [[ "$in_code_block" = true ]]; then
                continue
            fi
            # Break on next ## heading only when outside code blocks
            if [[ "$line" =~ ^##[[:space:]] ]]; then
                break
            fi
            criteria+="${line}"$'\n'
        fi
    done < "$file"

    echo "$criteria"
}

# _lint_extract_title FILE
# Returns the milestone title from the first H1 heading.
_lint_extract_title() {
    local file="$1"
    local title
    title=$(grep -m1 -- '^# ' "$file" 2>/dev/null || true)
    echo "${title#\# }"
}

# _lint_infer_categories TITLE
# Returns space-separated category tags based on title keywords.
# Possible values: "refactor", "config", or empty.
_lint_infer_categories() {
    local title="$1"
    local cats=""
    if echo "$title" | grep -qiE '\b(refactor|migrat|move|rename|parameteriz)\b'; then
        cats+="refactor "
    fi
    if echo "$title" | grep -qiE '\b(config|variable|default)\b|pipeline\.conf'; then
        cats+="config "
    fi
    echo "$cats"
}

# _lint_has_behavioral_criterion CRITERIA_TEXT
# Returns a warning message if no criteria contain behavioral verification
# keywords. Empty output means at least one behavioral criterion was found.
#
# Behavioral keywords are verbs indicating runtime/functional verification
# (handles, detects, rejects, emits, etc.). Common boilerplate words like
# "passes", "exists", "contains", "creates", "returns" are deliberately
# excluded — they appear in purely structural criteria too often.
_lint_has_behavioral_criterion() {
    local criteria="$1"

    local behavioral_re
    behavioral_re='\b(produces?|handles?|detects?|rejects?|triggers?'
    behavioral_re+='|strips?|preserves?|flags?|outputs?|emits?|renders?'
    behavioral_re+='|validates?|parses?|appends?|asserts?|retains?)\b'
    behavioral_re+='|creates? zero|produces? no'
    behavioral_re+='|verify at runtime|at runtime|\bobserve\b'

    if echo "$criteria" | grep -qiE "$behavioral_re"; then
        return 0
    fi

    echo "Lint: no behavioral acceptance criteria found — all criteria appear structural. Consider adding criteria that verify runtime behavior."
}

# _lint_refactor_has_completeness_check CRITERIA_TEXT
# For refactor milestones: warns if no criterion verifies old references
# are fully removed. Empty output means a completeness check was found.
_lint_refactor_has_completeness_check() {
    local criteria="$1"

    if echo "$criteria" | grep -qiE '\bgrep\b|no[[:space:]]+(remaining|occurrences|references|instances)\b'; then
        return 0
    fi

    echo "Lint: refactor milestone lacks completeness verification — add a criterion verifying no old references remain."
}

# _lint_config_has_self_referential_check CRITERIA_TEXT
# For config milestones: warns if no criterion tests the configuration
# within the pipeline itself. Empty output means a self-referential
# check was found.
_lint_config_has_self_referential_check() {
    local criteria="$1"

    if echo "$criteria" | grep -qiE 'pipeline\.conf|config_defaults|self.referential|own.configuration'; then
        return 0
    fi

    echo "Lint: config milestone lacks self-referential check — add a criterion verifying the configuration works within the pipeline."
}

# _lint_extract_deliverables FILE
# Echoes the first-column paths of the "## Files Modified" table, one per line.
# Skips the header/separator rows and pure-Delete rows (a deletion needs no
# verifying criterion).
_lint_extract_deliverables() {
    local file="$1"
    awk '
        /^## Files Modified/ { ins=1; next }
        ins && /^## / { exit }
        ins && /^\|/ {
            n=split($0, c, "|"); if (n < 3) next
            path=c[2]; type=c[3]
            gsub(/`/, "", path); gsub(/^[ \t]+|[ \t]+$/, "", path)
            gsub(/^[ \t]+|[ \t]+$/, "", type)
            if (path=="" || path=="File" || path ~ /^-+$/) next
            if (tolower(type) ~ /delete/) next
            print path
        }
    ' "$file" 2>/dev/null
}

# lint_milestone_blocking MILESTONE_FILE
# S4 — high-confidence, low-false-positive BLOCKING authoring checks. Echoes one
# finding per line; empty = clean. These fail the --draft write and the
# standalone gate. Findings:
#   (a) the file declares Files Modified but has no Acceptance Criteria section;
#   (b) a vague acceptance criterion with no observable predicate.
# Per-file coverage is intentionally NOT here — it is advisory
# (lint_milestone_coverage) because criteria legitimately reference symbols
# (ProfileFor) rather than filenames (profile.go), so coverage flags would be
# false-positive-prone as a hard gate. Runtime deliverable existence is enforced
# by S2 (the deliverable gate) instead.
lint_milestone_blocking() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local criteria findings=""
    criteria=$(_lint_extract_criteria "$file")

    local have_deliverables=false
    if [[ -n "$(_lint_extract_deliverables "$file")" ]]; then
        have_deliverables=true
    fi
    if [[ "$have_deliverables" = true ]] && [[ -z "$criteria" ]]; then
        findings+="declares Files Modified but has no '## Acceptance Criteria' section"$'\n'
    fi

    if [[ -n "$criteria" ]]; then
        local vague v
        vague=$(grep -niE 'works? correctly|as expected|handles? edge cases|works? properly|behaves? correctly|where relevant|if needed|and so on|etc\.' <<< "$criteria" || true)
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            findings+="vague criterion (use an observable predicate): ${v#*:}"$'\n'
        done <<< "$vague"
    fi

    findings="${findings%$'\n'}"
    [[ -n "$findings" ]] && printf '%s\n' "$findings"
    return 0
}

# lint_milestone_coverage MILESTONE_FILE
# S4 — ADVISORY per-file coverage hint: a Files-Modified deliverable whose path
# or basename is named in NO acceptance criterion. Surfaced for the author to
# improve, NOT blocking (criteria may reference a symbol rather than the file).
lint_milestone_coverage() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local criteria findings="" d base
    criteria=$(_lint_extract_criteria "$file")
    [[ -n "$criteria" ]] || return 0
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        base=$(basename "$d")
        if ! grep -qF "$d" <<< "$criteria" && ! grep -qF "$base" <<< "$criteria"; then
            findings+="deliverable '${d}' has no verifying acceptance criterion"$'\n'
        fi
    done < <(_lint_extract_deliverables "$file")
    findings="${findings%$'\n'}"
    [[ -n "$findings" ]] && printf '%s\n' "$findings"
    return 0
}

# lint_acceptance_criteria MILESTONE_FILE
# Main entry point. Returns warning lines (empty if all checks pass).
lint_acceptance_criteria() {
    local file="$1"
    local warnings=""

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local criteria
    criteria=$(_lint_extract_criteria "$file")

    if [[ -z "$criteria" ]]; then
        return 0
    fi

    # Check 1: Behavioral criteria (universal — applies to all milestones)
    local w
    w=$(_lint_has_behavioral_criterion "$criteria")
    if [[ -n "$w" ]]; then
        warnings+="${w}"$'\n'
    fi

    # Infer category from title for conditional checks
    local title
    title=$(_lint_extract_title "$file")
    local categories
    categories=$(_lint_infer_categories "$title")

    # Check 2: Refactor completeness (only for refactor-category milestones)
    if [[ "$categories" == *refactor* ]]; then
        w=$(_lint_refactor_has_completeness_check "$criteria")
        if [[ -n "$w" ]]; then
            warnings+="${w}"$'\n'
        fi
    fi

    # Check 3: Config self-referential (only for config-category milestones)
    if [[ "$categories" == *config* ]]; then
        w=$(_lint_config_has_self_referential_check "$criteria")
        if [[ -n "$w" ]]; then
            warnings+="${w}"$'\n'
        fi
    fi

    # Trim trailing newline
    warnings="${warnings%$'\n'}"
    echo "$warnings"
}
