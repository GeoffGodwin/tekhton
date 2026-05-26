#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# finalize_version.sh — Project version bump finalize hooks (Milestone 76)
#
# Sourced by finalize.sh — do not run directly.
# Expects: lib/project_version.sh, lib/project_version_bump.sh sourced first.
# Provides:
#   _hook_project_version_bump — bump version files before commit
#   _hook_project_version_tag  — create git tag after commit
# =============================================================================

# _hook_project_version_bump — Bump project version files on successful run.
# Runs before _hook_commit so bumped files are included in the commit.
# Guarded by PROJECT_VERSION_ENABLED and the no-op gate (no changes = no bump).
_hook_project_version_bump() {
    local exit_code="$1"
    [[ "$exit_code" -ne 0 ]] && return 0
    [[ "${FINAL_CHECK_RESULT:-0}" -ne 0 ]] && return 0
    [[ "${PROJECT_VERSION_ENABLED:-true}" != "true" ]] && return 0

    # Auto-detect version files if not already done
    detect_project_version_files

    local strategy
    strategy=$(_read_version_config "VERSION_STRATEGY" 2>/dev/null || echo "")
    [[ -z "$strategy" ]] && return 0
    [[ "$strategy" == "none" ]] && return 0

    # No-op gate: skip if no changes to commit
    if [[ -z "$(git status --porcelain 2>/dev/null)" ]]; then
        return 0
    fi

    local hint
    if [[ "$strategy" == "milestone" ]] \
        && [[ "${MILESTONE_MODE:-false}" == "true" ]] \
        && [[ -n "${_CURRENT_MILESTONE:-}" ]]; then
        case "${_CACHED_DISPOSITION:-}" in
            COMPLETE_AND_CONTINUE|COMPLETE_AND_WAIT)
                hint="milestone:${_CURRENT_MILESTONE:-}"
                ;;
            *)
                hint="patch"
                ;;
        esac
    elif [[ "$strategy" == "milestone" ]]; then
        hint="patch"
    else
        hint=$(get_version_bump_hint)
    fi

    bump_version_files "$hint"
}

# _hook_project_version_tag — Create git tag after successful commit.
# Runs after _hook_commit. Only tags if PROJECT_VERSION_TAG_ON_BUMP=true.
_hook_project_version_tag() {
    # shellcheck disable=SC2034  # exit_code accepted for hook interface parity
    # Deliberately not checked: tagging guards on _COMMIT_SUCCEEDED (set by
    # _hook_commit) rather than exit_code, because the tag should only be
    # created after a confirmed git commit, not merely a successful pipeline.
    local exit_code="$1"
    [[ "${_COMMIT_SUCCEEDED:-false}" != "true" ]] && return 0
    [[ "${PROJECT_VERSION_ENABLED:-true}" != "true" ]] && return 0
    [[ "${PROJECT_VERSION_TAG_ON_BUMP:-false}" != "true" ]] && return 0

    local new_version
    new_version=$(parse_current_version)
    [[ -z "$new_version" ]] && return 0

    local tag="v${new_version}"
    # Check for tag collision — never force-overwrite
    if git tag -l -- "$tag" | grep -q "^${tag}$"; then
        if command -v warn &>/dev/null; then
            warn "Git tag ${tag} already exists — skipping."
        fi
        return 0
    fi

    git tag -- "$tag" 2>/dev/null || true
    if command -v log &>/dev/null; then
        log "Created git tag: ${tag}"
    fi
}
