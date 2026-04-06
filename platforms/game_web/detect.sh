#!/usr/bin/env bash
# =============================================================================
# platforms/game_web/detect.sh — Browser-based game engine detection
#
# Sourced by source_platform_detect() from _base.sh. Sets:
#   DESIGN_SYSTEM          — Engine name: phaser, pixi, three, or babylon
#   DESIGN_SYSTEM_CONFIG   — Path to game config file (if identifiable)
#   COMPONENT_LIBRARY_DIR  — Path to scenes/levels directory
#
# Depends on: detect.sh (_extract_json_keys, _check_dep) already loaded,
#             PROJECT_DIR set by caller
# =============================================================================
# shellcheck disable=SC2034  # Variables used by caller via export
set -euo pipefail

# --- Engine detection ---------------------------------------------------------

_detect_game_engine() {
    local proj_dir="${PROJECT_DIR:-.}"
    local pkg="${proj_dir}/package.json"
    local deps=""

    if [[ -f "$pkg" ]]; then
        deps=$(_extract_json_keys "$pkg" '"dependencies"' '"devDependencies"')
    fi

    if [[ -z "$deps" ]]; then
        return
    fi

    # Check for game engines in package.json dependencies
    if _check_dep "$deps" '"phaser"'; then
        DESIGN_SYSTEM="phaser"
    elif _check_dep "$deps" '"pixi.js"' || _check_dep "$deps" '"@pixi/'; then
        DESIGN_SYSTEM="pixi"
    elif _check_dep "$deps" '"three"'; then
        DESIGN_SYSTEM="three"
    elif _check_dep "$deps" '"@babylonjs/core"'; then
        DESIGN_SYSTEM="babylon"
    fi
}

# --- Game config file detection -----------------------------------------------

_detect_game_config() {
    local proj_dir="${PROJECT_DIR:-.}"

    if [[ -z "${DESIGN_SYSTEM:-}" ]]; then
        return
    fi

    local _game_matches=""

    case "$DESIGN_SYSTEM" in
        phaser)
            # Look for Phaser.Game config
            _game_matches=$(grep -rsl 'new Phaser\.Game\|new Game(' "$proj_dir/src" --include='*.ts' --include='*.js' 2>/dev/null || true)
            if [[ -z "$_game_matches" ]]; then
                _game_matches=$(grep -rsl 'new Phaser\.Game\|new Game(' "$proj_dir" --include='*.ts' --include='*.js' 2>/dev/null || true)
            fi
            ;;
        three)
            _game_matches=$(grep -rsl 'new THREE\.Scene\|new Scene(' "$proj_dir/src" --include='*.ts' --include='*.js' 2>/dev/null || true)
            ;;
        babylon)
            _game_matches=$(grep -rsl 'new BABYLON\.Scene\|new Scene(' "$proj_dir/src" --include='*.ts' --include='*.js' 2>/dev/null || true)
            ;;
        pixi)
            _game_matches=$(grep -rsl 'new PIXI\.Application\|new Application(' "$proj_dir/src" --include='*.ts' --include='*.js' 2>/dev/null || true)
            ;;
    esac

    if [[ -n "$_game_matches" ]]; then
        DESIGN_SYSTEM_CONFIG=$(echo "$_game_matches" | head -1)
    fi
}

# --- Scene / level directory detection ----------------------------------------

_detect_game_scene_dir() {
    local proj_dir="${PROJECT_DIR:-.}"
    local candidate
    local candidates=(
        "src/scenes"
        "src/levels"
        "src/states"
        "scenes"
        "levels"
        "states"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -d "${proj_dir}/${candidate}" ]]; then
            COMPONENT_LIBRARY_DIR="${proj_dir}/${candidate}"
            return
        fi
    done
}

# --- Run detection ------------------------------------------------------------

_detect_game_engine
_detect_game_config
_detect_game_scene_dir
