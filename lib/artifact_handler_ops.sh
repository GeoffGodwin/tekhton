#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# artifact_handler_ops.sh — AI artifact handling operations (Milestone 11)
#
# Per-strategy handlers: archive, merge, tidy, ignore, tekhton-reinit.
# Sourced by lib/artifact_handler.sh — do not run directly.
# Depends on: common.sh, prompts_interactive.sh, prompts.sh
#             plan.sh (_call_planning_batch) — loaded on demand for merge ops
# =============================================================================

# --- Archive --
# _archive_artifact_group — Moves artifacts to .claude/archived-ai-config/.
# Args: $1 = project dir, $2 = tool name, $3 = group artifacts
_archive_artifact_group() {
    local project_dir="$1"
    local tool_name="$2"
    local group_artifacts="$3"
    local archive_dir="${project_dir}/${ARTIFACT_ARCHIVE_DIR:-.claude/archived-ai-config}"
    local manifest_file="${archive_dir}/MANIFEST.md"

    mkdir -p "$archive_dir"

    # Initialize manifest if it doesn't exist
    if [[ ! -f "$manifest_file" ]]; then
        cat > "$manifest_file" << 'MANIFEST_EOF'
# Archived AI Configurations

Archived by `tekhton --init`. Original files preserved intact for reference.

| Date | Tool | Original Path | Archive Path |
|------|------|---------------|--------------|
MANIFEST_EOF
    fi

    local path atype confidence
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M")
    while IFS='|' read -r path atype confidence; do
        [[ -z "$path" ]] && continue
        local src="${project_dir}/${path}"
        local dest_name
        dest_name=$(echo "$path" | tr '/' '_')
        local dest="${archive_dir}/${dest_name}"

        if [[ -e "$src" ]]; then
            # Preserve directory structure for dirs
            if [[ -d "$src" ]]; then
                cp -r "$src" "$dest"
                rm -rf "$src"
            else
                cp "$src" "$dest"
                rm -f "$src"
            fi
            echo "| ${timestamp} | ${tool_name} | ${path} | ${dest_name} |" >> "$manifest_file"
            success "Archived: ${path} → ${ARTIFACT_ARCHIVE_DIR:-archived-ai-config}/${dest_name}"
        fi
    done <<< "$group_artifacts"
}

