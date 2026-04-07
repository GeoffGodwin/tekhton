#!/usr/bin/env bash
# =============================================================================
# _base.sh — Platform resolution + fragment loading for UI platform adapters
#
# Sourced by tekhton.sh after detect.sh. Provides:
#   detect_ui_platform()       — Maps UI_FRAMEWORK to a platform directory name
#   load_platform_fragments()  — Reads prompt fragments from platform directories
#   source_platform_detect()   — Sources platform-specific detect.sh scripts
#
# Depends on: common.sh (log, warn), detect.sh (UI_FRAMEWORK, UI_PROJECT_DETECTED)
# =============================================================================
set -euo pipefail

# --- Helper: read a platform file with size limit ----------------------------

# _read_platform_file — Reads a file with 1MB size limit.
# Args: $1 = file path
# Output: file content or empty string
_read_platform_file() {
    local file_path="$1"
    local max_bytes=1048576  # 1MB

    if [[ ! -f "$file_path" ]]; then
        return
    fi

    # Cross-platform file size: try GNU stat, then BSD stat, then wc -c
    local file_size=0
    if file_size=$(stat --format='%s' "$file_path" 2>/dev/null); then
        :
    elif file_size=$(stat -f '%z' "$file_path" 2>/dev/null); then
        :
    else
        file_size=$(wc -c < "$file_path" 2>/dev/null || echo 0)
    fi

    if [[ "$file_size" -gt "$max_bytes" ]]; then
        warn "Platform file too large (${file_size} bytes): ${file_path}"
        return
    fi

    cat "$file_path"
}

# --- Helper: resolve platform directory paths --------------------------------

# _resolve_platform_dir — Returns full path to built-in platform directory.
# Args: $1 = platform name
# Output: directory path or empty string
_resolve_platform_dir() {
    local platform="$1"
    local dir="${TEKHTON_HOME}/platforms/${platform}"
    if [[ -d "$dir" ]]; then
        echo "$dir"
    fi
}

# _resolve_user_platform_dir — Returns full path to user's platform override directory.
# Args: $1 = platform name
# Output: directory path or empty string
_resolve_user_platform_dir() {
    local platform="$1"
    local dir="${PROJECT_DIR}/.claude/platforms/${platform}"
    if [[ -d "$dir" ]]; then
        echo "$dir"
    fi
}

# --- Platform resolution -----------------------------------------------------

# detect_ui_platform — Maps detected UI_FRAMEWORK and project type to a platform
# directory name. Sets UI_PLATFORM and UI_PLATFORM_DIR globals.
# Returns 0 if a platform was resolved, 1 if not (non-UI project).
detect_ui_platform() {
    # If UI_PLATFORM is explicitly set (not auto/empty), use it directly
    if [[ -n "${UI_PLATFORM:-}" ]] && [[ "${UI_PLATFORM:-}" != "auto" ]]; then
        UI_PLATFORM_DIR=$(_resolve_platform_dir "$UI_PLATFORM")
        # For custom_* platforms, also check user directory
        if [[ -z "$UI_PLATFORM_DIR" ]]; then
            UI_PLATFORM_DIR=$(_resolve_user_platform_dir "$UI_PLATFORM")
        fi
        export UI_PLATFORM UI_PLATFORM_DIR
        if [[ -n "$UI_PLATFORM_DIR" ]]; then
            return 0
        fi
        # Platform set but directory not found — still honor the setting
        export UI_PLATFORM UI_PLATFORM_DIR=""
        return 0
    fi

    # Skip if not a UI project
    if [[ "${UI_PROJECT_DETECTED:-false}" != "true" ]]; then
        UI_PLATFORM=""
        UI_PLATFORM_DIR=""
        export UI_PLATFORM UI_PLATFORM_DIR
        return 1
    fi

    local framework="${UI_FRAMEWORK:-}"
    local resolved=""

    # Framework-specific resolution
    case "$framework" in
        flutter)
            resolved="mobile_flutter" ;;
        swiftui)
            resolved="mobile_native_ios" ;;
        jetpack-compose)
            resolved="mobile_native_android" ;;
        phaser|pixi|three|babylon)
            resolved="game_web" ;;
        react|vue|svelte|angular|next.js)
            resolved="web" ;;
        playwright|cypress|testing-library|puppeteer)
            resolved="web" ;;
        selenium)
            resolved="web" ;;
        "")
            # Generic detection (2+ UI signals but no specific framework)
            # Use project type to disambiguate
            local project_type="${PROJECT_TYPE:-}"
            case "$project_type" in
                web-game)    resolved="game_web" ;;
                mobile-app)  resolved="mobile_flutter" ;;
                *)           resolved="web" ;;
            esac
            ;;
    esac

    if [[ -n "$resolved" ]]; then
        UI_PLATFORM="$resolved"
        UI_PLATFORM_DIR=$(_resolve_platform_dir "$resolved")
        export UI_PLATFORM UI_PLATFORM_DIR
        return 0
    fi

    UI_PLATFORM=""
    UI_PLATFORM_DIR=""
    export UI_PLATFORM UI_PLATFORM_DIR
    return 1
}

# --- Platform-specific detection ---------------------------------------------

