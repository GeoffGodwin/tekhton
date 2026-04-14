#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# index_reader.sh — Structured index reader API (Milestone 68)
#
# Reads from .claude/index/ structured data files and returns formatted content
# for prompt injection. All functions accept a project directory argument and
# gracefully fall back to legacy project index parsing when structured files
# don't exist (pre-M67 projects).
#
# Sourced by tekhton.sh AFTER crawler.sh — do not run directly.
# Depends on: common.sh (log, warn)
# =============================================================================

# --- Core reader functions ----------------------------------------------------

# read_index_meta — Returns metadata as key=value pairs.
# Args: $1 = project directory
# Output: "project_name=foo\nfile_count=342\n..."
read_index_meta() {
    local project_dir="$1"
    local meta_file="${project_dir}/.claude/index/meta.json"

    if [[ -f "$meta_file" ]]; then
        # Parse formatted JSON (one key per line) without jq
        local key value
        while IFS= read -r line; do
            if [[ "$line" =~ \"([a-z_]+)\":[[:space:]]*\"([^\"]*)\" ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                printf '%s=%s\n' "$key" "$value"
            elif [[ "$line" =~ \"([a-z_]+)\":[[:space:]]*([0-9]+) ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                printf '%s=%s\n' "$key" "$value"
            fi
        done < "$meta_file"
        return 0
    fi

    # Legacy fallback: parse HTML comments from project index
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0

    local scan_date scan_commit file_count total_lines project_name
    scan_date=$(grep '<!-- Last-Scan:' "$index_file" 2>/dev/null | \
        sed 's/.*<!-- Last-Scan: *\(.*\) *-->.*/\1/' | tr -d '[:space:]' || true)
    scan_commit=$(grep '<!-- Scan-Commit:' "$index_file" 2>/dev/null | \
        sed 's/.*<!-- Scan-Commit: *\(.*\) *-->.*/\1/' | tr -d '[:space:]' || true)
    file_count=$(grep '<!-- File-Count:' "$index_file" 2>/dev/null | \
        sed 's/.*<!-- File-Count: *\(.*\) *-->.*/\1/' | tr -d '[:space:]' || true)
    total_lines=$(grep '<!-- Total-Lines:' "$index_file" 2>/dev/null | \
        sed 's/.*<!-- Total-Lines: *\(.*\) *-->.*/\1/' | tr -d '[:space:]' || true)
    project_name=$(head -1 "$index_file" 2>/dev/null | sed 's/^# [^ ]* — //' || true)

    [[ -n "$project_name" ]] && printf 'project_name=%s\n' "$project_name"
    [[ -n "$scan_date" ]] && printf 'scan_date=%s\n' "$scan_date"
    [[ -n "$scan_commit" ]] && printf 'scan_commit=%s\n' "$scan_commit"
    [[ -n "$file_count" ]] && printf 'file_count=%s\n' "$file_count"
    [[ -n "$total_lines" ]] && printf 'total_lines=%s\n' "$total_lines"
}

# read_index_tree — Returns directory tree text.
# Args: $1 = project directory, $2 = max_lines (optional, 0=unlimited)
# Output: Plain text tree
read_index_tree() {
    local project_dir="$1"
    local max_lines="${2:-0}"
    local tree_file="${project_dir}/.claude/index/tree.txt"

    if [[ -f "$tree_file" ]]; then
        if [[ "$max_lines" -gt 0 ]]; then
            head -"$max_lines" "$tree_file"
        else
            cat "$tree_file"
        fi
        return 0
    fi

    # Legacy fallback: extract from project index
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0

    _index_extract_section "$index_file" "Directory Tree" "$max_lines"
}

# read_index_inventory — Returns file inventory as formatted text.
# Args: $1 = project directory, $2 = max_records (optional, 0=unlimited)
#        $3 = filter (optional: "size:large,huge" or "dir:src")
# Output: Formatted table
read_index_inventory() {
    local project_dir="$1"
    local max_records="${2:-0}"
    local filter="${3:-}"
    local inv_file="${project_dir}/.claude/index/inventory.jsonl"

    if [[ -f "$inv_file" ]]; then
        local count=0
        printf '| Path | Lines | Size |\n|------|-------|------|\n'
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue

            # Apply filter
            if [[ -n "$filter" ]]; then
                if [[ "$filter" == size:* ]]; then
                    local sizes="${filter#size:}"
                    local match=false
                    local IFS=','
                    local sz
                    for sz in $sizes; do
                        if [[ "$line" == *"\"size\":\"${sz}\""* ]]; then
                            match=true
                            break
                        fi
                    done
                    unset IFS
                    [[ "$match" == false ]] && continue
                elif [[ "$filter" == dir:* ]]; then
                    local dir_filter="${filter#dir:}"
                    [[ "$line" != *"\"dir\":\"${dir_filter}"* ]] && continue
                fi
            fi

            # Parse JSONL record
            local path lines size
            path=$(printf '%s' "$line" | sed 's/.*"path":"\([^"]*\)".*/\1/')
            lines=$(printf '%s' "$line" | sed 's/.*"lines":\([0-9]*\).*/\1/')
            size=$(printf '%s' "$line" | sed 's/.*"size":"\([^"]*\)".*/\1/')

            printf '| %s | %s | %s |\n' "$path" "$lines" "$size"
            count=$((count + 1))
            [[ "$max_records" -gt 0 && "$count" -ge "$max_records" ]] && break
        done < "$inv_file"
        return 0
    fi

    # Legacy fallback: extract from project index
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return

    local section
    section=$(_index_extract_section "$index_file" "File Inventory" 0)
    if [[ "$max_records" -gt 0 ]] && [[ -n "$section" ]]; then
        # Keep header + first max_records data lines
        printf '%s\n' "$section" | head -$((max_records + 2))
    else
        printf '%s' "$section"
    fi
}

# read_index_dependencies — Returns dependency summary.
# Args: $1 = project directory
# Output: Formatted dependency text
read_index_dependencies() {
    local project_dir="$1"
    local dep_file="${project_dir}/.claude/index/dependencies.json"

    if [[ -f "$dep_file" ]]; then
        local output=""

        # Parse manifests
        local in_manifests=false
        while IFS= read -r line; do
            if [[ "$line" == *'"manifests"'* ]]; then
                in_manifests=true; continue
            fi
            [[ "$in_manifests" != true ]] && continue
            [[ "$line" == *']'* ]] && break

            if [[ "$line" =~ \"file\":\"([^\"]*)\" ]]; then
                local file="${BASH_REMATCH[1]}"
                local manager deps dev_deps
                manager=$(printf '%s' "$line" | sed 's/.*"manager":"\([^"]*\)".*/\1/')
                deps=$(printf '%s' "$line" | sed 's/.*"deps":\([0-9]*\).*/\1/')
                dev_deps=$(printf '%s' "$line" | sed 's/.*"dev_deps":\([0-9]*\).*/\1/')
                output+="**${file}** (${manager}): ${deps} deps, ${dev_deps} dev deps"$'\n'
            fi
        done < "$dep_file"

        # Parse key dependencies (first 20)
        local dep_count=0
        local in_deps=false
        while IFS= read -r line; do
            if [[ "$line" == *'"key_dependencies"'* ]]; then
                in_deps=true; continue
            fi
            [[ "$in_deps" != true ]] && continue
            [[ "$line" == *']'* ]] && break

            if [[ "$line" =~ \"name\":\"([^\"]*)\" ]]; then
                local name="${BASH_REMATCH[1]}"
                local version
                version=$(printf '%s' "$line" | sed 's/.*"version":"\([^"]*\)".*/\1/')
                output+="- ${name} ${version}"$'\n'
                dep_count=$((dep_count + 1))
                [[ "$dep_count" -ge 20 ]] && break
            fi
        done < "$dep_file"

        printf '%s' "$output"
        return 0
    fi

    # Legacy fallback
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0
    _index_extract_section "$index_file" "Key Dependencies" 0
}

# read_index_configs — Returns config file list.
# Args: $1 = project directory
# Output: Formatted config table
read_index_configs() {
    local project_dir="$1"
    local cfg_file="${project_dir}/.claude/index/configs.json"

    if [[ -f "$cfg_file" ]]; then
        printf '| Config File | Purpose |\n|-------------|----------|\n'
        while IFS= read -r line; do
            if [[ "$line" =~ \"path\":\"([^\"]*)\" ]]; then
                local path="${BASH_REMATCH[1]}"
                local purpose
                purpose=$(printf '%s' "$line" | sed 's/.*"purpose":"\([^"]*\)".*/\1/')
                printf '| %s | %s |\n' "$path" "$purpose"
            fi
        done < "$cfg_file"
        return 0
    fi

    # Legacy fallback
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0
    _index_extract_section "$index_file" "Configuration Files" 0
}

# read_index_tests — Returns test infrastructure summary.
# Args: $1 = project directory
# Output: Formatted test summary
read_index_tests() {
    local project_dir="$1"
    local test_file="${project_dir}/.claude/index/tests.json"

    if [[ -f "$test_file" ]]; then
        local output=""
        local test_count frameworks

        test_count=$(grep '"test_file_count"' "$test_file" 2>/dev/null | \
            sed 's/.*"test_file_count": *\([0-9]*\).*/\1/' || echo "0")
        frameworks=$(grep -o '"[a-z-]*"' "$test_file" 2>/dev/null | \
            grep -v '"test_dirs"\|"test_file_count"\|"frameworks"\|"coverage"\|"path"\|"file_count"' | \
            tr -d '"' | paste -sd', ' || true)

        output+="**Test files:** ${test_count}"$'\n'
        [[ -n "$frameworks" ]] && output+="**Frameworks:** ${frameworks}"$'\n'

        # Test directories
        local in_dirs=false
        while IFS= read -r line; do
            if [[ "$line" == *'"test_dirs"'* ]]; then
                in_dirs=true; continue
            fi
            [[ "$in_dirs" != true ]] && continue
            [[ "$line" == *']'* ]] && { in_dirs=false; continue; }

            if [[ "$line" =~ \"path\":\"([^\"]*)\" ]]; then
                local dir="${BASH_REMATCH[1]}"
                local cnt
                cnt=$(printf '%s' "$line" | sed 's/.*"file_count":\([0-9]*\).*/\1/')
                output+="- ${dir} (${cnt} files)"$'\n'
            fi
        done < "$test_file"

        printf '%s' "$output"
        return 0
    fi

    # Legacy fallback
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0
    _index_extract_section "$index_file" "Test Infrastructure" 0
}

# read_index_samples — Returns sampled file content.
# Args: $1 = project directory, $2 = max_total_chars (optional)
# Output: Formatted sample blocks (markdown fenced)
read_index_samples() {
    local project_dir="$1"
    local max_chars="${2:-0}"
    local manifest="${project_dir}/.claude/index/samples/manifest.json"

    if [[ -f "$manifest" ]]; then
        local used=0 output=""
        while IFS= read -r line; do
            [[ "$line" =~ \"original\":\"([^\"]*)\" ]] || continue
            local orig="${BASH_REMATCH[1]}"
            local stored
            stored=$(printf '%s' "$line" | sed 's/.*"stored":"\([^"]*\)".*/\1/')
            local sample_file="${project_dir}/.claude/index/samples/${stored}"
            [[ ! -f "$sample_file" ]] && continue

            local content
            content=$(cat "$sample_file")
            local content_size=${#content}

            if [[ "$max_chars" -gt 0 ]]; then
                local remaining=$((max_chars - used))
                [[ "$remaining" -le 100 ]] && break
                if [[ "$content_size" -gt "$remaining" ]]; then
                    content="${content:0:$remaining}"
                    content="${content%$'\n'*}"
                fi
            fi

            local ext="${orig##*.}"
            output+="### ${orig}"$'\n\n'
            output+='```'"${ext}"$'\n'
            output+="${content}"$'\n'
            output+='```'$'\n\n'
            used=$((used + ${#content} + ${#orig} + 20))
        done < "$manifest"

        printf '%s' "$output"
        return 0
    fi

    # Legacy fallback
    local index_file="${project_dir}/${PROJECT_INDEX_FILE}"
    [[ ! -f "$index_file" ]] && return 0
    _index_extract_section "$index_file" "Sampled File Content" 0
}

# --- Budget-bounded summary ---------------------------------------------------

# read_index_summary — Returns a bounded summary for prompt injection.
# Assembles a prompt-ready project summary within a caller-specified character
# budget. Uses the used+remaining pattern for budget tracking.
#
# Priority allocation:
#   1. Always: meta header (~200 chars), tree (first 100 lines), test summary
#   2. Fill: dependencies, configs, top-50 inventory (large/huge first), samples
#
# Args: $1 = project directory, $2 = max_chars (total budget)
# Output: Abbreviated project summary within budget
read_index_summary() {
    local project_dir="$1"
    local max_chars="${2:-8000}"
    local used=0
    local output=""

    # --- Always included: meta header ---
    local meta_block=""
    local meta_raw
    meta_raw=$(read_index_meta "$project_dir")
    if [[ -n "$meta_raw" ]]; then
        local project_name="" file_count="" total_lines="" scan_date=""
        while IFS='=' read -r key value; do
            case "$key" in
                project_name) project_name="$value" ;;
                file_count)   file_count="$value" ;;
                total_lines)  total_lines="$value" ;;
                scan_date)    scan_date="$value" ;;
            esac
        done <<< "$meta_raw"
        meta_block="# Project: ${project_name:-unknown}"$'\n'
        meta_block+="**Files:** ${file_count:-0} | **Lines:** ${total_lines:-0}"
        [[ -n "$scan_date" ]] && meta_block+=" | **Scanned:** ${scan_date}"
        meta_block+=$'\n\n'
    fi
    output+="$meta_block"
    used=${#output}

    # --- Always included: tree (first 100 lines) ---
    local remaining=$((max_chars - used))
    if [[ "$remaining" -gt 500 ]]; then
        local tree
        tree=$(read_index_tree "$project_dir" 100)
        if [[ -n "$tree" ]]; then
            local tree_block="## Directory Tree"$'\n\n'"${tree}"$'\n\n'
            if [[ ${#tree_block} -gt "$remaining" ]]; then
                tree_block="${tree_block:0:$remaining}"
                tree_block="${tree_block%$'\n'*}"$'\n\n'
            fi
            output+="$tree_block"
            used=${#output}
        fi
    fi

    # --- Always included: test summary ---
    remaining=$((max_chars - used))
    if [[ "$remaining" -gt 200 ]]; then
        local tests
        tests=$(read_index_tests "$project_dir")
        if [[ -n "$tests" ]]; then
            local test_block="## Test Infrastructure"$'\n\n'"${tests}"$'\n\n'
            if [[ ${#test_block} -gt 800 ]] && [[ ${#test_block} -gt "$remaining" ]]; then
                test_block="${test_block:0:800}"
                test_block="${test_block%$'\n'*}"$'\n\n'
            fi
            output+="$test_block"
            used=${#output}
        fi
    fi

    # --- Priority fill: dependencies ---
    remaining=$((max_chars - used))
    if [[ "$remaining" -gt 300 ]]; then
        local deps
        deps=$(read_index_dependencies "$project_dir")
        if [[ -n "$deps" ]]; then
            local dep_block="## Dependencies"$'\n\n'"${deps}"$'\n\n'
            if [[ ${#dep_block} -gt "$remaining" ]]; then
                dep_block="${dep_block:0:$remaining}"
                dep_block="${dep_block%$'\n'*}"$'\n\n'
            fi
            output+="$dep_block"
            used=${#output}
        fi
    fi

    # --- Priority fill: configs ---
    remaining=$((max_chars - used))
    if [[ "$remaining" -gt 300 ]]; then
        local cfgs
        cfgs=$(read_index_configs "$project_dir")
        if [[ -n "$cfgs" ]]; then
            local cfg_block="## Configuration Files"$'\n\n'"${cfgs}"$'\n\n'
            if [[ ${#cfg_block} -gt "$remaining" ]]; then
                cfg_block="${cfg_block:0:$remaining}"
                cfg_block="${cfg_block%$'\n'*}"$'\n\n'
            fi
            output+="$cfg_block"
            used=${#output}
        fi
    fi

    # --- Priority fill: inventory (large/huge first, then all, up to 50) ---
    remaining=$((max_chars - used))
    if [[ "$remaining" -gt 500 ]]; then
        local inv=""
        # Large/huge files first
        inv=$(read_index_inventory "$project_dir" 50 "size:large,huge")
        # If few large files, supplement with all files
        local inv_lines
        inv_lines=$(printf '%s\n' "$inv" | wc -l | tr -d '[:space:]')
        if [[ "$inv_lines" -lt 12 ]]; then
            inv=$(read_index_inventory "$project_dir" 50)
        fi
        if [[ -n "$inv" ]]; then
            local inv_block="## File Inventory (top files)"$'\n\n'"${inv}"$'\n\n'
            if [[ ${#inv_block} -gt "$remaining" ]]; then
                inv_block="${inv_block:0:$remaining}"
                inv_block="${inv_block%$'\n'*}"$'\n\n'
            fi
            output+="$inv_block"
            used=${#output}
        fi
    fi

    # --- Priority fill: samples with remaining budget ---
    remaining=$((max_chars - used))
    if [[ "$remaining" -gt 500 ]]; then
        local samples
        samples=$(read_index_samples "$project_dir" "$remaining")
        if [[ -n "$samples" ]]; then
            local sample_block="## Sampled File Content"$'\n\n'"${samples}"
            if [[ ${#sample_block} -gt "$remaining" ]]; then
                sample_block="${sample_block:0:$remaining}"
                sample_block="${sample_block%$'\n'*}"$'\n'
            fi
            output+="$sample_block"
        fi
    fi

    printf '%s' "$output"
}

# --- Internal helpers ---------------------------------------------------------

# _index_extract_section — Extract content of a ## section from project index file.
# Args: $1 = file, $2 = section heading (without ##), $3 = max_lines (0=unlimited)
_index_extract_section() {
    local file="$1"
    local heading="$2"
    local max_lines="${3:-0}"
    local in_section=false
    local content=""

    while IFS= read -r line; do
        if [[ "$in_section" == true ]]; then
            if [[ "$line" =~ ^##\  ]]; then
                break
            fi
            content+="${line}"$'\n'
        fi
        if [[ "$line" == "## ${heading}" ]]; then
            in_section=true
        fi
    done < "$file"

    # Trim leading/trailing blank lines
    content=$(printf '%s' "$content" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')

    if [[ "$max_lines" -gt 0 ]] && [[ -n "$content" ]]; then
        printf '%s\n' "$content" | head -"$max_lines"
    else
        printf '%s' "$content"
    fi
}
