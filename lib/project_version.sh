#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# project_version.sh — Target-project version file detection and config cache
#
# Sourced by tekhton.sh — do not run directly.
# Provides:
#   detect_project_version_files  — scan for version files, write config cache
#   parse_current_version         — read cached version string
#   _read_version_config          — read a key from the version config file
#   _write_version_config         — update a key in the version config file
#   _detect_version_from_file     — extract version from a single file
#   _accessor_for_file            — map filename to accessor type
#   _default_version_for_strategy — initial version when no version file exists
# =============================================================================

# _default_version_for_strategy
#   Pick an initial version for projects with no version file.
_default_version_for_strategy() {
    case "${PROJECT_VERSION_STRATEGY:-semver}" in
        milestone) echo "0.0.0" ;;
        *)         echo "0.1.0" ;;
    esac
}

# _detect_version_from_file FILE ACCESSOR
#   Extract version string from a file using the given accessor method.
#   Returns 1 if no version found.
_detect_version_from_file() {
    local file="$1"
    local accessor="$2"

    [[ ! -f "$file" ]] && return 1

    local ver=""
    case "$accessor" in
        json)
            # m10 cutover: drop python3 dependency. We only need the
            # top-level "version" string from package.json / composer.json
            # and the like — pure grep + sed handles every shape we've
            # seen in the wild (single-line, indented, mixed quoting).
            ver=$(grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' -- "$file" 2>/dev/null \
                  | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/' || true)
            ;;
        toml_version)
            ver=$(grep -E '^version\s*=\s*"[^"]+"' -- "$file" 2>/dev/null \
                  | head -1 | sed 's/.*"\([^"]*\)".*/\1/' || true)
            ;;
        py_version)
            ver=$(grep -E "version\s*=\s*['\"][^'\"]+['\"]" -- "$file" 2>/dev/null \
                  | head -1 | sed "s/.*['\"]\\([^'\"]*\\)['\"].*/\\1/" || true)
            ;;
        cfg_version)
            ver=$(grep -E '^version\s*=\s*[0-9]' -- "$file" 2>/dev/null \
                  | head -1 | sed 's/version\s*=\s*//' | tr -d '[:space:]' || true)
            ;;
        yaml_version)
            ver=$(grep -E '^version:\s*[0-9]' -- "$file" 2>/dev/null \
                  | head -1 | sed 's/version:\s*//' | tr -d '[:space:]' || true)
            ;;
        plaintext)
            ver=$(tr -d '[:space:]' < "$file" 2>/dev/null || true)
            ;;
    esac

    [[ -z "$ver" ]] && return 1
    echo "$ver"
}

# _accessor_for_file FILENAME
#   Map a version filename to its accessor type.
_accessor_for_file() {
    local basename
    basename=$(basename "$1")
    case "$basename" in
        package.json|composer.json) echo "json" ;;
        pyproject.toml|Cargo.toml)  echo "toml_version" ;;
        setup.py)                   echo "py_version" ;;
        setup.cfg|gradle.properties) echo "cfg_version" ;;
        Chart.yaml|pubspec.yaml)    echo "yaml_version" ;;
        VERSION)                    echo "plaintext" ;;
        *)                          echo "plaintext" ;;
    esac
}

# detect_project_version_files
#   Scans $PROJECT_DIR for known version files. Writes the list +
#   current version to $PROJECT_VERSION_CONFIG. Idempotent — skips if
#   config already exists.
detect_project_version_files() {
    [[ "${PROJECT_VERSION_ENABLED:-true}" != "true" ]] && return 0
    [[ "${PROJECT_VERSION_AUTO_DETECT:-true}" != "true" ]] && return 0

    local project_dir="${PROJECT_DIR:-.}"
    local config_file="${project_dir}/${PROJECT_VERSION_CONFIG:-.claude/project_version.cfg}"

    # Idempotent: skip if config already exists
    if [[ -f "$config_file" ]]; then
        return 0
    fi

    # Ecosystems: file:accessor:path_key (ordered by detection priority)
    # Note: path_key is stored in VERSION_FILES but not consumed by bump logic
    # (_bump_single_file re-derives the accessor via _accessor_for_file).
    # Reserved for a future structured-read accessor.
    local -a ecosystems=(
        "package.json:json:.version"
        "pyproject.toml:toml_version:.project.version"
        "Cargo.toml:toml_version:.package.version"
        "setup.py:py_version:.version"
        "setup.cfg:cfg_version:.version"
        "gradle.properties:cfg_version:.version"
        "Chart.yaml:yaml_version:.version"
        "composer.json:json:.version"
        "pubspec.yaml:yaml_version:.version"
        "VERSION:plaintext:."
    )

    local version_files=""
    local current_version=""
    local detected=false

    for entry in "${ecosystems[@]}"; do
        local file="${entry%%:*}"
        local rest="${entry#*:}"
        local accessor="${rest%%:*}"
        local path_key="${rest#*:}"

        local ver
        ver=$(_detect_version_from_file "${project_dir}/${file}" "$accessor") || continue

        version_files="${version_files:+${version_files};}${file}:${path_key}"
        current_version="${current_version:-$ver}"
        detected=true
    done

    # If none found, create VERSION file as source of truth
    if [[ "$detected" != true ]]; then
        current_version=$(_default_version_for_strategy)
        echo "$current_version" > "${project_dir}/VERSION"
        version_files="VERSION:."
        if command -v log &>/dev/null; then
            log "No version file found — created VERSION with ${current_version}"
        fi
    fi

    # Ensure config directory exists
    local config_dir
    config_dir=$(dirname "$config_file")
    mkdir -p "$config_dir"

    # Write config cache
    cat > "$config_file" <<EOF
VERSION_STRATEGY=${PROJECT_VERSION_STRATEGY:-semver}
VERSION_FILES=${version_files}
CURRENT_VERSION=${current_version}
EOF

    if command -v log &>/dev/null; then
        log "Detected project version: ${current_version} (strategy: ${PROJECT_VERSION_STRATEGY:-semver})"
    fi
}

# parse_current_version
#   Reads $PROJECT_VERSION_CONFIG and emits the current version string.
#   Returns empty string if config doesn't exist.
parse_current_version() {
    _read_version_config "CURRENT_VERSION"
}

# _read_version_config KEY
#   Read a key from the version config file.
_read_version_config() {
    local key="$1"
    local project_dir="${PROJECT_DIR:-.}"
    local config_file="${project_dir}/${PROJECT_VERSION_CONFIG:-.claude/project_version.cfg}"

    [[ ! -f "$config_file" ]] && return 0

    grep -- "^${key}=" "$config_file" | head -1 | sed "s/^${key}=//" || true
}

# _write_version_config KEY VALUE
#   Update a key in the version config file.
_write_version_config() {
    local key="$1"
    local value="$2"
    local project_dir="${PROJECT_DIR:-.}"
    local config_file="${project_dir}/${PROJECT_VERSION_CONFIG:-.claude/project_version.cfg}"

    [[ ! -f "$config_file" ]] && return 1

    if grep -q -- "^${key}=" "$config_file"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$config_file"
    else
        echo "${key}=${value}" >> "$config_file"
    fi
}
