#!/usr/bin/env bash
# =============================================================================
# project_version_bump_helpers.sh — Per-file bump logic + multi-file parsing
#
# Sourced by tekhton.sh after lib/project_version_bump.sh — do not run directly.
# Provides:
#   _parse_version_files_list   — split VERSION_FILES into path:selector entries
#                                  (m43 — supports `;` and newline separators)
#   _bump_single_file           — write the new version into a single file
#   _bump_json_version          — format-preserving JSON `"version"` field edit
#                                  (m43 — replaces the reserialize-the-file
#                                  python3 path)
# =============================================================================

# _parse_version_files_list LIST [OUT_VAR]
#   Parse the VERSION_FILES config value into an array of `path:selector`
#   entries. Accepts both `;`-separated and newline-separated forms (or a
#   mix). Trims surrounding whitespace and skips empty entries.
#   When OUT_VAR is given, the parsed entries are written there via nameref;
#   otherwise the entries are printed one per line to stdout (with no
#   trailing blank line) so callers can `readarray`.
_parse_version_files_list() {
    local raw="${1:-}"
    local _out_name="${2:-}"
    [[ -z "$raw" ]] && return 0

    # Normalise both separators to a single newline; let read split on \n.
    local normalised="${raw//;/$'\n'}"

    local -a _entries=()
    local line trimmed
    while IFS= read -r line; do
        trimmed="${line#"${line%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -z "$trimmed" ]] && continue
        _entries+=("$trimmed")
    done <<< "$normalised"

    if [[ -n "$_out_name" ]]; then
        local -n _ref="$_out_name"
        _ref=("${_entries[@]}")
        return 0
    fi

    local entry
    for entry in "${_entries[@]}"; do
        printf '%s\n' "$entry"
    done
}

# _bump_json_version FILE OLD_VERSION NEW_VERSION
#   Replace the top-level `"version": "X"` field in a JSON file with the new
#   version. Format-preserving: only the matched line is touched; key order,
#   indentation, and trailing whitespace are left alone. Safe across both
#   `"version":` and `"version" :` spacing, single-line files
#   (`{"version":"X"}`), and indented multi-line forms (`  "version": "X",`).
#   Returns silently if no `"version"` field is found or the old value
#   doesn't match — the post-bump verify step is the source of truth for
#   "did this actually update".
_bump_json_version() {
    local file="$1"
    local old_version="$2"
    local new_version="$3"

    [[ ! -f "$file" ]] && return 0

    local escaped_old
    escaped_old=$(printf '%s' "$old_version" | sed 's/[][\\.^$*/]/\\&/g')

    sed -i.bak \
        -e "s|\"version\"[[:space:]]*:[[:space:]]*\"${escaped_old}\"|\"version\": \"${new_version}\"|" \
        "$file"
    rm -f "${file}.bak"
}

# _bump_single_file FILE OLD_VERSION NEW_VERSION
#   Write the new version into a single version file. Selector hint comes
#   from the basename; JSON dotfiles go through _bump_json_version so we
#   don't reserialise the whole file.
_bump_single_file() {
    local file="$1"
    local old_version="$2"
    local new_version="$3"

    [[ ! -f "$file" ]] && return 0

    local basename
    basename=$(basename "$file")

    local escaped_old
    escaped_old=$(printf '%s' "$old_version" | sed 's/\./\\./g')

    case "$basename" in
        package.json|composer.json)
            _bump_json_version "$file" "$old_version" "$new_version"
            ;;
        pyproject.toml|Cargo.toml)
            sed -i.bak \
                -e "s|^\\(version\\s*=\\s*'\\)${escaped_old}'|\1${new_version}'|" \
                -e "s|^\\(version\\s*=\\s*\"\\)${escaped_old}\"|\1${new_version}\"|" \
                "$file"
            rm -f "${file}.bak"
            ;;
        setup.py)
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
        *)
            # Fall through: unknown basename. Last-ditch effort — try JSON
            # if the file looks like JSON (first non-space char is '{').
            local first
            first=$(head -c 1 -- "$file" 2>/dev/null || true)
            if [[ "$first" == "{" ]]; then
                _bump_json_version "$file" "$old_version" "$new_version"
            fi
            ;;
    esac
}
