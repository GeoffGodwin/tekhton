#!/usr/bin/env bash
# =============================================================================
# platforms/mobile_flutter/detect.sh — Flutter/Dart design system detection
#
# Sourced by source_platform_detect() from _base.sh. Sets:
#   DESIGN_SYSTEM          — material or cupertino
#   DESIGN_SYSTEM_CONFIG   — Path to primary theme definition file
#   COMPONENT_LIBRARY_DIR  — Path to reusable widget directory
#
# Depends on: PROJECT_DIR set by caller
# =============================================================================
# shellcheck disable=SC2034  # Variables used by caller via export
set -euo pipefail

# --- Theme system detection ---------------------------------------------------

_detect_flutter_theme_system() {
    local proj_dir="${PROJECT_DIR:-.}"
    local lib_dir="${proj_dir}/lib"

    if [[ ! -d "$lib_dir" ]]; then
        return
    fi

    # Check for MaterialApp vs CupertinoApp in Dart files
    local has_material=false
    local has_cupertino=false

    if grep -rql 'MaterialApp' "$lib_dir" 2>/dev/null; then
        has_material=true
    fi
    if grep -rql 'CupertinoApp' "$lib_dir" 2>/dev/null; then
        has_cupertino=true
    fi

    if [[ "$has_material" == "true" ]]; then
        DESIGN_SYSTEM="material"
    elif [[ "$has_cupertino" == "true" ]]; then
        DESIGN_SYSTEM="cupertino"
    fi
}

# --- Design token / theme config detection ------------------------------------

_detect_flutter_theme_config() {
    local proj_dir="${PROJECT_DIR:-.}"
    local lib_dir="${proj_dir}/lib"

    if [[ ! -d "$lib_dir" ]]; then
        return
    fi

    # Look for custom theme files matching *theme*.dart, *color*.dart, *style*.dart
    local candidate
    while IFS= read -r candidate; do
        if [[ -n "$candidate" ]]; then
            DESIGN_SYSTEM_CONFIG="$candidate"
            return
        fi
    done < <(find "$lib_dir" -maxdepth 3 -type f \( \
        -name '*theme*.dart' -o -name '*color*.dart' -o -name '*style*.dart' \
    \) 2>/dev/null | head -1)

    # Check for ThemeExtension subclasses (custom semantic tokens)
    local ext_file
    ext_file=$(grep -rsl 'ThemeExtension' "$lib_dir" 2>/dev/null | head -1 || true)
    if [[ -n "$ext_file" ]]; then
        DESIGN_SYSTEM_CONFIG="$ext_file"
        return
    fi

    # Check for ColorScheme.fromSeed or explicit ColorScheme construction
    local cs_file
    cs_file=$(grep -rsl 'ColorScheme\.\|ColorScheme(' "$lib_dir" 2>/dev/null | head -1 || true)
    if [[ -n "$cs_file" ]] && [[ -z "${DESIGN_SYSTEM_CONFIG:-}" ]]; then
        DESIGN_SYSTEM_CONFIG="$cs_file"
    fi
}

# --- Widget / component directory detection -----------------------------------

_detect_flutter_component_dir() {
    local proj_dir="${PROJECT_DIR:-.}"
    local candidate
    local candidates=(
        "lib/widgets"
        "lib/ui"
        "lib/components"
        "lib/presentation"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "${proj_dir}/${candidate}" ]]; then
            COMPONENT_LIBRARY_DIR="${proj_dir}/${candidate}"
            return
        fi
    done
}

# --- Run detection ------------------------------------------------------------

_detect_flutter_theme_system
_detect_flutter_theme_config
_detect_flutter_component_dir
