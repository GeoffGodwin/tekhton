#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# init_config_sections_helpers.sh — Shared helpers for sectioned config emission
#
# Sourced by init_config_sections.sh — do not run directly.
# Depends on: (none)
# =============================================================================

# _emit_section_header — Prints a section header with separator.
_emit_section_header() {
    local num="$1"
    local title="$2"
    local desc="$3"
    cat << EOF

# ═══════════════════════════════════════════════════════════════════════════════
# Section ${num}: ${title}
# ${desc}
# ═══════════════════════════════════════════════════════════════════════════════

EOF
}

# _emit_verified_line — Emits a config key with source annotation and VERIFY marker.
# Args: $1=key, $2=value, $3=confidence, $4=source (optional)
_emit_verified_line() {
    local key="$1" val="$2" conf="$3" source="${4:-}"

    # Emit source annotation if available
    if [[ -n "$source" ]]; then
        echo "# Detected from: ${source} (confidence: ${conf})"
    fi

    case "$conf" in
        high)
            echo "${key}=\"${val}\""
            ;;
        medium)
            [[ -z "$source" ]] && echo "# VERIFY: detected with medium confidence"
            echo "${key}=\"${val}\""
            ;;
        low)
            echo "# SUGGESTION: detected with low confidence — uncomment if correct"
            echo "# ${key}=\"${val}\""
            echo "${key}=\"true\""
            ;;
        *)
            echo "${key}=\"${val}\""
            ;;
    esac
}
