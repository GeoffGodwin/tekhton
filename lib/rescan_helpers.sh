#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# rescan_helpers.sh — Helper functions for incremental rescan (Milestone 20)
#
# Provides: changed file detection, significance classification, section
# replacement, metadata management, and file-type helpers.
#
# Sourced by rescan.sh — do not run directly.
# Depends on: common.sh (log), crawler.sh (_list_tracked_files)
# =============================================================================

# --- Changed file detection ---------------------------------------------------

# _get_changed_files_since_scan — Lists files changed since the recorded scan commit.
# Uses git diff for committed changes and git status for working tree changes.
# Args: $1 = project directory, $2 = last scan commit hash
# Output: One line per file: STATUS\tFILENAME (or STATUS\tOLD\tNEW for renames)
_get_changed_files_since_scan() {
    local project_dir="$1"
    local last_scan_commit="$2"

    # Committed changes since the scan commit
    local committed_changes
    committed_changes=$(git -C "$project_dir" diff --name-status \
        "${last_scan_commit}..HEAD" 2>/dev/null || true)

    # Working tree changes (uncommitted)
    local working_changes
    working_changes=$(git -C "$project_dir" status --porcelain 2>/dev/null | \
        awk '{
            status = substr($0, 1, 2)
            file = substr($0, 4)
            # Map porcelain status to diff-style status
            if (status ~ /^\?\?/) print "A\t" file
            else if (status ~ /^.D/ || status ~ /^D/) print "D\t" file
            else if (status ~ /^.M/ || status ~ /^M/) print "M\t" file
            else if (status ~ /^A/) print "A\t" file
            else if (status ~ /^R/) print "R\t" file
        }' || true)

    # Merge both, deduplicate by filename (working tree wins)
    {
        [[ -n "$committed_changes" ]] && echo "$committed_changes"
        [[ -n "$working_changes" ]] && echo "$working_changes"
    } | awk -F'\t' '!seen[$NF]++' || true
}

# --- Significance detection ---------------------------------------------------

# _detect_significant_changes — Classifies change impact on project structure.
# Args: $1 = changed files (STATUS\tFILENAME format)
# Output: "trivial", "moderate", or "major"
_detect_significant_changes() {
    local changed_files="$1"
    local significance="trivial"

    local new_dirs=0 deleted_files=0 manifest_changes=0

    while IFS=$'\t' read -r status filepath rest; do
        [[ -z "$status" ]] && continue

        case "$status" in
            D*)
                deleted_files=$(( deleted_files + 1 ))
                if _is_manifest_file "$filepath"; then
                    manifest_changes=$(( manifest_changes + 1 ))
                fi
                ;;
            A*)
                local dir
                dir=$(dirname "$filepath")
                if [[ "$dir" != "." ]]; then
                    new_dirs=$(( new_dirs + 1 ))
                fi
                if _is_manifest_file "$filepath"; then
                    manifest_changes=$(( manifest_changes + 1 ))
                fi
                ;;
            M*)
                if _is_manifest_file "$filepath"; then
                    manifest_changes=$(( manifest_changes + 1 ))
                fi
                ;;
            R*)
                if [[ -n "$rest" ]]; then
                    local old_dir new_dir
                    old_dir=$(dirname "$filepath")
                    new_dir=$(dirname "$rest")
                    if [[ "$old_dir" != "$new_dir" ]]; then
                        new_dirs=$(( new_dirs + 1 ))
                    fi
                fi
                ;;
        esac
    done <<< "$changed_files"

    if [[ "$manifest_changes" -ge 2 ]] || [[ "$new_dirs" -ge 5 ]] || [[ "$deleted_files" -ge 10 ]]; then
        significance="major"
    elif [[ "$manifest_changes" -ge 1 ]] || [[ "$new_dirs" -ge 1 ]]; then
        significance="moderate"
    fi

    echo "$significance"
}

# --- Metadata management -----------------------------------------------------

