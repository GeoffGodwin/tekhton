#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# index_view.sh — Markdown view generator for PROJECT_INDEX.md (Milestone 69)
#
# Reads structured data from .claude/index/ and writes a bounded, human-readable
# PROJECT_INDEX.md. Uses record selection (not truncation) when sections exceed
# their budget allocation.
#
# Sourced by tekhton.sh AFTER crawler.sh and index_reader.sh — do not run directly.
# Depends on: common.sh (log), crawler.sh (_json_escape, _budget_allocator)
# =============================================================================

# --- Main entry point ---------------------------------------------------------

# generate_project_index_view — Assembles PROJECT_INDEX.md from structured data.
# Args: $1 = project directory, $2 = budget in chars (default: PROJECT_INDEX_BUDGET)
# Output: Writes PROJECT_INDEX.md to project directory
generate_project_index_view() {
    local project_dir="${1:-.}"
    local budget_chars="${2:-${PROJECT_INDEX_BUDGET:-120000}}"
    local index_dir="${project_dir}/.claude/index"
    local index_file="${project_dir}/PROJECT_INDEX.md"

    if [[ ! -d "$index_dir" ]]; then
        warn "No structured index at ${index_dir} — cannot generate view"
        return 1
    fi

    # Render fixed sections within their budget allocations
    local header tree inventory deps configs tests
    header=$(_view_render_header "$index_dir")
    tree=$(_view_render_tree "$index_dir" $(( budget_chars * 10 / 100 )))
    inventory=$(_view_render_inventory "$index_dir" $(( budget_chars * 15 / 100 )))
    deps=$(_view_render_dependencies "$index_dir" $(( budget_chars * 10 / 100 )))
    configs=$(_view_render_configs "$index_dir" $(( budget_chars * 5 / 100 )))
    tests=$(_view_render_tests "$index_dir" $(( budget_chars * 5 / 100 )))

    # Calculate remaining budget for samples (base 55% + surplus from thin sections)
    local remaining_budget
    remaining_budget=$(_budget_allocator "$budget_chars" \
        "${#tree}" "${#inventory}" "${#deps}" "${#configs}" "${#tests}")

    local samples
    samples=$(_view_render_samples "$index_dir" "$remaining_budget")

    # Assemble full output
    local full_output=""
    full_output+="${header}"$'\n\n'
    full_output+="## Directory Tree"$'\n\n'"${tree}"$'\n\n'
    full_output+="## File Inventory"$'\n\n'"${inventory}"$'\n\n'
    full_output+="## Key Dependencies"$'\n\n'"${deps}"$'\n\n'
    full_output+="## Configuration Files"$'\n\n'"${configs}"$'\n\n'
    full_output+="## Test Infrastructure"$'\n\n'"${tests}"$'\n\n'
    full_output+="## Sampled File Content"$'\n\n'"${samples}"

    # Final budget enforcement — trim at last line boundary if over budget
    if [[ ${#full_output} -gt "$budget_chars" ]]; then
        full_output="${full_output:0:$budget_chars}"
        full_output="${full_output%$'\n'*}"
    fi

    # Atomic write: temp file then mv
    local tmp_file
    tmp_file=$(mktemp "${project_dir}/PROJECT_INDEX_XXXXXXXX.tmp")
    printf '%s\n' "$full_output" > "$tmp_file"
    mv "$tmp_file" "$index_file"
}

# --- Section renderers --------------------------------------------------------

# _view_render_header — Renders PROJECT_INDEX.md header from meta.json.
_view_render_header() {
    local index_dir="$1"
    local meta_file="${index_dir}/meta.json"
    local project_name="unknown" scan_date="" scan_commit="" file_count=0 total_lines=0 dq_score=0

    if [[ -f "$meta_file" ]]; then
        local key value
        while IFS= read -r line; do
            if [[ "$line" =~ \"([a-z_]+)\":[[:space:]]*\"([^\"]*)\" ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                case "$key" in
                    project_name) project_name="$value" ;;
                    scan_date)    scan_date="$value" ;;
                    scan_commit)  scan_commit="$value" ;;
                esac
            elif [[ "$line" =~ \"([a-z_]+)\":[[:space:]]*([0-9]+) ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"
                case "$key" in
                    file_count)        file_count="$value" ;;
                    total_lines)       total_lines="$value" ;;
                    doc_quality_score) dq_score="$value" ;;
                esac
            fi
        done < "$meta_file"
    fi

    local dq_line=""
    [[ "$dq_score" -gt 0 ]] 2>/dev/null && \
        dq_line=$'\n'"<!-- DOC_QUALITY_SCORE: ${dq_score} -->"

    cat <<EOF
# PROJECT_INDEX.md — ${project_name}

<!-- Last-Scan: ${scan_date} -->
<!-- Scan-Commit: ${scan_commit} -->
<!-- File-Count: ${file_count} -->
<!-- Total-Lines: ${total_lines} -->${dq_line}

**Project:** ${project_name}
**Scanned:** ${scan_date}
**Files:** ${file_count} | **Lines:** ${total_lines}
EOF
}

# _view_render_tree — Renders directory tree from tree.txt, capped at 300 lines.
# Args: $1 = index_dir, $2 = budget_chars
_view_render_tree() {
    local index_dir="$1"
    local budget="$2"
    local tree_file="${index_dir}/tree.txt"

    if [[ ! -s "$tree_file" ]]; then
        echo "(no directory tree available)"
        return
    fi

    local total_lines
    total_lines=$(wc -l < "$tree_file" | tr -d '[:space:]')
    local max_lines=300
    [[ "$total_lines" -le "$max_lines" ]] && max_lines="$total_lines"

    local content
    content=$(head -"$max_lines" "$tree_file")

    # Check budget — further trim if needed
    if [[ ${#content} -gt "$budget" ]]; then
        # Find how many lines fit within budget
        local lines_fit=0 accumulated=""
        while IFS= read -r line; do
            local next="${accumulated}${line}"$'\n'
            if [[ ${#next} -gt "$budget" ]]; then
                break
            fi
            accumulated="$next"
            lines_fit=$((lines_fit + 1))
        done < "$tree_file"
        content="$accumulated"
        local remaining=$((total_lines - lines_fit))
        if [[ "$remaining" -gt 0 ]]; then
            content+="... (${remaining} more lines — see .claude/index/tree.txt)"
        fi
    elif [[ "$total_lines" -gt "$max_lines" ]]; then
        local remaining=$((total_lines - max_lines))
        content+=$'\n'"... (${remaining} more lines — see .claude/index/tree.txt)"
    fi

    printf '%s' "$content"
}

# _view_render_inventory — Renders file inventory with smart selection.
# Sorts by size category (huge > large > medium > small > tiny), then selects
# records until budget is reached.
# Args: $1 = index_dir, $2 = budget_chars
_view_render_inventory() {
    local index_dir="$1"
    local budget="$2"
    local inv_file="${index_dir}/inventory.jsonl"

    if [[ ! -s "$inv_file" ]]; then
        echo "(no files inventoried)"
        return
    fi

    local total_records
    total_records=$(wc -l < "$inv_file" | tr -d '[:space:]')

    # Table header
    local output=""
    output+="| Path | Lines | Size |"$'\n'
    output+="|------|------:|------|"$'\n'
    local header_size=${#output}

    # Sort by size priority: huge=1, large=2, medium=3, small=4, tiny=5
    # Then read sorted records and select until budget
    local sorted_records
    sorted_records=$(awk '{
        if ($0 ~ /"size":"huge"/)   print "1\t" $0
        else if ($0 ~ /"size":"large"/)  print "2\t" $0
        else if ($0 ~ /"size":"medium"/) print "3\t" $0
        else if ($0 ~ /"size":"small"/)  print "4\t" $0
        else print "5\t" $0
    }' "$inv_file" | sort -t$'\t' -k1,1n | cut -f2-)

    local used=$header_size
    local included=0
    local prev_dir=""
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue

        local path="" lines="" size="" dir=""
        [[ "$line" =~ \"path\":\"([^\"]*)\" ]] && path="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"lines\":([0-9]+) ]] && lines="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"size\":\"([^\"]*)\" ]] && size="${BASH_REMATCH[1]}"
        [[ "$line" =~ \"dir\":\"([^\"]*)\" ]] && dir="${BASH_REMATCH[1]}"

        # Directory separator for readability
        local dir_line=""
        if [[ "$dir" != "$prev_dir" ]]; then
            if [[ -n "$prev_dir" ]]; then
                dir_line=$'\n'"| **${dir}/** | | |"$'\n'
            else
                dir_line="| **${dir}/** | | |"$'\n'
            fi
            prev_dir="$dir"
        fi

        local record_line="| ${path} | ${lines} | ${size} |"$'\n'
        local addition_size=$(( ${#dir_line} + ${#record_line} ))

        # Reserve space for the selection indicator
        if [[ $(( used + addition_size + 80 )) -gt "$budget" ]]; then
            break
        fi

        output+="${dir_line}${record_line}"
        used=$(( used + addition_size ))
        included=$((included + 1))
    done <<< "$sorted_records"

    local remaining=$((total_records - included))
    if [[ "$remaining" -gt 0 ]]; then
        output+=$'\n'"... and ${remaining} more files (see .claude/index/inventory.jsonl)"
    fi

    printf '%s' "$output"
}

# _view_render_dependencies — Renders dependency information from dependencies.json.
# Args: $1 = index_dir, $2 = budget_chars
_view_render_dependencies() {
    local index_dir="$1"
    local budget="$2"
    local dep_file="${index_dir}/dependencies.json"

    if [[ ! -f "$dep_file" ]]; then
        echo "(no package manifests detected)"
        return
    fi

    # Check for empty manifests
    if grep -q '"manifests": \[\]' "$dep_file" 2>/dev/null && \
       grep -q '"key_dependencies": \[\]' "$dep_file" 2>/dev/null; then
        echo "(no package manifests detected)"
        return
    fi

    local output=""

    # Pre-calculate total dependencies for later reference
    local total_deps
    total_deps=$(grep -c '"name"' "$dep_file" || true)

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

    # Parse key dependencies
    local dep_count=0
    local in_deps=false
    local used=${#output}
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
            local dep_line="- ${name} ${version}"$'\n'
            if [[ $(( used + ${#dep_line} )) -gt "$budget" ]]; then
                local skipped=$(( total_deps - dep_count ))
                [[ "$skipped" -gt 0 ]] && \
                    output+="... and ${skipped} more dependencies"$'\n'
                break
            fi
            output+="$dep_line"
            used=$(( used + ${#dep_line} ))
            dep_count=$((dep_count + 1))
        fi
    done < "$dep_file"

    [[ -z "$output" ]] && output="(no package manifests detected)"$'\n'
    printf '%s' "$output"
}

# _view_render_configs — Renders configuration files from configs.json.
# Args: $1 = index_dir, $2 = budget_chars
_view_render_configs() {
    local index_dir="$1"
    local budget="$2"
    local cfg_file="${index_dir}/configs.json"

    if [[ ! -f "$cfg_file" ]]; then
        echo "(no configuration files detected)"
        return
    fi

    # Check for empty configs
    if grep -q '"configs": \[\]' "$cfg_file" 2>/dev/null; then
        echo "(no configuration files detected)"
        return
    fi

    local output=""
    output+="| Config File | Purpose |"$'\n'
    output+="|-------------|---------|"$'\n'
    local used=${#output}
    local count=0

    # Pre-calculate total config files for later reference
    local total
    total=$(grep -c '"path"' "$cfg_file" || true)

    while IFS= read -r line; do
        if [[ "$line" =~ \"path\":\"([^\"]*)\" ]]; then
            local path="${BASH_REMATCH[1]}"
            local purpose
            purpose=$(printf '%s' "$line" | sed 's/.*"purpose":"\([^"]*\)".*/\1/')
            local cfg_line="| ${path} | ${purpose} |"$'\n'
            if [[ $(( used + ${#cfg_line} + 40 )) -gt "$budget" ]]; then
                local remaining=$(( total - count ))
                [[ "$remaining" -gt 0 ]] && \
                    output+="... and ${remaining} more config files"$'\n'
                break
            fi
            output+="$cfg_line"
            used=$(( used + ${#cfg_line} ))
            count=$((count + 1))
        fi
    done < "$cfg_file"

    printf '%s' "$output"
}

# _view_render_tests — Renders test infrastructure from tests.json.
# Args: $1 = index_dir, $2 = budget_chars
_view_render_tests() {
    local index_dir="$1"
    local budget="$2"
    local test_file="${index_dir}/tests.json"

    if [[ ! -f "$test_file" ]]; then
        echo "(no test infrastructure detected)"
        return
    fi

    local output=""

    # Test file count
    local test_count
    test_count=$(grep '"test_file_count"' "$test_file" 2>/dev/null | \
        sed 's/.*"test_file_count": *\([0-9]*\).*/\1/' || echo "0")
    output+="**Test files:** ${test_count}"$'\n'

    # Frameworks
    local frameworks=""
    if [[ -f "$test_file" ]]; then
        # Extract framework names from JSON array
        local in_fw=false
        while IFS= read -r line; do
            if [[ "$line" == *'"frameworks"'* ]]; then
                in_fw=true; continue
            fi
            [[ "$in_fw" != true ]] && continue
            [[ "$line" == *']'* ]] && break
            local fw
            fw=$(printf '%s' "$line" | tr -d '[:space:]",' )
            [[ -n "$fw" ]] && frameworks+="${fw}, "
        done < "$test_file"
        frameworks="${frameworks%, }"
    fi
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
            local dir_line="- ${dir} (${cnt} files)"$'\n'
            if [[ $(( ${#output} + ${#dir_line} )) -gt "$budget" ]]; then
                output+="... and more test directories (see .claude/index/tests.json)"$'\n'
                break
            fi
            output+="$dir_line"
        fi
    done < "$test_file"

    printf '%s' "$output"
}

# _view_render_samples — Renders sampled file content from samples/ directory.
# Includes complete samples only (no mid-file truncation).
# Args: $1 = index_dir, $2 = budget_chars
_view_render_samples() {
    local index_dir="$1"
    local budget="$2"
    local manifest="${index_dir}/samples/manifest.json"

    if [[ ! -f "$manifest" ]]; then
        echo "(no files sampled)"
        return
    fi

    local output="" used=0 included=0 total=0

    while IFS= read -r line; do
        [[ "$line" =~ \"original\":\"([^\"]*)\" ]] || continue
        total=$((total + 1))
    done < "$manifest"

    while IFS= read -r line; do
        [[ "$line" =~ \"original\":\"([^\"]*)\" ]] || continue
        local orig="${BASH_REMATCH[1]}"
        local stored
        stored=$(printf '%s' "$line" | sed 's/.*"stored":"\([^"]*\)".*/\1/')
        # Reject path traversal characters
        if [[ "$stored" == *".."* || "$stored" == *"/"* ]]; then
            continue
        fi
        local sample_file="${index_dir}/samples/${stored}"
        [[ ! -f "$sample_file" ]] && continue

        local content
        content=$(cat "$sample_file")
        local ext="${orig##*.}"

        # Build the complete sample block
        local block=""
        block+="### ${orig}"$'\n\n'
        block+='```'"${ext}"$'\n'
        block+="${content}"$'\n'
        block+='```'$'\n\n'

        # Check if entire sample fits — never truncate individual samples
        if [[ $(( used + ${#block} )) -gt "$budget" ]]; then
            continue  # Skip this sample, try smaller ones
        fi

        output+="$block"
        used=$(( used + ${#block} ))
        included=$((included + 1))
    done < "$manifest"

    local skipped=$((total - included))
    if [[ "$skipped" -gt 0 ]]; then
        output+="... (${skipped} more files available — sampled ${included} of ${total} candidates)"$'\n'
    fi

    [[ -z "$output" ]] && output="(no files sampled)"$'\n'
    printf '%s' "$output"
}
