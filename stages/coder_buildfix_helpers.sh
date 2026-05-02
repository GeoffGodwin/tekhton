#!/usr/bin/env bash
# shellcheck shell=bash
set -euo pipefail
# =============================================================================
# stages/coder_buildfix_helpers.sh — Pure helpers for the M128 build-fix loop
#
# Sourced by stages/coder_buildfix.sh — do not run directly.
# Functions here are pure (no I/O beyond optional report writes) so they can
# be exercised in unit tests without stubbing the agent or pipeline state.
# =============================================================================

# _compute_build_fix_budget ATTEMPT BASE_TURNS USED
# Returns the per-attempt turn budget on stdout. Integer-only arithmetic.
#
# Schedule (attempt-indexed): 1.0× / 1.5× / 2.0× of BASE_TURNS, capped at
# EFFECTIVE_CODER_MAX_TURNS * BUILD_FIX_MAX_TURN_MULTIPLIER / 100 and
# floored at 8. The cumulative cap (BUILD_FIX_TOTAL_TURN_CAP) is applied
# last; if the remaining cap is below the 8-turn floor, returns 0 to
# signal the loop should exit ("cap reached").
_compute_build_fix_budget() {
    local attempt="$1" base="$2" used="$3"
    local budget upper remaining cap multiplier max_turns
    multiplier="${BUILD_FIX_MAX_TURN_MULTIPLIER:-100}"
    max_turns="${EFFECTIVE_CODER_MAX_TURNS:-${CODER_MAX_TURNS:-80}}"
    cap="${BUILD_FIX_TOTAL_TURN_CAP:-120}"

    case "$attempt" in
        1) budget=$base ;;
        2) budget=$(( base * 3 / 2 )) ;;
        *) budget=$(( base * 2 )) ;;
    esac

    # Lower-bound floor: every attempt deserves at least 8 turns of room.
    if (( budget < 8 )); then budget=8; fi

    # Upper-bound: clamp to EFFECTIVE_CODER_MAX_TURNS * multiplier / 100.
    upper=$(( max_turns * multiplier / 100 ))
    if (( upper < 8 )); then upper=8; fi
    if (( budget > upper )); then budget=$upper; fi

    # Cumulative cap: bash has no fp math, all integer arithmetic.
    remaining=$(( cap - used ))
    if (( remaining <= 0 )); then echo 0; return 0; fi
    if (( remaining < 8 )); then echo 0; return 0; fi
    if (( budget > remaining )); then budget=$remaining; fi

    echo "$budget"
}

# _build_fix_progress_signal PREV_COUNT NEW_COUNT PREV_TAIL NEW_TAIL
# Pure function. Returns one of: improved | unchanged | worsened
# - improved   when NEW_COUNT < PREV_COUNT
# - worsened   when NEW_COUNT > PREV_COUNT
# - unchanged  when counts equal AND tails equal
# - improved   when counts equal but tails differ (some signal moved)
_build_fix_progress_signal() {
    local prev="$1" new="$2" prev_tail="$3" new_tail="$4"
    if (( new < prev )); then echo "improved"; return 0; fi
    if (( new > prev )); then echo "worsened"; return 0; fi
    if [[ "$prev_tail" == "$new_tail" ]]; then
        echo "unchanged"
    else
        echo "improved"
    fi
}

# _bf_count_errors RAW_PATH
# Line count of the file (or 0 if missing). Pure boundary helper.
_bf_count_errors() {
    local path="$1"
    if [[ -f "$path" ]]; then
        local n
        n=$(wc -l < "$path" 2>/dev/null || echo 0)
        echo "${n//[[:space:]]/}"
    else
        echo 0
    fi
}

# _bf_get_error_tail RAW_PATH
# Last 20 non-blank lines of the raw error stream, joined with newlines.
# Window size is part of the unit-test fixture — do not change without
# updating tests/test_build_fix_loop.sh.
_bf_get_error_tail() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo ""
        return 0
    fi
    grep -v '^[[:space:]]*$' "$path" 2>/dev/null | tail -20 || true
}

# _append_build_fix_report ATTEMPT BUDGET TERMINAL_CLASS GATE_RESULT PROGRESS DELTA CLASSIFICATION
# Append one section per attempt to BUILD_FIX_REPORT_FILE. Schema is one
# section per attempt with the seven fields below; downstream parsers
# (notes pipeline, watchtower) rely on simple grep/sed access.
_append_build_fix_report() {
    local attempt="$1" budget="$2" terminal="$3" gate_result="$4" \
          progress="$5" delta="$6" classification="$7"
    local file="${BUILD_FIX_REPORT_FILE:-.tekhton/BUILD_FIX_REPORT.md}"
    local dir
    dir=$(dirname "$file")
    [[ -d "$dir" ]] || mkdir -p "$dir" 2>/dev/null || return 0

    if [[ ! -f "$file" ]]; then
        cat > "$file" <<EOF
# Build-Fix Report — $(date '+%Y-%m-%d %H:%M:%S')

Per-attempt history of the coder-stage build-fix continuation loop (M128).
Each attempt records the adaptive turn budget, the agent's terminal class,
the post-attempt build-gate result, the progress signal vs. the prior
attempt, and the M127 routing classification at loop entry.
EOF
    fi

    cat >> "$file" <<EOF

## Attempt ${attempt}
- Turn budget: ${budget}
- Terminal class: ${terminal}
- Gate result: ${gate_result}
- Progress signal: ${progress}
- Error-count delta: ${delta}
- M127 classification: ${classification}
EOF
}

