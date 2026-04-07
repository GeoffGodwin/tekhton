#!/usr/bin/env bash
# =============================================================================
# platforms/web/detect.sh — Web design system detection
#
# Sourced by source_platform_detect() from _base.sh. Sets:
#   DESIGN_SYSTEM          — Detected design system name (e.g., tailwind, mui)
#   DESIGN_SYSTEM_CONFIG   — Path to design system config file (if found)
#   COMPONENT_LIBRARY_DIR  — Path to reusable component directory (if found)
#
# Depends on: detect.sh (_extract_json_keys, _check_dep) already loaded
# =============================================================================
# shellcheck disable=SC2034  # Variables used by caller via export
set -euo pipefail

# --- Design system detection --------------------------------------------------

_detect_web_design_system() {
    local proj_dir="${PROJECT_DIR:-.}"
    local deps=""
    local pkg="${proj_dir}/package.json"

    if [[ -f "$pkg" ]]; then
        deps=$(_extract_json_keys "$pkg" '"dependencies"' '"devDependencies"')
    fi

    # --- Component libraries (higher precedence than CSS frameworks) ----------

    # MUI
    if _check_dep "$deps" '"@mui/material"'; then
        DESIGN_SYSTEM="mui"
        return
    fi

    # Chakra UI
    if _check_dep "$deps" '"@chakra-ui/react"'; then
        DESIGN_SYSTEM="chakra"
        return
    fi

    # shadcn/ui — detected via components.json with shadcn schema
    if [[ -f "${proj_dir}/components.json" ]]; then
        # shellcheck disable=SC2016  # $schema is a literal JSON key, not a variable
        if grep -q '"style"\|"\$schema".*shadcn\|"aliases"' "${proj_dir}/components.json" 2>/dev/null; then
            DESIGN_SYSTEM="shadcn"
            return
        fi
    fi

    # Ant Design
    if _check_dep "$deps" '"antd"'; then
        DESIGN_SYSTEM="antd"
        return
    fi

    # Vuetify
    if _check_dep "$deps" '"vuetify"'; then
        DESIGN_SYSTEM="vuetify"
        return
    fi

    # Element Plus
    if _check_dep "$deps" '"element-plus"'; then
        DESIGN_SYSTEM="element-plus"
        return
    fi

    # Headless UI (React or Vue)
    if _check_dep "$deps" '"@headlessui/react"' || _check_dep "$deps" '"@headlessui/vue"'; then
        DESIGN_SYSTEM="headlessui"
        return
    fi

    # Radix (without shadcn — shadcn already returned above)
    if echo "$deps" | grep -q '"@radix-ui/react-' 2>/dev/null; then
        DESIGN_SYSTEM="radix"
        return
    fi

    # --- CSS frameworks (lower precedence) ------------------------------------

    # Tailwind CSS — check config files first, then package.json
    local tailwind_config=""
    local tc
    for tc in "tailwind.config.ts" "tailwind.config.js" "tailwind.config.cjs" "tailwind.config.mjs"; do
        if [[ -f "${proj_dir}/${tc}" ]]; then
            tailwind_config="${proj_dir}/${tc}"
            break
        fi
    done

    if [[ -n "$tailwind_config" ]] || _check_dep "$deps" '"tailwindcss"'; then
        DESIGN_SYSTEM="tailwind"
        if [[ -n "$tailwind_config" ]]; then
            DESIGN_SYSTEM_CONFIG="$tailwind_config"
        fi
        return
    fi

    # UnoCSS
    if _check_dep "$deps" '"unocss"' || _check_dep "$deps" '"@unocss'; then
        DESIGN_SYSTEM="unocss"
        local uno_config
        for uno_config in "uno.config.ts" "uno.config.js"; do
            if [[ -f "${proj_dir}/${uno_config}" ]]; then
                DESIGN_SYSTEM_CONFIG="${proj_dir}/${uno_config}"
                break
            fi
        done
        return
    fi

    # Bootstrap
    if _check_dep "$deps" '"bootstrap"'; then
        DESIGN_SYSTEM="bootstrap"
        return
    fi

    # Bulma
    if _check_dep "$deps" '"bulma"'; then
        DESIGN_SYSTEM="bulma"
        return
    fi
}

# --- CSS custom property / design token files ---------------------------------

_detect_web_design_tokens() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Only scan if DESIGN_SYSTEM_CONFIG is not already set
    if [[ -n "${DESIGN_SYSTEM_CONFIG:-}" ]]; then
        return
    fi

    local token_file
    local search_dirs=("${proj_dir}/src" "$proj_dir")
    local token_names=("variables.css" "variables.scss" "tokens.css" "tokens.scss" "theme.css" "theme.scss")

    local dir
    for dir in "${search_dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            continue
        fi
        for token_file in "${token_names[@]}"; do
            if [[ -f "${dir}/${token_file}" ]]; then
                DESIGN_SYSTEM_CONFIG="${dir}/${token_file}"
                return
            fi
        done
    done
}

# --- Component directory detection --------------------------------------------

_detect_web_component_dir() {
    local proj_dir="${PROJECT_DIR:-.}"
    local candidate
    local candidates=(
        "src/components/ui"
        "src/components/common"
        "src/ui"
        "components/ui"
        "components/common"
        "app/components/ui"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "${proj_dir}/${candidate}" ]]; then
            COMPONENT_LIBRARY_DIR="${proj_dir}/${candidate}"
            return
        fi
    done
}

# --- Run detection ------------------------------------------------------------

_detect_web_design_system
_detect_web_design_tokens
_detect_web_component_dir
