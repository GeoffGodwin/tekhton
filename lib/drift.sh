#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# drift.sh — Drift log management (observations, thresholds, audit counters)
#
# Sourced by tekhton.sh — do not run directly.
# Expects: PROJECT_DIR, DRIFT_LOG_FILE, ARCHITECTURE_LOG_FILE,
#          HUMAN_ACTION_FILE, DRIFT_OBSERVATION_THRESHOLD,
#          DRIFT_RUNS_SINCE_AUDIT_THRESHOLD, TASK (set by caller/config)
# Depends on: drift_cleanup.sh sourced afterward (provides append_nonblocking_notes,
#             _resolve_addressed_nonblocking_notes)
# =============================================================================

set -euo pipefail

# --- Shared AWK helper -------------------------------------------------------

# _awk_join_bullets — AWK program that parses markdown bullet lists, joins
# continuation lines, and inserts formatted entries after a target section header.
# Args: $1 = section_regex  $2 = printf_format (for date, task, note)
# Returns the AWK program text. Caller passes -v date=... -v task=... -v input=...
_awk_join_bullets() {
    local section_regex="$1"
    local line_format="$2"
    cat <<AWKEOF
${section_regex} {
    print
    n = split(input, lines, "\\n")
    note = ""
    for (i = 1; i <= n; i++) {
        line = lines[i]
        gsub(/[[:space:]]+\$/, "", line)
        if (length(line) == 0) continue
        if (match(line, /^[[:space:]]*-[[:space:]]*/)) {
            if (length(note) > 0 && tolower(note) != "none" && !match(note, /^-+$/)) {
                printf "${line_format}\\n", date, task, note
            }
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/^[[:space:]]+/, "", line)
            note = line
        } else {
            gsub(/^[[:space:]]+/, "", line)
            if (length(note) > 0) {
                note = note " " line
            } else {
                note = line
            }
        }
    }
    if (length(note) > 0 && tolower(note) != "none" && !match(note, /^-+$/)) {
        printf "${line_format}\\n", date, task, note
    }
    next
}
{ print }
AWKEOF
}

# --- Drift Log ---------------------------------------------------------------

# _ensure_drift_log — Creates ${DRIFT_LOG_FILE} with initial structure if missing.
_ensure_drift_log() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        cat > "$drift_file" << 'EOF'
# Drift Log

## Metadata
- Last audit: never
- Runs since audit: 0

## Unresolved Observations

## Resolved
EOF
    fi
}

# append_drift_observations — Reads reviewer report's drift section, appends to log.
# Skips if section contains only "None" or is absent.
append_drift_observations() {
    local reviewer_report="${PROJECT_DIR}/${REVIEWER_REPORT_FILE}"
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"

    if [ ! -f "$reviewer_report" ]; then
        return 0
    fi

    # Extract drift observations section
    local observations
    observations=$(awk '/^## Drift Observations/{found=1; next} found && /^##/{exit} found{print}' \
        "$reviewer_report" 2>/dev/null || true)

    # Skip if empty or only "None"
    if [ -z "$observations" ] || echo "$observations" | grep -qE '^\s*-?\s*None\s*$'; then
        return 0
    fi

    _ensure_drift_log

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="${TASK:-unknown}"

    # Append each observation bullet to the Unresolved section
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")

    local awk_prog
    awk_prog=$(_awk_join_bullets \
        '/^## Unresolved Observations/' \
        '- [%s | \"%s\"] %s')

    awk -v date="$date_tag" -v task="$task_desc" -v input="$observations" \
        "$awk_prog" "$drift_file" > "$tmpfile"

    mv "$tmpfile" "$drift_file"
}

# count_drift_observations — Returns count of unresolved observations.
count_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(awk '/^## Unresolved Observations/{found=1; next} found && /^## [^#]/{exit} found && /^- \[/{count++} END{print count+0}' \
        "$drift_file" 2>/dev/null)
    echo "$count"
}

# resolve_drift_observations — Marks matching observations as resolved.
# Usage: resolve_drift_observations "pattern1" "pattern2" ...
# Moves lines matching any pattern from Unresolved to Resolved.
# Deduplicates: skips observations whose text already appears in Resolved.
resolve_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local date_tag
    date_tag=$(date +%Y-%m-%d)

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local resolved_lines=""

    # Collect patterns into a single grep -E pattern
    local combined_pattern=""
    for pattern in "$@"; do
        if [ -n "$combined_pattern" ]; then
            combined_pattern="${combined_pattern}|${pattern}"
        else
            combined_pattern="$pattern"
        fi
    done

    if [ -z "$combined_pattern" ]; then
        return 0
    fi

    # Pre-read existing resolved entries to avoid duplicates
    local existing_resolved
    existing_resolved=$(awk '/^## Resolved/{found=1; next} found{print}' "$drift_file" 2>/dev/null || true)

    # Process file: move matching unresolved lines to resolved section
    local in_unresolved=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Unresolved Observations"; then
            in_unresolved=true
            echo "$line" >> "$tmpfile"
        elif echo "$line" | grep -q "^## Resolved"; then
            in_unresolved=false
            echo "$line" >> "$tmpfile"
            # Append newly resolved lines here
            if [ -n "$resolved_lines" ]; then
                echo "$resolved_lines" >> "$tmpfile"
            fi
        elif [[ "$in_unresolved" = true ]] && echo "$line" | grep -qE "$combined_pattern"; then
            # This line matches — save for resolved section
            local stripped
            # shellcheck disable=SC2001
            stripped=$(echo "$line" | sed 's/^- \[[^]]*\] //')
            # Skip if this observation text already appears in the Resolved section
            if [ -n "$existing_resolved" ] && echo "$existing_resolved" | grep -qF -- "$stripped"; then
                : # Already resolved — drop from unresolved without re-adding
            else
                resolved_lines="${resolved_lines}
