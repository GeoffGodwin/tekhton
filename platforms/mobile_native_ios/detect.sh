#!/usr/bin/env bash
# =============================================================================
# platforms/mobile_native_ios/detect.sh — iOS design system detection
#
# Sourced by source_platform_detect() from _base.sh. Sets:
#   DESIGN_SYSTEM          — swiftui or uikit
#   DESIGN_SYSTEM_CONFIG   — Path to primary .xcassets directory
#   COMPONENT_LIBRARY_DIR  — Path to reusable view/component directory
#
# Depends on: PROJECT_DIR set by caller
# =============================================================================
# shellcheck disable=SC2034  # Variables used by caller via export
set -euo pipefail

# --- UI framework detection ---------------------------------------------------

_detect_ios_ui_framework() {
    local proj_dir="${PROJECT_DIR:-.}"

    local swiftui_count=0
    local uikit_count=0

    # Count files with SwiftUI imports
    local swiftui_files
    swiftui_files=$(grep -rsl 'import SwiftUI' "$proj_dir" --include='*.swift' 2>/dev/null || true)
    if [[ -n "$swiftui_files" ]]; then
        swiftui_count=$(echo "$swiftui_files" | wc -l)
        swiftui_count="${swiftui_count//[[:space:]]/}"
    fi

    # Count files with UIKit indicators (UIViewController subclasses, storyboards, xibs)
    local uikit_files
    uikit_files=$(grep -rsl 'UIViewController\|UIView\b' "$proj_dir" --include='*.swift' 2>/dev/null || true)
    if [[ -n "$uikit_files" ]]; then
        uikit_count=$(echo "$uikit_files" | wc -l)
        uikit_count="${uikit_count//[[:space:]]/}"
    fi

    # Also count .storyboard and .xib files
    local ib_count=0
    local ib_files
    ib_files=$(find "$proj_dir" -maxdepth 5 -type f \( -name '*.storyboard' -o -name '*.xib' \) 2>/dev/null || true)
    if [[ -n "$ib_files" ]]; then
        ib_count=$(echo "$ib_files" | wc -l)
        ib_count="${ib_count//[[:space:]]/}"
    fi
    uikit_count=$((uikit_count + ib_count))

    if [[ "$swiftui_count" -gt 0 ]] && [[ "$swiftui_count" -ge "$uikit_count" ]]; then
        DESIGN_SYSTEM="swiftui"
    elif [[ "$uikit_count" -gt 0 ]]; then
        DESIGN_SYSTEM="uikit"
    fi
}

# --- Asset catalog detection --------------------------------------------------

_detect_ios_asset_catalog() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Find the primary .xcassets directory
    local xcassets_path
    xcassets_path=$(find "$proj_dir" -maxdepth 4 -type d -name 'Assets.xcassets' 2>/dev/null | head -1 || true)
    if [[ -n "$xcassets_path" ]]; then
        DESIGN_SYSTEM_CONFIG="$xcassets_path"
        return
    fi

    # Fallback: any .xcassets directory
    xcassets_path=$(find "$proj_dir" -maxdepth 4 -type d -name '*.xcassets' 2>/dev/null | head -1 || true)
    if [[ -n "$xcassets_path" ]]; then
        DESIGN_SYSTEM_CONFIG="$xcassets_path"
    fi
}

# --- Component directory detection --------------------------------------------

_detect_ios_component_dir() {
    local proj_dir="${PROJECT_DIR:-.}"
    local candidate
    local candidates=(
        "Views"
        "Screens"
        "Components"
        "Sources/Views"
        "Sources/Screens"
        "Sources/Components"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "${proj_dir}/${candidate}" ]]; then
            COMPONENT_LIBRARY_DIR="${proj_dir}/${candidate}"
            return
        fi
    done

    # Search one level deeper for common Swift project structures
    local found
    found=$(find "$proj_dir" -maxdepth 3 -type d -name 'Views' 2>/dev/null | head -1 || true)
    if [[ -n "$found" ]]; then
        COMPONENT_LIBRARY_DIR="$found"
    fi
}

# --- Run detection ------------------------------------------------------------

_detect_ios_ui_framework
_detect_ios_asset_catalog
_detect_ios_component_dir
