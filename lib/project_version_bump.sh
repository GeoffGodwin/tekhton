#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# project_version_bump.sh — Version bump logic and file writes
#
# Sourced by tekhton.sh — do not run directly.
# Expects: lib/project_version.sh sourced first.
# Provides:
#   compute_next_version  — pure function: current + strategy + bump → next
#   get_version_bump_hint — read CODER_SUMMARY.md for disposition hints
#   bump_version_files    — write bumped version to all detected files
# =============================================================================

# compute_next_version CURRENT STRATEGY BUMP_TYPE
#   Pure function — no I/O. Computes the next version string.
compute_next_version() {
    local current="$1"
    local strategy="$2"
    local bump_type="$3"

    case "$strategy" in
        semver)
            local major minor patch
            IFS='.' read -r major minor patch <<< "$current"
            major="${major:-0}"; minor="${minor:-0}"; patch="${patch:-0}"
            # Strip any non-numeric suffix (e.g., -rc.1)
            patch="${patch%%[^0-9]*}"

            case "$bump_type" in
                major) echo "$((major + 1)).0.0" ;;
                minor) echo "${major}.$((minor + 1)).0" ;;
                patch|*) echo "${major}.${minor}.$((patch + 1))" ;;
            esac
            ;;
        calver)
            local today_year today_month
            today_year=$(date +%Y)
            today_month=$(date +%-m)

            local cur_year cur_month cur_patch
            IFS='.' read -r cur_year cur_month cur_patch <<< "$current"
            cur_patch="${cur_patch:-0}"

            if [[ "$cur_year" == "$today_year" ]] && [[ "$cur_month" == "$today_month" ]]; then
                echo "${today_year}.${today_month}.$((cur_patch + 1))"
            else
                echo "${today_year}.${today_month}.0"
            fi
            ;;
        datestamp)
            date +%Y-%m-%d
            ;;
        none)
            echo "$current"
            ;;
        *)
            echo "$current"
            ;;
    esac
}

# get_version_bump_hint
#   Reads CODER_SUMMARY.md for disposition hints.
#   Returns: major, minor, or $PROJECT_VERSION_DEFAULT_BUMP (default: patch)
get_version_bump_hint() {
    local summary_file="${CODER_SUMMARY_FILE:-${TEKHTON_DIR:-.tekhton}/CODER_SUMMARY.md}"
    local project_dir="${PROJECT_DIR:-.}"
    local full_path="${project_dir}/${summary_file}"

    if [[ ! -f "$full_path" ]]; then
        echo "${PROJECT_VERSION_DEFAULT_BUMP:-patch}"
        return 0
    fi

    # ## Breaking Changes → major
    if grep -q '^## Breaking Changes' -- "$full_path" 2>/dev/null; then
        echo "major"
        return 0
    fi

    # ## New Public Surface → minor
    if grep -q '^## New Public Surface' -- "$full_path" 2>/dev/null; then
        echo "minor"
        return 0
    fi

    echo "${PROJECT_VERSION_DEFAULT_BUMP:-patch}"
}

