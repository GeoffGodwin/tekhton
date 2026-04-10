#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# crawler_inventory_emitters.sh — JSON emitter functions for inventory data
#
# Sourced by crawler_inventory.sh — do not run directly.
# Depends on: common.sh (log, warn), _json_escape, _count_files_in_dir,
#             _config_purpose
# =============================================================================

# _emit_inventory_jsonl — Writes one JSONL record per tracked file.
# Fix for issue #4: writes directly to file (no O(n^2) string concatenation).
# Args: $1=project_dir, $2=file_list, $3=index_dir
_emit_inventory_jsonl() {
    local project_dir="$1" file_list="$2" index_dir="$3"
    local tmp_file
    tmp_file=$(mktemp "${index_dir}/inv_XXXXXXXX")

    if [[ -z "$file_list" ]]; then
        : > "$tmp_file"
        mv "$tmp_file" "${index_dir}/inventory.jsonl"
        return 0
    fi

    # Batch line counting (same xargs pattern as _crawl_file_inventory)
    local -A file_lines=()
    local line_data
    line_data=$(printf '%s\n' "$file_list" | while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        [[ -f "${project_dir}/${f}" ]] && printf '%s\n' "${project_dir}/${f}"
    done | xargs wc -l 2>/dev/null | grep -v ' total$' || true)

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local count path rel_path
        count=$(printf '%s' "$line" | awk '{print $1}')
        path=$(printf '%s' "$line" | awk '{$1=""; print substr($0,2)}')
        rel_path="${path#"${project_dir}/"}"
        file_lines[$rel_path]="$count"
    done <<< "$line_data"

    # Write JSONL — one record per file, directly to temp file
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local dir="${f%/*}"
        [[ "$dir" == "$f" ]] && dir="."
        local lines="${file_lines[$f]:-0}"
        local size_cat
        if [[ "$lines" -lt 50 ]]; then size_cat="tiny"
        elif [[ "$lines" -lt 200 ]]; then size_cat="small"
        elif [[ "$lines" -lt 500 ]]; then size_cat="medium"
        elif [[ "$lines" -lt 1000 ]]; then size_cat="large"
        else size_cat="huge"; fi
        printf '{"path":"%s","dir":"%s","lines":%s,"size":"%s"}\n' \
            "$(_json_escape "$f")" "$(_json_escape "$dir")" "$lines" "$size_cat"
    done <<< "$file_list" > "$tmp_file"

    mv "$tmp_file" "${index_dir}/inventory.jsonl"
}

# _emit_configs_json — Writes config file inventory as JSON.
# Args: $1=project_dir, $2=file_list, $3=index_dir
_emit_configs_json() {
    local project_dir="$1" file_list="$2" index_dir="$3"
    local tmp_file
    tmp_file=$(mktemp "${index_dir}/configs_XXXXXXXX")
    {
        printf '{\n  "configs": ['
        local first=true
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local purpose
            purpose=$(_config_purpose "$f")
            [[ -z "$purpose" ]] && continue
            [[ "$first" != true ]] && printf ','
            printf '\n    {"path":"%s","purpose":"%s"}' \
                "$(_json_escape "$f")" "$(_json_escape "$purpose")"
            first=false
        done < <(printf '%s\n' "$file_list" | sort)
        printf '\n  ]\n}\n'
    } > "$tmp_file"
    mv "$tmp_file" "${index_dir}/configs.json"
}

# _emit_tests_json — Writes test infrastructure data as JSON.
# Args: $1=project_dir, $2=file_list, $3=index_dir
_emit_tests_json() {
    local project_dir="$1" file_list="$2" index_dir="$3"
    local tmp_file
    tmp_file=$(mktemp "${index_dir}/tests_XXXXXXXX")

    # Test directories
    local test_dirs
    test_dirs=$(printf '%s\n' "$file_list" | grep -oE '^[^/]+/' | sort -u | \
        grep -iE '^(tests?|spec|__tests__|e2e|integration|cypress)/' || true)

    # Test file count
    local test_file_count
    test_file_count=$(printf '%s\n' "$file_list" | \
        grep -cE '\.(test|spec)\.[^.]+$|_test\.[^.]+$|test_[^/]+\.[^.]+$' || true)
    [[ -z "$test_file_count" ]] && test_file_count=0

    # Detect frameworks
    local -a frameworks=()
    if [[ -f "${project_dir}/package.json" ]]; then
        local pdeps
        pdeps=$(cat "${project_dir}/package.json" 2>/dev/null)
        echo "$pdeps" | grep -q '"jest"' && frameworks+=("jest")
        echo "$pdeps" | grep -q '"vitest"' && frameworks+=("vitest")
        echo "$pdeps" | grep -q '"mocha"' && frameworks+=("mocha")
        echo "$pdeps" | grep -q '"cypress"' && frameworks+=("cypress")
        echo "$pdeps" | grep -q '"playwright"' && frameworks+=("playwright")
    fi
    if [[ -f "${project_dir}/pytest.ini" ]] || [[ -f "${project_dir}/conftest.py" ]] || \
        grep -q 'pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
        frameworks+=("pytest")
    fi
    [[ -f "${project_dir}/Cargo.toml" ]] && frameworks+=("cargo-test")
    printf '%s\n' "$file_list" | grep -q '_test\.go$' && frameworks+=("go-test")

    # Detect coverage
    local -a coverage=()
    [[ -f "${project_dir}/.nycrc" || -f "${project_dir}/.nycrc.json" ]] && coverage+=("nyc")
    [[ -f "${project_dir}/.coveragerc" || -f "${project_dir}/coverage.xml" ]] && coverage+=("python-coverage")
    printf '%s\n' "$file_list" | grep -q 'codecov\|coveralls' && coverage+=("ci-coverage")

    # Assemble JSON
    {
        printf '{\n  "test_dirs": ['
        local first=true
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            local cnt
            cnt=$(_count_files_in_dir "$file_list" "$d")
            [[ "$first" != true ]] && printf ','
            printf '\n    {"path":"%s","file_count":%d}' "$(_json_escape "$d")" "$cnt"
            first=false
        done <<< "$test_dirs"
        printf '\n  ],\n  "test_file_count": %d,\n  "frameworks": [' "$test_file_count"
        first=true
        for fw in "${frameworks[@]+"${frameworks[@]}"}"; do
            [[ "$first" != true ]] && printf ','
            printf '"%s"' "$fw"; first=false
        done
        printf '],\n  "coverage": ['
        first=true
        for cov in "${coverage[@]+"${coverage[@]}"}"; do
            [[ "$first" != true ]] && printf ','
            printf '"%s"' "$cov"; first=false
        done
        printf ']\n}\n'
    } > "$tmp_file"
    mv "$tmp_file" "${index_dir}/tests.json"
}
