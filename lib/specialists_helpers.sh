#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# specialists_helpers.sh — Specialist review helper functions
#
# Sourced by tekhton.sh after specialists.sh — do not run directly.
# Provides: _specialist_diff_relevant(), _extract_specialist_blockers(),
#           _append_specialist_notes()
# =============================================================================

# _extract_specialist_blockers — Reads [BLOCKER] items from a specialist's output.
# Args: $1 = specialist name
# Returns: blocker text (one per line) or empty string
_extract_specialist_blockers() {
    local spec_name="$1"
    local upper_name
    upper_name=$(echo "$spec_name" | tr '[:lower:]' '[:upper:]')
    local findings_file="SPECIALIST_${upper_name}_FINDINGS.md"

    if [ ! -f "$findings_file" ]; then
        return
    fi

    grep "\[BLOCKER\]" "$findings_file" 2>/dev/null || true
}

# _append_specialist_notes — Reads [NOTE] items and appends to NON_BLOCKING_LOG.md.
# Args: $1 = specialist name
_append_specialist_notes() {
    local spec_name="$1"
    local upper_name
    upper_name=$(echo "$spec_name" | tr '[:lower:]' '[:upper:]')
    local findings_file="SPECIALIST_${upper_name}_FINDINGS.md"

    if [ ! -f "$findings_file" ]; then
        return
    fi

    local notes
    notes=$(grep "\[NOTE\]" "$findings_file" 2>/dev/null || true)

    if [ -z "$notes" ]; then
        return
    fi

    _ensure_nonblocking_log

    local nb_file="${PROJECT_DIR}/${NON_BLOCKING_LOG_FILE}"
    local date_tag
    date_tag=$(date +%Y-%m-%d)

    # Append each [NOTE] item as an open non-blocking note.
    # Uses awk to insert after "## Open" header — avoids sed -i which interprets
    # escape sequences (\n, \t) in the replacement text, corrupting entries.
    local tmpfile
    tmpfile=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/specialist_nb_XXXXXXXX")

    # Build the block of new entries to insert
    local insert_block=""
    while IFS= read -r note_line; do
        [[ -z "$note_line" ]] && continue
        # Strip leading "- " if present
        local text="${note_line#- }"
        insert_block="${insert_block}- [ ] [${date_tag} | specialist:${spec_name}] ${text}"$'\n'
    done <<< "$notes"

    # Insert the block after "## Open" using awk.
    # Reads the insert block from a temp file to avoid export/ENVIRON leak risk
    # and awk -v C-style escape interpretation (\n, \U, etc.).
    local insert_file
    insert_file=$(mktemp "${TEKHTON_SESSION_DIR:-/tmp}/specialist_ins_XXXXXXXX")
    printf '%s' "$insert_block" > "$insert_file"
    awk '/^## Open$/{print; while ((getline line < insfile) > 0) print line; next} {print}' \
        insfile="$insert_file" "$nb_file" > "$tmpfile"
    rm -f "$insert_file"

    mv "$tmpfile" "$nb_file"
    local note_count
    note_count=$(echo "$notes" | grep -c "\[NOTE\]")
    log "[Specialist ${spec_name}] ${note_count} note(s) appended to ${NON_BLOCKING_LOG_FILE}."
}

# =============================================================================
# _specialist_diff_relevant — Check if git diff touches files relevant to a specialist.
# Args: $1 = specialist name (security, performance, api, or custom)
# Returns 0 if relevant files found, 1 if diff is irrelevant.
# Custom specialists always return 0 (relevant) — no keyword list available.
# =============================================================================
_specialist_diff_relevant() {
    local spec_name="$1"

    # Get changed file paths (staged + unstaged vs HEAD)
    local diff_files
    diff_files=$(git diff --name-only HEAD 2>/dev/null || true)
    if [[ -z "$diff_files" ]]; then
        # Also check staged-only changes
        diff_files=$(git diff --name-only --cached 2>/dev/null || true)
    fi

    # If we can't determine diff, be conservative — run the specialist
    if [[ -z "$diff_files" ]]; then
        return 0
    fi

    local patterns
    case "$spec_name" in
        security)
            # Broad keyword list — false negatives are costly for security
            patterns="auth|crypto|crypt|password|passwd|token|session|login|
                      signin|signup|oauth|jwt|secret|key|cert|tls|ssl|
                      cookie|csrf|xss|sanitiz|escap|hash|salt|permiss|
                      access|credential|secur|encrypt|decrypt|verify|
                      middleware|guard|policy|role|acl|rbac"
            ;;
        performance)
            patterns="cache|query|queries|index|perf|optim|loop|batch|
                      pool|buffer|stream|async|concurr|parallel|throttl|
                      debounce|memo|lazy|eager|preload|prefetch|
                      database|db|sql|redis|queue|worker|schedule"
            ;;
        api)
            patterns="route|endpoint|controller|handler|middleware|
                      schema|swagger|openapi|graphql|grpc|proto|
                      request|response|api|rest|rpc|service|
                      serializ|deserializ|dto|payload|contract|
                      version|v1|v2|v3"
            ;;
        ui)
            # File extension + directory pattern matching for UI-related files
            local relevance_patterns='\.tsx$|\.jsx$|\.vue$|\.svelte$|\.css$|\.scss$|\.sass$|\.less$|\.html$|\.dart$|\.swift$|\.kt$|\.kts$|/components/|/pages/|/views/|/screens/|/widgets/|/scenes/|/ui/|/styles/|/theme/|\.storyboard$|\.xib$'
            if echo "$diff_files" | grep -qE "$relevance_patterns"; then
                return 0
            fi
            return 1
            ;;
        *)
            # Custom specialists: no keyword list, always relevant
            return 0
            ;;
    esac

    # Collapse multiline pattern to single line, strip whitespace
    patterns=$(echo "$patterns" | tr -d '[:space:]' | tr -s '|')

    if echo "$diff_files" | grep -qiE "$patterns"; then
        return 0
    fi

    return 1
}
