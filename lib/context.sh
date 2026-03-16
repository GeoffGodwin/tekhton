#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# context.sh — Token accounting, context budget measurement, and context compiler
#
# Sourced by tekhton.sh — do not run directly.
# Expects: log(), warn() from common.sh
# Provides: measure_context_size(), log_context_report(), check_context_budget(),
#           extract_relevant_sections(), build_context_packet(),
#           compress_context()
# =============================================================================

# --- Context budget globals --------------------------------------------------

# Accumulated context size (characters) for the current agent invocation.
# Reset by log_context_report() after each report.
_CONTEXT_TOTAL_CHARS=0
_CONTEXT_TOTAL_TOKENS=0
_CONTEXT_REPORT=""

# --- Model context window lookup table ---------------------------------------
# Maps model family prefixes to maximum context window sizes (in tokens).
# These are input token limits — the prompt + context must fit within this.
# Update this table when Anthropic releases new models or changes limits.

_get_model_window() {
    local model="$1"
    case "$model" in
        *opus*)   echo 200000 ;;
        *sonnet*) echo 200000 ;;
        *haiku*)  echo 200000 ;;
        *)        echo 200000 ;;  # Conservative default
    esac
}

# =============================================================================
# measure_context_size — Returns character count and estimated token count
#
# Usage: measure_context_size "some text content"
# Output: two lines — "chars: N" and "tokens: N"
#
# Token estimation uses CHARS_PER_TOKEN (default: 4). This is deliberately
# conservative — real tokenizers produce fewer tokens per character, so our
# estimates will slightly overcount. Good enough for budget checks.
# =============================================================================

