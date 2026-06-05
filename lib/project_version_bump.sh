#!/usr/bin/env bash
# =============================================================================
# project_version_bump.sh — Version bump logic and file writes
#
# Sourced by tekhton.sh — do not run directly.
# Expects: lib/project_version.sh sourced first.
# Self-sources lib/project_version_bump_helpers.sh (per-file write helpers
# + multi-file VERSION_FILES parser) so bump_version_files is callable from
# any context that has the bump shim sourced.
# Post-bump verify lives in lib/project_version_verify.sh and is sourced
# separately at the top-level (call site detects it via command -v).
# Provides:
#   compute_next_version  — pure function: current + strategy + bump → next
#   get_version_bump_hint — read CODER_SUMMARY.md for disposition hints
#   bump_version_files    — write bumped version to all detected files,
#                           then run the post-bump consistency self-check
#   _max_done_milestone_in_manifest — highest numeric milestone with
#                                     status=done in MANIFEST.cfg (#45)
# =============================================================================

# Self-source the per-file write helpers + multi-file parser. Idempotent —
# guarded by a sentinel so multiple sources (e.g. tekhton-legacy.sh + a
# direct test source) don't re-execute the body.
if [[ -z "${_PROJECT_VERSION_BUMP_HELPERS_SOURCED:-}" ]]; then
    # shellcheck source=lib/project_version_bump_helpers.sh
    source "$(dirname -- "${BASH_SOURCE[0]}")/project_version_bump_helpers.sh"
    _PROJECT_VERSION_BUMP_HELPERS_SOURCED=1
fi

# _max_done_milestone_in_manifest [PROJECT_DIR]
# Returns the highest numeric milestone ID with status=done in
# .claude/milestones/MANIFEST.cfg (without the leading "m"). Used by
# compute_next_version's milestone branch to anchor MINOR to the true
# high-water-mark in the manifest rather than the value currently in
# VERSION (which can drift due to PATCH bumps from non-milestone runs or
# from being reset by an earlier milestone completing after a later one).
#
# Echoes 0 when no done milestones are found, the manifest is missing,
# or anything goes wrong — caller treats 0 as "no floor", which is the
# safe degradation for greenfield repos.
_max_done_milestone_in_manifest() {
    local proj="${PROJECT_DIR:-.}"
    local manifest="${proj}/.claude/milestones/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
    if [[ -n "${MILESTONE_DIR:-}" ]]; then
        manifest="${MILESTONE_DIR:-.claude/milestones}/${MILESTONE_MANIFEST:-MANIFEST.cfg}"
    fi
    [[ -f "$manifest" ]] || { echo 0; return 0; }
    # Format: id|title|status|depends_on|file|parallel_group
    # We only want top-level integer IDs (m23, not m05.1) with status=done.
    awk -F'|' '
        /^m[0-9]+\|/ && $3 == "done" {
            id = $1
            sub(/^m/, "", id)
            if (id ~ /^[0-9]+$/ && (id+0) > max) max = id+0
        }
        END { print (max+0) }
    ' "$manifest" 2>/dev/null || echo 0
}

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
        milestone)
            local major minor patch target_milestone
            IFS='.' read -r major minor patch <<< "$current"
            major="${major:-0}"
            minor="${minor:-0}"
            patch="${patch:-0}"
            patch="${patch%%[^0-9]*}"

            case "$bump_type" in
                milestone:*)
                    target_milestone="${bump_type#milestone:}"
                    if [[ "$target_milestone" =~ ^[0-9]+$ ]]; then
                        # MINOR must reflect the highest completed milestone
                        # in MANIFEST.cfg, NOT just the value currently in
                        # VERSION (#45). The earlier half-fix guarded
                        # against MINOR regression using current-minor as
                        # the floor — but VERSION can DRIFT below ground
                        # truth if PATCH bumps happened while a real
                        # higher milestone sat done in the manifest. The
                        # high-water-mark check restores ground truth.
                        local _hwm
                        _hwm=$(_max_done_milestone_in_manifest)
                        # new_minor = max(target, hwm, current_minor).
                        # All three are floors; the highest wins.
                        local _new_minor="$target_milestone"
                        if [[ "$_hwm" -gt "$_new_minor" ]]; then
                            _new_minor="$_hwm"
                        fi
                        if [[ "$minor" -gt "$_new_minor" ]]; then
                            _new_minor="$minor"
                        fi
                        if [[ "$_new_minor" -gt "$minor" ]]; then
                            # MINOR advanced — clean bump, reset PATCH.
                            # Covers both "target>floor" (new milestone)
                            # and "self-heal" (target<=hwm but VERSION
                            # drifted below) cases.
                            echo "${major}.${_new_minor}.0"
                        else
                            # MINOR stays put — PATCH bump. Reached when
                            # target<=current_minor AND hwm<=current_minor.
                            echo "${major}.${minor}.$((patch + 1))"
                        fi
                    else
                        echo "$current"
                    fi
                    ;;
                major)
                    echo "$((major + 1)).0.0"
                    ;;
                patch|minor|*)
                    echo "${major}.${minor}.$((patch + 1))"
                    ;;
            esac
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

    # Bump each declared version file (m43: multi-entry parser handles both
    # `;`- and newline-separated VERSION_FILES values).
    local -a entries=()
    _parse_version_files_list "$version_files_str" entries
    local entry file
    for entry in "${entries[@]}"; do
        file="${entry%%:*}"
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

    # m43 Goal 2: post-bump consistency self-check. Read every declared
    # file back; trip the commit gate + emit a HUMAN_ACTION entry on any
    # divergence so a desynced bump never reaches the commit stage.
    if command -v verify_version_files_synced &>/dev/null; then
        verify_version_files_synced "$next_version" "${entries[@]}" || true
    fi
}