- [RESOLVED ${date_tag}] ${stripped}"
            fi
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
}

# resolve_all_drift_observations — Moves ALL unresolved observations to Resolved.
# Used after architect audit completes: the architect reviewed every observation,
# so all are considered addressed. Out of Scope items get re-added separately.
# Deduplicates: skips observations whose text already appears in Resolved.
resolve_all_drift_observations() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local date_tag
    date_tag=$(date +%Y-%m-%d)

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    local resolved_lines=""

    # Pre-read existing resolved entries to avoid duplicates
    local existing_resolved
    existing_resolved=$(awk '/^## Resolved/{found=1; next} found{print}' "$drift_file" 2>/dev/null || true)

    local in_unresolved=false
    while IFS= read -r line; do
        if echo "$line" | grep -q "^## Unresolved Observations"; then
            in_unresolved=true
            echo "$line" >> "$tmpfile"
        elif echo "$line" | grep -q "^## Resolved"; then
            in_unresolved=false
            echo "$line" >> "$tmpfile"
            # Insert newly resolved lines at top of Resolved section
            if [ -n "$resolved_lines" ]; then
                printf '%s\n' "$resolved_lines" >> "$tmpfile"
            fi
        elif [[ "$in_unresolved" = true ]] && echo "$line" | grep -q "^- \["; then
            # Move this observation to resolved
            local stripped
            # shellcheck disable=SC2001
            stripped=$(echo "$line" | sed 's/^- \[[^]]*\] //')
            # Skip if this observation text already appears in the Resolved section
            if [ -n "$existing_resolved" ] && echo "$existing_resolved" | grep -qF -- "$stripped"; then
                : # Already resolved — drop from unresolved without re-adding
            else
                resolved_lines="${resolved_lines:+${resolved_lines}
}- [RESOLVED ${date_tag}] ${stripped}"
            fi
        else
            echo "$line" >> "$tmpfile"
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
}

# append_drift_entries — Adds raw text entries to the Unresolved section.
# Used to re-add Out of Scope items after bulk resolution.
# Usage: append_drift_entries "entry1" "entry2" ...
append_drift_entries() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    _ensure_drift_log

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local task_desc="architect audit"

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")

    while IFS= read -r line; do
        echo "$line" >> "$tmpfile"
        if echo "$line" | grep -q "^## Unresolved Observations"; then
            for entry in "$@"; do
                echo "- [${date_tag} | \"${task_desc}\"] ${entry}" >> "$tmpfile"
            done
        fi
    done < "$drift_file"

    mv "$tmpfile" "$drift_file"
}

# get_runs_since_audit — Returns the run counter from drift log metadata.
get_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        echo "0"
        return
    fi
    local count
    count=$(grep -m1 "Runs since audit:" "$drift_file" 2>/dev/null | grep -oE '[0-9]+' || echo "0")
    # Defensive: ensure count is numeric (guards against corrupted drift files)
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        count="0"
    fi
    echo "$count"
}

# increment_runs_since_audit — Bumps the run counter by 1.
increment_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    _ensure_drift_log

    local current
    current=$(get_runs_since_audit)
    local new_count=$((current + 1))

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    sed "s/Runs since audit: ${current}/Runs since audit: ${new_count}/" "$drift_file" > "$tmpfile"
    mv "$tmpfile" "$drift_file"
}

# reset_runs_since_audit — Resets counter to 0 and updates last audit date.
reset_runs_since_audit() {
    local drift_file="${PROJECT_DIR}/${DRIFT_LOG_FILE}"
    if [ ! -f "$drift_file" ]; then
        return 0
    fi

    local date_tag
    date_tag=$(date +%Y-%m-%d)
    local current
    current=$(get_runs_since_audit)

    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/drift_XXXXXXXX")
    sed -e "s/Runs since audit: ${current}/Runs since audit: 0/" \
        -e "s/Last audit: .*/Last audit: ${date_tag}/" \
        "$drift_file" > "$tmpfile"
    mv "$tmpfile" "$drift_file"

    # Prune old resolved entries after audit to prevent unbounded growth
    prune_resolved_drift_entries
}

# should_trigger_audit — Returns 0 (true) if audit threshold is reached.
should_trigger_audit() {
    local obs_count
    obs_count=$(count_drift_observations)
    local runs_count
    runs_count=$(get_runs_since_audit)

    if [ "$obs_count" -ge "$DRIFT_OBSERVATION_THRESHOLD" ] 2>/dev/null; then
        return 0
    fi
    if [ "$runs_count" -ge "$DRIFT_RUNS_SINCE_AUDIT_THRESHOLD" ] 2>/dev/null; then
        return 0
    fi
    return 1
}