measure_context_size() {
    local content="$1"
    local chars=${#content}
    local cpt="${CHARS_PER_TOKEN:-4}"
    local tokens=$(( (chars + cpt - 1) / cpt ))  # Round up
    echo "chars: ${chars}"
    echo "tokens: ${tokens}"
}

# =============================================================================
# log_context_report — Logs a structured breakdown of context components
#
# Called by each stage after assembling context blocks but before render_prompt.
# Each call to _add_context_component accumulates into the report. Then
# log_context_report finalizes and writes the summary.
#
# Usage:
#   _add_context_component "Architecture" "$ARCHITECTURE_BLOCK"
#   _add_context_component "Human Notes" "$HUMAN_NOTES_BLOCK"
#   log_context_report "coder" "$model"
# =============================================================================

_add_context_component() {
    local name="$1"
    local content="$2"

    local chars=${#content}
    if [ "$chars" -eq 0 ]; then
        return
    fi

    local cpt="${CHARS_PER_TOKEN:-4}"
    local tokens=$(( (chars + cpt - 1) / cpt ))

    _CONTEXT_TOTAL_CHARS=$(( _CONTEXT_TOTAL_CHARS + chars ))
    _CONTEXT_TOTAL_TOKENS=$(( _CONTEXT_TOTAL_TOKENS + tokens ))
    _CONTEXT_REPORT="${_CONTEXT_REPORT}    ${name}: ${chars} chars (~${tokens} tokens)\n"
}

log_context_report() {
    local stage="$1"
    local model="$2"

    if [ "${CONTEXT_BUDGET_ENABLED:-true}" != "true" ]; then
        _CONTEXT_TOTAL_CHARS=0
        _CONTEXT_TOTAL_TOKENS=0
        _CONTEXT_REPORT=""
        return
    fi

    local window
    window=$(_get_model_window "$model")
    local budget_pct="${CONTEXT_BUDGET_PCT:-50}"
    local budget_tokens=$(( window * budget_pct / 100 ))

    local pct_used=0
    if [ "$window" -gt 0 ]; then
        pct_used=$(( _CONTEXT_TOTAL_TOKENS * 100 / window ))
    fi

    log "[context] ${stage} context breakdown:"
    if [ -n "${_CONTEXT_REPORT}" ]; then
        echo -e "${_CONTEXT_REPORT}" | while IFS= read -r line; do
            if [ -n "$line" ]; then log "$line"; fi
        done
    fi
    log "  Total: ${_CONTEXT_TOTAL_CHARS} chars (~${_CONTEXT_TOTAL_TOKENS} tokens, ${pct_used}% of ${window} window)"

    if [ "$_CONTEXT_TOTAL_TOKENS" -gt "$budget_tokens" ]; then
        warn "[context] Over budget: ${_CONTEXT_TOTAL_TOKENS} tokens > ${budget_tokens} budget (${budget_pct}% of ${window})"
    fi

    # Store for print_run_summary
    export LAST_CONTEXT_TOKENS="$_CONTEXT_TOTAL_TOKENS"
    export LAST_CONTEXT_PCT="$pct_used"

    # Reset for next stage
    _CONTEXT_TOTAL_CHARS=0
    _CONTEXT_TOTAL_TOKENS=0
    _CONTEXT_REPORT=""
}

# =============================================================================
# check_context_budget — Returns 0 if under budget, 1 if over budget
#
# Usage: check_context_budget "$total_tokens" "$model"
# =============================================================================

check_context_budget() {
    local total_tokens="$1"
    local model="$2"

    if [ "${CONTEXT_BUDGET_ENABLED:-true}" != "true" ]; then
        return 0
    fi

    local window
    window=$(_get_model_window "$model")
    local budget_pct="${CONTEXT_BUDGET_PCT:-50}"
    local budget_tokens=$(( window * budget_pct / 100 ))

    if [ "$total_tokens" -gt "$budget_tokens" ]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Context Compiler — Task-scoped context assembly (Milestone 2)
#
# When CONTEXT_COMPILER_ENABLED=true, agents receive only the sections of large
# artifacts relevant to their current task, instead of full-file injection.
# Falls back to full injection when keyword extraction yields zero matches.
# =============================================================================

# --- _extract_keywords — Extracts keywords from task string and file paths ---
# Parses the task string for significant words and extracts file paths from
# a scout report or coder summary.
# Usage: _extract_keywords "$task" "$scout_or_summary_file"
# Output: newline-separated list of keywords (lowercase)

_extract_keywords() {
    local task="$1"
    local ref_file="${2:-}"

    local keywords=""

    # Extract significant words from task (4+ chars, skip common stop words)
    local task_words
    task_words=$(echo "$task" | tr '[:upper:]' '[:lower:]' | \
        tr -cs '[:alnum:]_-' '\n' | \
        awk 'length >= 4 && !/^(this|that|with|from|into|have|been|will|would|should|could|must|also|when|then|each|only|just|does|done|make|like|some|more|most|very|than|what|which|where|after|before|implement|milestone)$/' | \
        sort -u)
    keywords="${task_words}"

    # Extract file paths from reference file (scout report or coder summary)
    if [ -n "$ref_file" ] && [ -f "$ref_file" ]; then
        local file_words
        # Match paths like lib/foo.sh, stages/bar.sh, src/component.ts
        file_words=$(grep -oE '[a-zA-Z0-9_/.-]+\.[a-z]{1,4}' "$ref_file" 2>/dev/null | \
            sed 's|.*/||' | sed 's/\.[^.]*$//' | tr '[:upper:]' '[:lower:]' | \
            sort -u || true)
        if [ -n "$file_words" ]; then
            keywords="${keywords}
${file_words}"
        fi
    fi

    # Deduplicate and output
    echo "$keywords" | sort -u | grep -v '^$' || true
}

# =============================================================================
# extract_relevant_sections — Filters a markdown file to sections matching keywords
#
# Splits the file on ## headings, keeps sections whose heading or body contains
# at least one keyword. Returns the filtered content.
#
# Usage: extract_relevant_sections "$file_content" "$keywords_newline_separated"
# Output: filtered markdown content (stdout)
#
# If no sections match, returns empty string (caller must handle fallback).
# =============================================================================

extract_relevant_sections() {
    local content="$1"
    local keywords="$2"

    if [ -z "$content" ] || [ -z "$keywords" ]; then
        echo "$content"
        return
    fi

    # Build a grep -i pattern from keywords (pipe-separated)
    local pattern
    pattern=$(echo "$keywords" | tr '\n' '|' | sed 's/|$//')
    if [ -z "$pattern" ]; then
        echo "$content"
        return
    fi

    # Use awk to split on ## headings and filter sections
    local filtered
    filtered=$(echo "$content" | awk -v pat="$pattern" '
    BEGIN {
        IGNORECASE = 1
        section = ""
        header = ""
        in_section = 0
        result = ""
        # Keep everything before the first ## heading (preamble)
        preamble = ""
        seen_heading = 0
    }
    /^## / {
        # Process previous section
        if (in_section && (header ~ pat || section ~ pat)) {
            result = result header section
        }
        header = $0 "\n"
        section = ""
        in_section = 1
        seen_heading = 1
        next
    }
    {
        if (!seen_heading) {
            preamble = preamble $0 "\n"
        } else {
            section = section $0 "\n"
        }
    }
    END {
        # Process last section
        if (in_section && (header ~ pat || section ~ pat)) {
            result = result header section
        }
        # Always include preamble (title, intro text)
        printf "%s%s", preamble, result
    }')

    echo "$filtered"
}

# =============================================================================
# compress_context — Applies compression to a context component
#
# Strategies:
#   truncate          — Keep first N lines (default: 50)
#   summarize_headings — Keep only ## and ### headings
#   omit              — Remove entirely
#
# Usage: compress_context "$content" "strategy" [max_lines]
# Output: compressed content (stdout)
# =============================================================================

compress_context() {
    local content="$1"
    local strategy="$2"
    local max_lines="${3:-50}"

    case "$strategy" in
        truncate)
            local line_count
            line_count=$(echo "$content" | wc -l)
            line_count=$(echo "$line_count" | tr -d '[:space:]')
            if [ "$line_count" -gt "$max_lines" ]; then
                echo "$content" | head -n "$max_lines"
                echo "[... truncated from ${line_count} to ${max_lines} lines]"
            else
                echo "$content"
            fi
            ;;
        summarize_headings)
            echo "$content" | grep -E '^#{1,3} ' || true
            ;;
        omit)
            # Return empty — caller handles the note
            ;;
        *)
            # Unknown strategy — return as-is
            echo "$content"
            ;;
    esac
}