# bump_version_files BUMP_TYPE
#   Write the bumped version to all detected version files.
#   Guarded by user-pre-bump detection (Design Decision #5).
bump_version_files() {
    local bump_type="$1"
    [[ "${PROJECT_VERSION_ENABLED:-true}" != "true" ]] && return 0

    local project_dir="${PROJECT_DIR:-.}"
    local config_file="${project_dir}/${PROJECT_VERSION_CONFIG:-.claude/project_version.cfg}"

    [[ ! -f "$config_file" ]] && return 0

    local strategy
    strategy=$(_read_version_config "VERSION_STRATEGY")
    [[ "$strategy" == "none" ]] && return 0

    local cached_version
    cached_version=$(_read_version_config "CURRENT_VERSION")
    [[ -z "$cached_version" ]] && return 0

    local version_files_str
    version_files_str=$(_read_version_config "VERSION_FILES")
    [[ -z "$version_files_str" ]] && return 0

    # User pre-bump detection: read actual version from first file
    local first_entry="${version_files_str%%;*}"
    local first_file="${first_entry%%:*}"
    local first_accessor
    first_accessor=$(_accessor_for_file "$first_file")
    local actual_version
    actual_version=$(_detect_version_from_file "${project_dir}/${first_file}" "$first_accessor") || actual_version=""

    if [[ -n "$actual_version" ]] && [[ "$actual_version" != "$cached_version" ]]; then
        if command -v warn &>/dev/null; then
            warn "User bumped ${cached_version} → ${actual_version}, updating cache"
        fi
        _write_version_config "CURRENT_VERSION" "$actual_version"
        return 0
    fi

    local next_version
    next_version=$(compute_next_version "$cached_version" "$strategy" "$bump_type")

    [[ "$next_version" == "$cached_version" ]] && return 0

    # Bump each detected version file
    IFS=';' read -ra entries <<< "$version_files_str"
    for entry in "${entries[@]}"; do
        local file="${entry%%:*}"
        _bump_single_file "${project_dir}/${file}" "$cached_version" "$next_version"
    done

    # Update cache
    _write_version_config "CURRENT_VERSION" "$next_version"

    # Expose bump details for the Pipeline Complete banner (M96 IA2).
    _BUMPED_VERSION_OLD="$cached_version"
    _BUMPED_VERSION_NEW="$next_version"
    _BUMPED_VERSION_TYPE="$bump_type"
    export _BUMPED_VERSION_OLD _BUMPED_VERSION_NEW _BUMPED_VERSION_TYPE

    if command -v log &>/dev/null; then
        log "Bumped project version: ${cached_version} → ${next_version} (${bump_type})"
    fi
}

# _bump_single_file FILE OLD_VERSION NEW_VERSION
#   Write the new version into a single version file.
_bump_single_file() {
    local file="$1"
    local old_version="$2"
    local new_version="$3"

    [[ ! -f "$file" ]] && return 0

    local basename
    basename=$(basename "$file")

    # Escape dots in old_version for sed regex
    local escaped_old
    escaped_old=$(printf '%s' "$old_version" | sed 's/\./\\./g')

    case "$basename" in
        package.json|composer.json)
            python3 -c "
import json, sys
with open(sys.argv[1], 'r') as f:
    d = json.load(f)
if d.get('version') == sys.argv[2]:
    d['version'] = sys.argv[3]
    with open(sys.argv[1], 'w') as f:
        json.dump(d, f, indent=2)
        f.write('\n')
" "$file" "$old_version" "$new_version" 2>/dev/null || true
            ;;
        pyproject.toml|Cargo.toml)
            # Two patterns: one for single-quoted, one for double-quoted,
            # so the replacement preserves the original quote style.
            sed -i.bak \
                -e "s|^\\(version\\s*=\\s*'\\)${escaped_old}'|\1${new_version}'|" \
                -e "s|^\\(version\\s*=\\s*\"\\)${escaped_old}\"|\1${new_version}\"|" \
                "$file"
            rm -f "${file}.bak"
            ;;
        setup.py)
            # Two patterns: one for single-quoted, one for double-quoted,
            # so the replacement preserves the original quote style.
            sed -i.bak \
                -e "s|\\(version\\s*=\\s*'\\)${escaped_old}'|\\1${new_version}'|" \
                -e "s|\\(version\\s*=\\s*\"\\)${escaped_old}\"|\\1${new_version}\"|" \
                "$file"
            rm -f "${file}.bak"
            ;;
        setup.cfg|gradle.properties)
            sed -i.bak "s|^\\(version\\s*=\\s*\\)${escaped_old}|\\1${new_version}|" "$file"
            rm -f "${file}.bak"
            ;;
        Chart.yaml|pubspec.yaml)
            sed -i.bak "s|^\\(version:\\s*\\)${escaped_old}|\\1${new_version}|" "$file"
            rm -f "${file}.bak"
            ;;
        VERSION)
            echo "$new_version" > "$file"
            ;;
    esac
}