# --- Merge ---
# _run_merge_batch — Lazy-loads dependencies and runs the merge agent.
# Args: $1 = tool name, $2 = collected content, $3 = project dir,
#        $4 = merge context file
_run_merge_batch() {
    local tool_name="$1" collected_content="$2"
    local project_dir="$3" merge_context_file="$4"
    local _ops_dir="${BASH_SOURCE[0]%/*}"

    # Lazy-load plan.sh (_call_planning_batch) and prompts.sh (render_prompt)
    # — neither is sourced during --init.
    if ! type _call_planning_batch &>/dev/null; then
        # shellcheck source=lib/plan.sh
        source "${_ops_dir}/plan.sh"
    fi
    if ! type render_prompt &>/dev/null; then
        # shellcheck source=lib/prompts.sh
        source "${_ops_dir}/prompts.sh"
    fi

    export MERGE_ARTIFACT_CONTENT="$collected_content"
    export MERGE_TOOL_NAME="$tool_name"

    local model="${ARTIFACT_MERGE_MODEL:-${CLAUDE_STANDARD_MODEL:-claude-sonnet-4-6}}"
    local max_turns="${ARTIFACT_MERGE_MAX_TURNS:-10}"
    local log_dir="${project_dir}/.claude/logs"
    mkdir -p "$log_dir"
    local log_file
    log_file="${log_dir}/$(date +"%Y%m%d_%H%M%S")_artifact-merge.log"

    local prompt
    prompt=$(render_prompt "artifact_merge")

    printf '=== Tekhton Artifact Merge (%s) ===\nDate: %s\nModel: %s\n=== Session Start ===\n' \
        "$tool_name" "$(date)" "$model" > "$log_file"

    local merge_output="" batch_exit=0
    merge_output=$(_call_planning_batch \
        "$model" "$max_turns" "$prompt" "$log_file") || batch_exit=$?

    printf '=== Session End ===\nExit code: %s\n' "$batch_exit" >> "$log_file"

    if [[ -n "$merge_output" ]]; then
        [[ -f "$merge_context_file" ]] && printf '\n\n---\n\n' >> "$merge_context_file"
        printf '%s\n' "$merge_output" >> "$merge_context_file"
        success "Merged ${tool_name} config → MERGE_CONTEXT.md"
    else
        warn "Merge agent produced no output for ${tool_name}."
    fi

    unset MERGE_ARTIFACT_CONTENT MERGE_TOOL_NAME
}
# _merge_artifact_group — Invokes merge agent to extract useful content.
# Args: $1 = project dir, $2 = tool name, $3 = group artifacts
_merge_artifact_group() {
    local project_dir="$1"
    local tool_name="$2"
    local group_artifacts="$3"
    local merge_context_file="${project_dir}/MERGE_CONTEXT.md"

    log "Extracting useful content from ${tool_name} configuration..."

    # Collect file contents for the merge agent
    local collected_content=""
    local path atype confidence
    while IFS='|' read -r path atype confidence; do
        [[ -z "$path" ]] && continue
        local src="${project_dir}/${path}"
        if [[ -f "$src" ]]; then
            local content
            content=$(head -500 "$src" 2>/dev/null || true)
            if [[ -n "$content" ]]; then
                collected_content+="--- BEGIN: ${path} (${tool_name}, ${atype}) ---"$'\n'
                collected_content+="${content}"$'\n'
                collected_content+="--- END: ${path} ---"$'\n'$'\n'
            fi
        elif [[ -d "$src" ]]; then
            # For directories, scan .md/.json/.yaml files only
            _collect_dir_content "$src" "$path" "$tool_name" "$atype" collected_content
        fi
    done <<< "$group_artifacts"

    if [[ -z "$collected_content" ]]; then
        warn "No readable content found in ${tool_name} artifacts — skipping merge."
        return 0
    fi

    _run_merge_batch "$tool_name" "$collected_content" \
        "$project_dir" "$merge_context_file"
}

