#!/usr/bin/env bash
# =============================================================================
# platforms/mobile_native_android/detect.sh — Android design system detection
#
# Sourced by source_platform_detect() from _base.sh. Sets:
#   DESIGN_SYSTEM          — material3, material, compose, or xml-layouts
#   DESIGN_SYSTEM_CONFIG   — Path to custom theme file (e.g., ui/theme/Theme.kt)
#   COMPONENT_LIBRARY_DIR  — Path to reusable composable/component directory
#
# Depends on: PROJECT_DIR set by caller
# =============================================================================
# shellcheck disable=SC2034  # Variables used by caller via export
set -euo pipefail

# --- UI framework detection ---------------------------------------------------

_detect_android_ui_framework() {
    local proj_dir="${PROJECT_DIR:-.}"

    local compose_count=0
    local xml_count=0

    # Count files with @Composable annotations
    local compose_files
    compose_files=$(grep -rsl '@Composable' "$proj_dir" --include='*.kt' 2>/dev/null || true)
    if [[ -n "$compose_files" ]]; then
        compose_count=$(echo "$compose_files" | wc -l)
        compose_count="${compose_count//[[:space:]]/}"
    fi

    # Count XML layout files
    local xml_files
    xml_files=$(find "$proj_dir" -maxdepth 6 -path '*/res/layout/*.xml' -type f 2>/dev/null || true)
    if [[ -n "$xml_files" ]]; then
        xml_count=$(echo "$xml_files" | wc -l)
        xml_count="${xml_count//[[:space:]]/}"
    fi

    # Determine majority framework
    if [[ "$compose_count" -gt 0 ]] && [[ "$compose_count" -ge "$xml_count" ]]; then
        # Compose project — check for Material3 vs Material
        _detect_android_material_version
    elif [[ "$xml_count" -gt 0 ]]; then
        DESIGN_SYSTEM="xml-layouts"
        _detect_android_material_version_xml
    fi
}

# --- Material version detection (Compose) -------------------------------------

_detect_android_material_version() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Check build.gradle / build.gradle.kts for material3 dependency
    local gradle_files
    gradle_files=$(find "$proj_dir" -maxdepth 3 -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' \) 2>/dev/null || true)

    if [[ -n "$gradle_files" ]]; then
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] && grep -lqE 'material3|compose-material3|androidx.compose.material3' "$f" 2>/dev/null && {
                DESIGN_SYSTEM="material3"
                return
            }
        done <<< "$gradle_files"
        while IFS= read -r f; do
            [[ -n "$f" ]] && grep -lqE 'compose-material\b|androidx.compose.material\b' "$f" 2>/dev/null && {
                DESIGN_SYSTEM="material"
                return
            }
        done <<< "$gradle_files"
    fi

    # Fallback: set to compose if we can't determine material version
    DESIGN_SYSTEM="compose"
}

# --- Material version detection (XML layouts) ---------------------------------

_detect_android_material_version_xml() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Check for Material dependency in Gradle
    local gradle_files
    gradle_files=$(find "$proj_dir" -maxdepth 3 -type f \( -name 'build.gradle' -o -name 'build.gradle.kts' \) 2>/dev/null || true)

    if [[ -n "$gradle_files" ]]; then
        local f
        while IFS= read -r f; do
            [[ -n "$f" ]] && grep -lqE 'com.google.android.material:material' "$f" 2>/dev/null && {
                DESIGN_SYSTEM="material"
                return
            }
        done <<< "$gradle_files"
    fi

    # Check themes.xml / styles.xml for Material theme references
    local themes_file
    themes_file=$(find "$proj_dir" -maxdepth 6 -path '*/res/values/themes.xml' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$themes_file" ]] && grep -q 'Theme.Material3\|Theme.MaterialComponents' "$themes_file" 2>/dev/null; then
        if grep -q 'Theme.Material3' "$themes_file" 2>/dev/null; then
            DESIGN_SYSTEM="material3"
        else
            DESIGN_SYSTEM="material"
        fi
    fi
}

# --- Theme config file detection ----------------------------------------------

_detect_android_theme_config() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Look for Compose theme files: Theme.kt, Color.kt, Type.kt
    local theme_file
    theme_file=$(find "$proj_dir" -maxdepth 6 -type f -name 'Theme.kt' 2>/dev/null | head -1 || true)
    if [[ -n "$theme_file" ]]; then
        DESIGN_SYSTEM_CONFIG="$theme_file"
        return
    fi

    # Fallback: look for themes.xml
    local themes_xml
    themes_xml=$(find "$proj_dir" -maxdepth 6 -path '*/res/values/themes.xml' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$themes_xml" ]]; then
        DESIGN_SYSTEM_CONFIG="$themes_xml"
        return
    fi

    # Fallback: styles.xml
    local styles_xml
    styles_xml=$(find "$proj_dir" -maxdepth 6 -path '*/res/values/styles.xml' -type f 2>/dev/null | head -1 || true)
    if [[ -n "$styles_xml" ]]; then
        DESIGN_SYSTEM_CONFIG="$styles_xml"
    fi
}

# --- Component directory detection --------------------------------------------

_detect_android_component_dir() {
    local proj_dir="${PROJECT_DIR:-.}"

    # Search for common Android component directories
    local candidate
    candidate=$(find "$proj_dir" -maxdepth 5 -type d \( \
        -name 'composables' -o -name 'components' -o -name 'screens' \
    \) 2>/dev/null | head -1 || true)
    if [[ -n "$candidate" ]]; then
        COMPONENT_LIBRARY_DIR="$candidate"
        return
    fi

    # Look for ui/ package directory containing Kotlin files
    local ui_dirs
    ui_dirs=$(find "$proj_dir" -maxdepth 5 -type d -name 'ui' 2>/dev/null || true)
    if [[ -n "$ui_dirs" ]]; then
        local d
        while IFS= read -r d; do
            if [[ -n "$d" ]] && find "$d" -maxdepth 1 -name '*.kt' -type f 2>/dev/null | grep -q .; then
                COMPONENT_LIBRARY_DIR="$d"
                return
            fi
        done <<< "$ui_dirs"
    fi
}

# --- Run detection ------------------------------------------------------------

_detect_android_ui_framework
_detect_android_theme_config
_detect_android_component_dir
