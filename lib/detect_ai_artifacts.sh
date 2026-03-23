#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_ai_artifacts.sh — AI artifact detection engine (Milestone 11)
#
# Scans a project directory for known AI tool configurations: .cursor/,
# .cursorrules, .github/copilot/, .aider*, .cline/, .continue/, .windsurf/,
# .windsurfrules, .roomodes, .roo/, CLAUDE.md, .claude/ (granular), and
# heuristic markdown files containing agent-style directives.
#
# Sourced by lib/init.sh — do not run directly.
# Depends on: common.sh (log, warn)
#
# Provides:
#   detect_ai_artifacts()          — main detection entry point
#   classify_ai_tool()             — maps paths to known tool names
#   _scan_for_directive_language()  — heuristic persona detection in .md files
# =============================================================================

# --- Known AI tool patterns ---------------------------------------------------

# _KNOWN_AI_DIRS — Directories that are definitively AI tool configs.
# Format: DIR_NAME|TOOL_NAME
_KNOWN_AI_DIRS=(
    ".cursor|Cursor"
    ".github/copilot|GitHub Copilot"
    ".cline|Cline"
    "cline_docs|Cline"
    ".continue|Continue.dev"
    ".windsurf|Windsurf"
    ".roo|Roo Code"
    ".ai|Generic AI Config"
)

# _KNOWN_AI_FILES — Files that are definitively AI tool configs.
# Format: FILE_NAME|TOOL_NAME
_KNOWN_AI_FILES=(
    ".cursorrules|Cursor"
    ".windsurfrules|Windsurf"
    ".roomodes|Roo Code"
    ".aiconfig|Generic AI Config"
)

# _KNOWN_AI_GLOBS — Glob patterns for AI tool files.
# Format: GLOB_PATTERN|TOOL_NAME
_KNOWN_AI_GLOBS=(
    ".aider*|aider"
)

# --- Main detection entry point -----------------------------------------------

# detect_ai_artifacts — Scans project directory for AI tool configurations.
#
# Args: $1 = project directory
# Output: One line per artifact: TOOL|PATH|TYPE|CONFIDENCE
#   TYPE: config, rules, agents, code-patterns
#   CONFIDENCE: high, medium, low
# Returns: 0 always (empty output means no artifacts found)
detect_ai_artifacts() {
    local project_dir="$1"
    local results=""

    # --- Known AI directories ---
    local entry dir_name file_name tool_name
    for entry in "${_KNOWN_AI_DIRS[@]}"; do
        IFS='|' read -r dir_name tool_name <<< "$entry"
        if [[ -d "${project_dir}/${dir_name}" ]]; then
            # Special case: .ai/ might be Adobe Illustrator files
            if [[ "$dir_name" == ".ai" ]]; then
                if _dir_has_config_files "${project_dir}/${dir_name}"; then
                    results+="${tool_name}|${dir_name}/|config|medium"$'\n'
                fi
            else
                results+="${tool_name}|${dir_name}/|config|high"$'\n'
            fi
        fi
    done

    # --- Known AI files ---
    for entry in "${_KNOWN_AI_FILES[@]}"; do
        IFS='|' read -r file_name tool_name <<< "$entry"
        if [[ -f "${project_dir}/${file_name}" ]]; then
            results+="${tool_name}|${file_name}|rules|high"$'\n'
        fi
    done

    # --- Glob patterns (e.g., .aider*) ---
    local pattern
    for entry in "${_KNOWN_AI_GLOBS[@]}"; do
        IFS='|' read -r pattern tool_name <<< "$entry"
        local match
        # Use compgen to safely expand glob
        while IFS= read -r match; do
            [[ -z "$match" ]] && continue
            local basename_match
            basename_match=$(basename "$match")
            results+="${tool_name}|${basename_match}|config|high"$'\n'
        done < <(compgen -G "${project_dir}/${pattern}" 2>/dev/null || true)
    done

    # --- .claude/ directory (granular detection) ---
    _detect_claude_dir_artifacts "$project_dir" results

    # --- CLAUDE.md (provenance check) ---
    _detect_claude_md "$project_dir" results

    # --- Heuristic: markdown files with agent-style directives ---
    _detect_directive_markdowns "$project_dir" results

    # Output (strip trailing newline, skip empty lines)
    if [[ -n "$results" ]]; then
        echo "$results" | sed '/^$/d'
    fi
}

# --- classify_ai_tool — Maps a path to a known AI tool name ------------------