# =============================================================================
# build_context_packet — Assembles task-scoped context for an agent stage
#
# When CONTEXT_COMPILER_ENABLED=true, filters large artifacts to relevant
# sections based on task keywords. Falls back to full content when keyword
# extraction yields zero matches or when sections are marked as always-full.
#
# Usage: build_context_packet "stage" "$task" "$model"
#
# Reads from exported context block variables (ARCHITECTURE_BLOCK, etc.)
# and writes filtered versions back to those variables.
# Also handles compression when context exceeds budget.
#
# Stage-specific behavior:
#   coder   — Architecture always full; other blocks filtered
#   review  — Architecture filtered to files from CODER_SUMMARY.md
#   tester  — Architecture filtered to files from CODER_SUMMARY.md
# =============================================================================

build_context_packet() {
    local stage="$1"
    local task="$2"
    local model="$3"

    if [ "${CONTEXT_COMPILER_ENABLED:-false}" != "true" ]; then
        return
    fi

    # Extract keywords from task and available reference files
    local ref_file=""
    if [ -f "SCOUT_REPORT.md" ]; then
        ref_file="SCOUT_REPORT.md"
    elif [ -f "CODER_SUMMARY.md" ]; then
        ref_file="CODER_SUMMARY.md"
    fi

    local keywords
    keywords=$(_extract_keywords "$task" "$ref_file")

    if [ -z "$keywords" ]; then
        log "[context-compiler] No keywords extracted — using full context (1.0 fallback)"
        return
    fi

    log "[context-compiler] Extracted keywords: $(echo "$keywords" | tr '\n' ', ' | sed 's/,$//')"

    # --- Stage-specific filtering ---

    case "$stage" in
        coder)
            # Architecture stays FULL for coder — it needs the complete map
            # Filter other blocks if they are large
            _filter_block "PRIOR_REVIEWER_CONTEXT" "$keywords"
            _filter_block "PRIOR_TESTER_CONTEXT" "$keywords"
            _filter_block "NON_BLOCKING_CONTEXT" "$keywords"
            _filter_block "PRIOR_PROGRESS_CONTEXT" "$keywords"
            ;;
        review)
            # Filter architecture to sections referencing modified files
            _filter_block "ARCHITECTURE_CONTENT" "$keywords"
            ;;
        tester)
            # Filter architecture to sections referencing modified files
            _filter_block "ARCHITECTURE_CONTENT" "$keywords"
            ;;
    esac

    # --- Budget-based compression ---
    # Estimate total context and compress if over budget
    _compress_if_over_budget "$stage" "$model"
}

# --- _filter_block — Filters a named context block variable by keywords ---
# If filtering produces empty output, falls back to the original content.