# _extract_scan_metadata — Reads a metadata field from structured index or
# $PROJECT_INDEX_FILE header. Prefers .claude/index/meta.json (M68), falls back
# to HTML comment parsing for legacy projects.
# Args: $1 = index file path, $2 = field name (e.g., "Scan-Commit")
# Output: Field value or empty string
_extract_scan_metadata() {
    local index_file="$1"
    local field="$2"
    local project_dir
    project_dir=$(dirname "$index_file")
    local meta_file="${project_dir}/.claude/index/meta.json"

    # Prefer structured data (M68)
    if [[ -f "$meta_file" ]]; then
        local json_field=""
        case "$field" in
            Scan-Commit) json_field="scan_commit" ;;
            Last-Scan)   json_field="scan_date" ;;
            File-Count)  json_field="file_count" ;;
            Total-Lines) json_field="total_lines" ;;
        esac
        if [[ -n "$json_field" ]]; then
            local value
            value=$(grep "\"${json_field}\"" "$meta_file" 2>/dev/null | \
                sed 's/.*: *"\{0,1\}\([^",}]*\)"\{0,1\}.*/\1/' | tr -d '[:space:]' || true)
            if [[ -n "$value" ]]; then
                printf '%s' "$value"
                return
            fi
        fi
    fi

    # Legacy fallback: parse HTML comments from markdown
    grep "<!-- ${field}:" "$index_file" 2>/dev/null | \
        sed "s/.*<!-- ${field}: *\(.*\) *-->.*/\1/" | \
        tr -d '[:space:]' || true
}

# _record_scan_metadata — Updates scan metadata in meta.json.
# M69: the view generator reads meta.json and renders fresh HTML comments,
# so we only need to update the structured data. Callers regenerate the view.
# Args: $1 = index file (unused after M69, kept for backward compat), $2 = project directory
_record_scan_metadata() {
    local _index_file="$1"
    local project_dir="$2"

    # Update meta.json with current scan info — view will be regenerated by caller
    _emit_meta_json "$project_dir" "${project_dir}/.claude/index" "0"
}

# --- File-type helpers --------------------------------------------------------

# _is_manifest_file — Checks if a filename is a dependency manifest.
_is_manifest_file() {
    local filepath="$1"
    local basename
    basename=$(basename "$filepath")
    case "$basename" in
        package.json|Cargo.toml|go.mod|pyproject.toml|requirements.txt|\
        setup.py|Pipfile|Gemfile|composer.json|pubspec.yaml|Package.swift|\
        mix.exs|build.gradle|build.gradle.kts|pom.xml|*.csproj|*.sln|\
        stack.yaml|cabal.project|Makefile)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# _is_config_file — Checks if a filename is a configuration file.
_is_config_file() {
    local filepath="$1"
    local basename
    basename=$(basename "$filepath")
    case "$basename" in
        *.conf|*.cfg|*.ini|*.toml|*.yaml|*.yml|*.json|*.env|*.env.*|\
        .eslintrc*|.prettierrc*|.babelrc*|webpack.config.*|\
        rollup.config.*|vite.config.*|jest.config.*|.editorconfig|\
        Dockerfile|docker-compose*|.dockerignore|.gitignore|.gitattributes)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

# _extract_sampled_files — Lists file paths currently sampled in the index.
# M68: prefers samples/manifest.json, falls back to legacy markdown parsing
# with corrected regex (no backtick — headings are ### filename not ### `filename`).
# Args: $1 = index file
_extract_sampled_files() {
    local index_file="$1"
    local project_dir
    project_dir=$(dirname "$index_file")
    local manifest="${project_dir}/.claude/index/samples/manifest.json"

    if [[ -f "$manifest" ]]; then
        # Extract "original" field values from manifest JSON
        grep '"original"' "$manifest" 2>/dev/null | \
            sed 's/.*"original": *"\([^"]*\)".*/\1/' || true
        return
    fi

    # Legacy fallback (fixed regex — no backtick; headings are ### filename)
    grep '^### ' "$index_file" 2>/dev/null | \
        sed 's/^### //' | sed 's/`//g' || true
}