# source_platform_detect — Sources platform detect.sh scripts that set
# DESIGN_SYSTEM, DESIGN_SYSTEM_CONFIG, COMPONENT_LIBRARY_DIR.
source_platform_detect() {
    local platform="${UI_PLATFORM:-}"
    if [[ -z "$platform" ]]; then
        return
    fi

    # Initialize optional globals
    : "${DESIGN_SYSTEM:=}"
    : "${DESIGN_SYSTEM_CONFIG:=}"
    : "${COMPONENT_LIBRARY_DIR:=}"

    # Source built-in platform detect.sh
    local builtin_detect
    builtin_detect="${TEKHTON_HOME}/platforms/${platform}/detect.sh"
    if [[ -f "$builtin_detect" ]]; then
        # shellcheck source=/dev/null
        source "$builtin_detect"
    fi

    # Source user override detect.sh (appends/overrides)
    local user_detect
    user_detect="${PROJECT_DIR}/.claude/platforms/${platform}/detect.sh"
    if [[ -f "$user_detect" ]]; then
        # shellcheck source=/dev/null
        source "$user_detect"
    fi

    export DESIGN_SYSTEM DESIGN_SYSTEM_CONFIG COMPONENT_LIBRARY_DIR
}

# --- Fragment loading --------------------------------------------------------

# load_platform_fragments — Reads .prompt.md files from universal + platform
# directories and assembles them into prompt variables.
# Sets globals: UI_CODER_GUIDANCE, UI_SPECIALIST_CHECKLIST, UI_TESTER_PATTERNS
load_platform_fragments() {
    local platform="${UI_PLATFORM:-}"
    local universal_dir="${TEKHTON_HOME}/platforms/_universal"

    UI_CODER_GUIDANCE=""
    UI_SPECIALIST_CHECKLIST=""
    UI_TESTER_PATTERNS=""

    # 1. Universal coder guidance (always included for UI projects)
    local content
    content=$(_read_platform_file "${universal_dir}/coder_guidance.prompt.md")
    if [[ -n "$content" ]]; then
        UI_CODER_GUIDANCE="$content"
    fi

    # 2. Platform-specific coder guidance (appended)
    if [[ -n "$platform" ]]; then
        content=$(_read_platform_file "${TEKHTON_HOME}/platforms/${platform}/coder_guidance.prompt.md")
        if [[ -n "$content" ]]; then
            UI_CODER_GUIDANCE="${UI_CODER_GUIDANCE:+${UI_CODER_GUIDANCE}
}${content}"
        fi
    fi

    # 3. Universal specialist checklist
    content=$(_read_platform_file "${universal_dir}/specialist_checklist.prompt.md")
    if [[ -n "$content" ]]; then
        UI_SPECIALIST_CHECKLIST="$content"
    fi

    # 4. Platform-specific specialist checklist (appended)
    if [[ -n "$platform" ]]; then
        content=$(_read_platform_file "${TEKHTON_HOME}/platforms/${platform}/specialist_checklist.prompt.md")
        if [[ -n "$content" ]]; then
            UI_SPECIALIST_CHECKLIST="${UI_SPECIALIST_CHECKLIST:+${UI_SPECIALIST_CHECKLIST}
}${content}"
        fi
    fi

    # 5. Platform-specific tester patterns
    if [[ -n "$platform" ]]; then
        UI_TESTER_PATTERNS=$(_read_platform_file "${TEKHTON_HOME}/platforms/${platform}/tester_patterns.prompt.md")
    fi

    # 6. User overrides — append content from PROJECT_DIR/.claude/platforms/
    if [[ -n "$platform" ]]; then
        local user_dir
        user_dir=$(_resolve_user_platform_dir "$platform")
        if [[ -n "$user_dir" ]]; then
            content=$(_read_platform_file "${user_dir}/coder_guidance.prompt.md")
            if [[ -n "$content" ]]; then
                UI_CODER_GUIDANCE="${UI_CODER_GUIDANCE:+${UI_CODER_GUIDANCE}
}${content}"
            fi

            content=$(_read_platform_file "${user_dir}/specialist_checklist.prompt.md")
            if [[ -n "$content" ]]; then
                UI_SPECIALIST_CHECKLIST="${UI_SPECIALIST_CHECKLIST:+${UI_SPECIALIST_CHECKLIST}
}${content}"
            fi

            content=$(_read_platform_file "${user_dir}/tester_patterns.prompt.md")
            if [[ -n "$content" ]]; then
                UI_TESTER_PATTERNS="${UI_TESTER_PATTERNS:+${UI_TESTER_PATTERNS}
}${content}"
            fi
        fi
    fi

    # 7. Append design system info to coder guidance if detected
    if [[ -n "${DESIGN_SYSTEM:-}" ]]; then
        local ds_block="
### Design System: ${DESIGN_SYSTEM}
This project uses ${DESIGN_SYSTEM}."
        if [[ -n "${DESIGN_SYSTEM_CONFIG:-}" ]]; then
            ds_block="${ds_block} Configuration: ${DESIGN_SYSTEM_CONFIG}."
        fi
        ds_block="${ds_block}
Use its tokens, components, and patterns. Do not use raw values when the
design system provides an equivalent."
        if [[ -n "${DESIGN_SYSTEM_CONFIG:-}" ]]; then
            ds_block="${ds_block} Read the config file for available
theme values."
        fi
        UI_CODER_GUIDANCE="${UI_CODER_GUIDANCE:+${UI_CODER_GUIDANCE}
}${ds_block}"
    fi

    # 8. Append component library info if detected
    if [[ -n "${COMPONENT_LIBRARY_DIR:-}" ]]; then
        UI_CODER_GUIDANCE="${UI_CODER_GUIDANCE:+${UI_CODER_GUIDANCE}
}
### Reusable Components
Check ${COMPONENT_LIBRARY_DIR} for existing components before creating new ones."
    fi

    export UI_CODER_GUIDANCE UI_SPECIALIST_CHECKLIST UI_TESTER_PATTERNS
}