# _export_build_fix_stats OUTCOME
# Goal-7 contract: export the four cross-milestone env vars that M132's
# _collect_build_fix_stats_json reads. Token vocabulary is frozen by M128:
# passed | exhausted | no_progress | not_run.
_export_build_fix_stats() {
    local outcome="${1:-not_run}"
    case "$outcome" in
        passed|exhausted|no_progress|not_run) ;;
        *) outcome="not_run" ;;
    esac
    export BUILD_FIX_OUTCOME="$outcome"
    export BUILD_FIX_ATTEMPTS="${BUILD_FIX_ATTEMPTS:-0}"
    export BUILD_FIX_TURN_BUDGET_USED="${BUILD_FIX_TURN_BUDGET_USED:-0}"
    export BUILD_FIX_PROGRESS_GATE_FAILURES="${BUILD_FIX_PROGRESS_GATE_FAILURES:-0}"
}

# _build_fix_set_secondary_cause
# Sets the SECONDARY_ERROR_* env vars per Goal 5 (M129 forward integration).
# Prefers the M129 helper set_secondary_cause when available.
_build_fix_set_secondary_cause() {
    if command -v set_secondary_cause &>/dev/null; then
        set_secondary_cause "AGENT_SCOPE" "max_turns" \
            "build_fix_budget_exhausted" "coder_build_fix"
        return 0
    fi
    export SECONDARY_ERROR_CATEGORY="AGENT_SCOPE"
    export SECONDARY_ERROR_SUBCATEGORY="max_turns"
    export SECONDARY_ERROR_SIGNAL="build_fix_budget_exhausted"
    export SECONDARY_ERROR_SOURCE="coder_build_fix"
}

# _bf_emit_routing_diagnosis RAW_ERRORS — write BUILD_ROUTING_DIAGNOSIS.md
# with category counts and top diagnoses (mixed_uncertain path). Schema is
# kept simple (header + counts + top three) so downstream parsers stay
# trivial. Sourced into the M127 routing path; M128 calls it once at loop
# entry when the decision is mixed_uncertain.
_bf_emit_routing_diagnosis() {
    local raw="$1"
    local stats
    stats=$(classify_build_errors_with_stats "$raw" 2>/dev/null) || stats=""

    local total_matched=0 total_lines=0 unmatched_lines=0
    if [[ -n "$stats" ]]; then
        IFS='|' read -r _c _s _r _d _mc total_matched total_lines unmatched_lines \
            <<< "$(printf '%s\n' "$stats" | head -1)"
    fi

    {
        echo "# Build Routing Diagnosis — $(date '+%Y-%m-%d %H:%M:%S')"
        echo
        echo "## Routing Decision"
        echo "mixed_uncertain — both code and non-code signals present."
        echo
        echo "## Line Stats"
        echo "- considered: ${total_lines}"
        echo "- matched: ${total_matched}"
        echo "- unmatched: ${unmatched_lines}"
        echo
        echo "## Top Diagnoses"
        if [[ -n "$stats" ]]; then
            local rec cat safety diag count
            local i=0
            while IFS= read -r rec; do
                [[ -z "$rec" ]] && continue
                IFS='|' read -r cat safety _remed diag count _tm _tl _ul <<< "$rec"
                echo "- ${cat} (${safety}) ×${count}: ${diag}"
                i=$((i + 1))
                [[ $i -ge 3 ]] && break
            done <<< "$stats"
        else
            echo "- (no recognized signatures)"
        fi
    } > "${BUILD_ROUTING_DIAGNOSIS_FILE}"
}

# _bf_extra_context_for_decision DECISION — return the route-specific
# extra-context block for the agent prompt. mixed_uncertain points at
# BUILD_ROUTING_DIAGNOSIS.md; unknown_only emits a low-confidence note;
# code_dominant returns empty.
_bf_extra_context_for_decision() {
    case "$1" in
        mixed_uncertain)
            printf '%s\n%s' \
                "## Routing Context (mixed_uncertain)" \
                "Both code and non-code error signals were detected in this run. See ${BUILD_ROUTING_DIAGNOSIS_FILE} for category counts and top diagnoses. Fix code errors first; if the build still fails, the remaining issues may be environmental and should be flagged for human action rather than retried."
            ;;
        unknown_only)
            printf '%s\n%s' \
                "## Routing Context (unknown_only)" \
                "No recognized error signatures matched the build output. This is the bounded fallback path: attempt one fix pass, then surface for human triage if it does not converge."
            ;;
        *) : ;;
    esac
}

# _build_fix_terminal_class EXIT_CODE TURNS MAX
# Map run_agent's exit code + turn count to a coarse terminal class for
# the report. Mirrors the existing taxonomy in lib/agent.sh / errors.sh
# but stays self-contained: success | max_turns | error.
_build_fix_terminal_class() {
    local exit_code="${1:-0}" turns="${2:-0}" max="${3:-0}"
    if [[ "$exit_code" -eq 0 ]]; then
        echo "success"
        return 0
    fi
    if (( max > 0 && turns >= max )); then
        echo "max_turns"
        return 0
    fi
    echo "error"
}