# _collect_dir_content — Collects .md/.json/.yaml content from a directory.
# Args: $1 = dir path, $2 = relative path, $3 = tool name,
#        $4 = artifact type, $5 = nameref to content string
_collect_dir_content() {
    local dir="$1"
    local rel_path="$2"
    local tool_name="$3"
    local atype="$4"
    local -n _content="$5"

    local file
    for file in "$dir"/*.md "$dir"/*.json "$dir"/*.yaml "$dir"/*.yml; do
        [[ -f "$file" ]] || continue
        local fname
        fname=$(basename "$file")
        local file_content
        file_content=$(head -200 "$file" 2>/dev/null || true)
        if [[ -n "$file_content" ]]; then
            _content+="--- BEGIN: ${rel_path}${fname} (${tool_name}, ${atype}) ---"$'\n'
            _content+="${file_content}"$'\n'
            _content+="--- END: ${rel_path}${fname} ---"$'\n'$'\n'
        fi
    done
}

# --- Tidy ---
# _tidy_artifact_group — Removes artifacts with confirmation.
# Args: $1 = project dir, $2 = tool name, $3 = group artifacts
_tidy_artifact_group() {
    local project_dir="$1"
    local tool_name="$2"
    local group_artifacts="$3"

    local path atype confidence
    while IFS='|' read -r path atype confidence; do
        [[ -z "$path" ]] && continue
        local src="${project_dir}/${path}"

        if [[ ! -e "$src" ]]; then
            continue
        fi

        # Require explicit confirmation per artifact in interactive mode
        if [[ -z "${ARTIFACT_HANDLING_DEFAULT:-}" ]]; then
            if ! prompt_confirm "Remove ${path}?" "n"; then
                log "Skipped: ${path}"
                continue
            fi
        fi

        if [[ -d "$src" ]]; then
            rm -rf "$src"
        else
            rm -f "$src"
        fi
        success "Removed: ${path}"

        # Check for related .gitignore entries
        _tidy_gitignore_entry "$project_dir" "$path"
    done <<< "$group_artifacts"

    # Offer optional git commit for tidying
    if [[ -z "${ARTIFACT_HANDLING_DEFAULT:-}" ]]; then
        _offer_tidy_commit "$project_dir" "$tool_name"
    fi
}

# _tidy_gitignore_entry — Offers to clean up .gitignore entries for removed artifacts.
# Args: $1 = project dir, $2 = artifact path
_tidy_gitignore_entry() {
    local project_dir="$1"
    local artifact_path="$2"
    local gitignore="${project_dir}/.gitignore"

    [[ -f "$gitignore" ]] || return 0

    # Check if .gitignore has an entry for this artifact
    local pattern
    pattern="${artifact_path%/}"
    local escaped_pattern
    escaped_pattern=$(printf '%s' "$pattern" | sed 's/[.[\*^$/]/\\&/g')
    if grep -q "^${escaped_pattern}" "$gitignore" 2>/dev/null || \
       grep -q "^/${escaped_pattern}" "$gitignore" 2>/dev/null; then
        if [[ -z "${ARTIFACT_HANDLING_DEFAULT:-}" ]]; then
            if prompt_confirm "  Also remove '${pattern}' from .gitignore?" "n"; then
                local tmp
                tmp=$(mktemp)
                grep -v "^/\?${escaped_pattern}" "$gitignore" > "$tmp" 2>/dev/null || true
                mv "$tmp" "$gitignore"
                success "  Cleaned .gitignore entry for ${pattern}"
            fi
        fi
    fi
}

# _offer_tidy_commit — Offers to create a git commit after tidying.
# Args: $1 = project dir, $2 = tool name
_offer_tidy_commit() {
    local project_dir="$1"
    local tool_name="$2"

    # Only offer if in a git repo with changes
    if ! git -C "$project_dir" rev-parse --git-dir &>/dev/null; then
        return 0
    fi

    local changes
    changes=$(git -C "$project_dir" status --porcelain 2>/dev/null || true)
    [[ -z "$changes" ]] && return 0

    if prompt_confirm "Create a git commit for the ${tool_name} removal?" "n"; then
        git -C "$project_dir" add -u >/dev/null 2>&1
        git -C "$project_dir" commit -m "chore: remove prior ${tool_name} config (tekhton --init)" \
            >/dev/null 2>&1 || true
        success "Committed removal of ${tool_name} config"
    fi
}

# --- Ignore ---

# _ignore_artifact_group — Proceeds with warning about potential conflicts.
# Args: $1 = tool name
_ignore_artifact_group() {
    local tool_name="$1"
    warn "${tool_name} artifacts left in place — config conflicts may occur."
}

# --- Tekhton reinit path ------------------------------------------------------

# _handle_tekhton_reinit — Special handling for prior Tekhton installs.
# Preserves pipeline.conf settings while noting the reinit.
# Args: $1 = project dir, $2 = group artifacts
_handle_tekhton_reinit() {
    local project_dir="$1"
    local group_artifacts="$2"

    log "Prior Tekhton installation detected."

    local has_pipeline_conf=false
    local path atype confidence
    # shellcheck disable=SC2034  # confidence consumed by format, not code
    while IFS='|' read -r path atype confidence; do
        [[ "$path" == ".claude/pipeline.conf" ]] && has_pipeline_conf=true
    done <<< "$group_artifacts"

    if [[ "$has_pipeline_conf" == "true" ]]; then
        success "pipeline.conf will be preserved during re-initialization."
        log "Agent roles will be regenerated with current templates."
    fi
}