_filter_block() {
    local var_name="$1"
    local keywords="$2"

    local original="${!var_name:-}"
    if [ -z "$original" ]; then
        return
    fi

    local filtered
    filtered=$(extract_relevant_sections "$original" "$keywords")

    if [ -z "$filtered" ] || [ "$filtered" = "$original" ]; then
        return  # No change or empty result — keep original
    fi

    # If the original had ## headings but the filtered result has none,
    # that means no sections matched keywords — only preamble survived.
    # Fall back to original to preserve full context (spec: "zero matches → full artifact").
    local orig_has_headings filtered_has_headings
    orig_has_headings=$(echo "$original" | grep -c '^## ' || true)
    filtered_has_headings=$(echo "$filtered" | grep -c '^## ' || true)
    if [ "$orig_has_headings" -gt 0 ] && [ "$filtered_has_headings" -eq 0 ]; then
        return  # Preamble-only result — keep original
    fi

    local orig_lines filtered_lines
    orig_lines=$(echo "$original" | wc -l | tr -d '[:space:]')
    filtered_lines=$(echo "$filtered" | wc -l | tr -d '[:space:]')

    # Only use filtered version if it actually reduced content
    if [ "$filtered_lines" -lt "$orig_lines" ]; then
        log "[context-compiler] ${var_name}: filtered from ${orig_lines} to ${filtered_lines} lines"
        export "$var_name=$filtered"
    fi
}

# --- _compress_if_over_budget — Applies compression to largest non-essential blocks ---
# Compression priority (compress first → last):
#   1. Prior tester context
#   2. Non-blocking notes
#   3. Prior progress context
# Never compresses: architecture (coder), task, human notes

_compress_if_over_budget() {
    local stage="$1"
    local model="$2"

    # Estimate current total
    local total_chars=0
    local -a block_vars

    case "$stage" in
        coder)
            block_vars=("ARCHITECTURE_BLOCK" "GLOSSARY_BLOCK" "MILESTONE_BLOCK" "HUMAN_NOTES_BLOCK" "PRIOR_REVIEWER_CONTEXT" "PRIOR_PROGRESS_CONTEXT" "PRIOR_TESTER_CONTEXT" "NON_BLOCKING_CONTEXT" "BUG_SCOUT_CONTEXT")
            ;;
        review)
            block_vars=("ARCHITECTURE_CONTENT")
            ;;
        tester)
            block_vars=("ARCHITECTURE_CONTENT")
            ;;
        *)
            return
            ;;
    esac

    local i
    for i in "${!block_vars[@]}"; do
        local val="${!block_vars[$i]:-}"
        total_chars=$(( total_chars + ${#val} ))
    done

    local cpt="${CHARS_PER_TOKEN:-4}"
    local total_tokens=$(( (total_chars + cpt - 1) / cpt ))

    if check_context_budget "$total_tokens" "$model"; then
        return  # Under budget — no compression needed
    fi

    log "[context-compiler] Over budget (${total_tokens} est. tokens) — applying compression"

    # Compress in priority order: tester context, non-blocking, progress
    local -a compress_priority=("PRIOR_TESTER_CONTEXT" "NON_BLOCKING_CONTEXT" "PRIOR_PROGRESS_CONTEXT")

    for var_name in "${compress_priority[@]}"; do
        local val="${!var_name:-}"
        if [ -z "$val" ]; then
            continue
        fi

        local orig_chars=${#val}
        local compressed
        compressed=$(compress_context "$val" "truncate" 50)
        export "$var_name=$compressed"

        local new_chars=${#compressed}
        local saved=$(( orig_chars - new_chars ))
        if [ "$saved" -gt 0 ]; then
            log "[context-compiler] Compressed ${var_name}: saved ~$(( saved / cpt )) tokens"
            # Inject compression note
            export "$var_name=[Context compressed: ${var_name} reduced from $(echo "$val" | wc -l | tr -d '[:space:]') to $(echo "$compressed" | wc -l | tr -d '[:space:]') lines]
${compressed}"
        fi

        # Re-check budget
        total_chars=0
        for j in "${!block_vars[@]}"; do
            local v="${!block_vars[$j]:-}"
            total_chars=$(( total_chars + ${#v} ))
        done
        total_tokens=$(( (total_chars + cpt - 1) / cpt ))

        if check_context_budget "$total_tokens" "$model"; then
            log "[context-compiler] Under budget after compressing ${var_name}"
            return
        fi
    done

    warn "[context-compiler] Still over budget after compression (${total_tokens} est. tokens)"
}
