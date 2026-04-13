#!/usr/bin/env bash
# =============================================================================
# docs_agent.sh — Docs agent skip-path detection and public-surface parsing
#
# Sourced by tekhton.sh — do not run directly.
# Provides: docs_agent_should_skip()
#
# The docs agent (M75) runs between the build gate and the security stage.
# This helper determines whether the stage should skip (no public-surface
# changes) or run (coder touched something that might need doc updates).
# =============================================================================
set -euo pipefail

# docs_agent_should_skip — Decide whether the docs stage can be skipped.
#   Returns 0 if the stage should skip (no work), 1 if it should run.
#
# Skip criteria (any one suffices):
#   - DOCS_AGENT_ENABLED != true
#   - SKIP_DOCS == true (--skip-docs flag)
#   - No changed files from the coder touch public-surface paths
#
# When the public-surface check can't determine relevance (no CLAUDE.md
# section 13, no changed files, parse failure), it returns 1 (run the
# agent) — false-negative skips are worse than false-positive runs.
docs_agent_should_skip() {
    # Gate checks (caller already checks these, but belt-and-suspenders)
    if [[ "${DOCS_AGENT_ENABLED:-false}" != "true" ]]; then
        return 0
    fi
    if [[ "${SKIP_DOCS:-false}" == "true" ]]; then
        return 0
    fi

    # Get changed files from the coder's work
    local changed_files
    changed_files=$(git diff --name-only HEAD 2>/dev/null || true)
    if [[ -z "$changed_files" ]]; then
        # No unstaged changes — check staged
        changed_files=$(git diff --cached --name-only 2>/dev/null || true)
    fi
    if [[ -z "$changed_files" ]]; then
        log "[docs] No changed files detected. Skipping docs agent."
        return 0
    fi

    # Extract public-surface patterns from CLAUDE.md section 13
    local surface_patterns
    surface_patterns=$(_docs_extract_public_surface)
    if [[ -z "$surface_patterns" ]]; then
        # No section 13 found — can't determine; run the agent to be safe
        log "[docs] No Documentation Responsibilities section in CLAUDE.md. Running agent."
        return 1
    fi

    # Check if any changed file matches a public-surface pattern
    if _docs_changed_files_match_surface "$changed_files" "$surface_patterns"; then
        return 1  # run the agent
    fi

    log "[docs] No public-surface files changed. Skipping docs agent."
    return 0
}

# _docs_extract_public_surface — Extract public-surface indicators from CLAUDE.md.
# Reads the Documentation Responsibilities section (section 13) and extracts
# keywords/patterns that indicate public-surface files.
# Returns patterns one per line, or empty string if section not found.
_docs_extract_public_surface() {
    local rules_file="${PROJECT_RULES_FILE:-CLAUDE.md}"
    if [[ ! -f "$rules_file" ]]; then
        return
    fi

    # Extract the Documentation Responsibilities section.
    # Look for the heading and capture until the next ## heading.
    local section
    section=$(sed -n '/^##.*[Dd]ocumentation [Rr]esponsibilities/,/^## /{ /^## [^D]/d; p; }' \
        "$rules_file" 2>/dev/null || true)
    if [[ -z "$section" ]]; then
        return
    fi

    # Extract file extensions, paths, and surface indicators from the section.
    # We look for common patterns: file extensions (*.sh, *.ts), directory
    # references (docs/, src/), and keywords (CLI, API, config, README).
    local patterns=""

    # File extension patterns (e.g., "*.sh", ".ts files")
    local ext_matches
    ext_matches=$(echo "$section" | grep -oE '\*\.[a-zA-Z0-9]+' || true)
    if [[ -n "$ext_matches" ]]; then
        patterns="${patterns}${ext_matches}"$'\n'
    fi

    # Explicit path references (e.g., "README.md", "docs/", "src/api/")
    local path_matches
    path_matches=$(echo "$section" | grep -oE '[a-zA-Z0-9_./]+\.(md|txt|rst|adoc)' || true)
    if [[ -n "$path_matches" ]]; then
        patterns="${patterns}${path_matches}"$'\n'
    fi

    # Directory references (e.g., "docs/", "src/")
    local dir_matches
    dir_matches=$(echo "$section" | grep -oE '[a-zA-Z0-9_-]+/' || true)
    if [[ -n "$dir_matches" ]]; then
        patterns="${patterns}${dir_matches}"$'\n'
    fi

    # Always include README and common doc files as public surface
    patterns="${patterns}README.md"$'\n'
    patterns="${patterns}${DOCS_README_FILE:-README.md}"$'\n'
    patterns="${patterns}${DOCS_DIRS:-docs/}"$'\n'

    # Deduplicate and return
    echo "$patterns" | sort -u | grep -v '^$' || true
}

# _docs_changed_files_match_surface — Check if changed files touch public surface.
# Args: $1 = newline-separated changed files, $2 = newline-separated patterns
# Returns: 0 if any file matches, 1 if no matches.
_docs_changed_files_match_surface() {
    local changed_files="$1"
    local patterns="$2"

    while IFS= read -r pattern; do
        [[ -z "$pattern" ]] && continue

        # Handle glob-style patterns (e.g., "*.sh")
        if [[ "$pattern" == *"*"* ]]; then
            # Convert glob to grep-compatible regex
            local regex
            regex=$(echo "$pattern" | sed 's/\./\\./g; s/\*/.*/g')
            if echo "$changed_files" | grep -qE -- "$regex"; then
                return 0
            fi
        else
            # Literal path/prefix match
            if echo "$changed_files" | grep -qF -- "$pattern"; then
                return 0
            fi
        fi
    done <<< "$patterns"

    return 1
}