# classify_ai_tool — Given a path relative to project root, return the tool name.
# Args: $1 = relative path
# Output: tool name or "unknown"
classify_ai_tool() {
    local path="$1"

    case "$path" in
        .cursor/*|.cursorrules)    echo "Cursor" ;;
        .github/copilot/*)        echo "GitHub Copilot" ;;
        .aider*)                  echo "aider" ;;
        .cline/*|cline_docs/*)    echo "Cline" ;;
        .continue/*)              echo "Continue.dev" ;;
        .windsurf/*|.windsurfrules) echo "Windsurf" ;;
        .roomodes|.roo/*)         echo "Roo Code" ;;
        .ai/*|.aiconfig)          echo "Generic AI Config" ;;
        .claude/pipeline.conf)    echo "Tekhton" ;;
        .claude/agents/*)         echo "Tekhton" ;;
        .claude/milestones/*)     echo "Tekhton" ;;
        .claude/settings.json|.claude/settings.local.json) echo "Claude Code" ;;
        .claude/commands/*)       echo "Claude Code" ;;
        .claude/*)                echo "Claude Code" ;;
        CLAUDE.md)                echo "Claude/Tekhton" ;;
        *)                        echo "unknown" ;;
    esac
}

# --- Granular .claude/ detection ----------------------------------------------

# _detect_claude_dir_artifacts — Detects AI artifacts within .claude/ at file level.
# Distinguishes Tekhton artifacts from Claude Code artifacts.
# Args: $1 = project directory, $2 = nameref to results string
_detect_claude_dir_artifacts() {
    local project_dir="$1"
    local -n _results="$2"
    local claude_dir="${project_dir}/.claude"

    [[ -d "$claude_dir" ]] || return 0

    # Tekhton-specific artifacts
    if [[ -f "${claude_dir}/pipeline.conf" ]]; then
        _results+="Tekhton|.claude/pipeline.conf|config|high"$'\n'
    fi
    if [[ -d "${claude_dir}/agents" ]] && compgen -G "${claude_dir}/agents/*.md" >/dev/null 2>&1; then
        _results+="Tekhton|.claude/agents/|agents|high"$'\n'
    fi
    if [[ -d "${claude_dir}/milestones" ]]; then
        _results+="Tekhton|.claude/milestones/|config|high"$'\n'
    fi

    # Claude Code artifacts
    if [[ -f "${claude_dir}/settings.json" ]]; then
        _results+="Claude Code|.claude/settings.json|config|high"$'\n'
    fi
    if [[ -f "${claude_dir}/settings.local.json" ]]; then
        _results+="Claude Code|.claude/settings.local.json|config|high"$'\n'
    fi
    if [[ -d "${claude_dir}/commands" ]] && compgen -G "${claude_dir}/commands/*" >/dev/null 2>&1; then
        _results+="Claude Code|.claude/commands/|config|high"$'\n'
    fi
}

# --- CLAUDE.md provenance detection -------------------------------------------

# _detect_claude_md — Checks for CLAUDE.md and determines its provenance.
# Tekhton-managed files have <!-- tekhton-managed --> marker.
# Args: $1 = project directory, $2 = nameref to results string
_detect_claude_md() {
    local project_dir="$1"
    local -n _results="$2"
    local claude_md="${project_dir}/CLAUDE.md"

    [[ -f "$claude_md" ]] || return 0

    if grep -q '<!-- tekhton-managed -->' "$claude_md" 2>/dev/null; then
        _results+="Tekhton|CLAUDE.md|rules|high"$'\n'
    else
        # Hand-written or Claude Code native — valuable merge candidate
        _results+="Claude/Tekhton|CLAUDE.md|rules|medium"$'\n'
    fi
}

# --- Heuristic: directive-bearing markdown files ------------------------------

# _scan_for_directive_language — Checks if a markdown file contains
# agent-style directives (persona language, rules blocks, etc.).
# Args: $1 = file path
# Returns: 0 if directive language detected, 1 otherwise
_scan_for_directive_language() {
    local file="$1"

    [[ -f "$file" ]] || return 1
    # Only scan .md files
    [[ "$file" == *.md ]] || return 1

    # Look for agent persona language patterns
    local match_count=0
    # "You are" at start of line (persona)
    grep -qci '^\s*you are\b' "$file" 2>/dev/null && match_count=$(( match_count + 1 ))
    # "Your role" or "Your job"
    grep -qci '^\s*your \(role\|job\)\b' "$file" 2>/dev/null && match_count=$(( match_count + 1 ))
    # "## Rules" or "## Constraints" headers
    grep -qci '^##\s*\(Rules\|Constraints\|Guidelines\|Instructions\)' "$file" 2>/dev/null && match_count=$(( match_count + 1 ))
    # "MUST" / "NEVER" / "ALWAYS" in all caps (directive language)
    local directive_count=0
    directive_count=$(grep -ci '\bMUST\b\|\bNEVER\b\|\bALWAYS\b' "$file" 2>/dev/null || true)
    [[ "$directive_count" -ge 3 ]] && match_count=$(( match_count + 1 ))

    [[ "$match_count" -ge 2 ]]
}

# _detect_directive_markdowns — Scans common markdown files for agent directives.
# Only checks well-known filenames, not every .md in the project.
# Args: $1 = project directory, $2 = nameref to results string
_detect_directive_markdowns() {
    local project_dir="$1"
    local -n _results="$2"

    local candidate
    for candidate in AGENTS.md CONVENTIONS.md ARCHITECTURE.md; do
        local full_path="${project_dir}/${candidate}"
        if [[ -f "$full_path" ]] && _scan_for_directive_language "$full_path"; then
            _results+="AI Directives|${candidate}|rules|low"$'\n'
        fi
    done
}

# --- Helper: check if directory contains config-like files --------------------

# _dir_has_config_files — Returns 0 if directory has .json/.yaml/.yml/.md/.toml files.
# Used for ambiguous directories like .ai/ that might not be AI config.
# Args: $1 = directory path
_dir_has_config_files() {
    local dir="$1"
    compgen -G "${dir}/*.json" >/dev/null 2>&1 && return 0
    compgen -G "${dir}/*.yaml" >/dev/null 2>&1 && return 0
    compgen -G "${dir}/*.yml" >/dev/null 2>&1 && return 0
    compgen -G "${dir}/*.md" >/dev/null 2>&1 && return 0
    compgen -G "${dir}/*.toml" >/dev/null 2>&1 && return 0
    return 1
}
