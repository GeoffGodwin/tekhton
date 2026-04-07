#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# health_checks.sh — Core dimension check functions for project health
#
# Sourced by lib/health.sh — do not run directly.
# Each function outputs: DIMENSION|SCORE|DETAIL_JSON (pipe-delimited)
# All checks are read-only. They never run project code, never install
# dependencies, never execute test suites (unless HEALTH_RUN_TESTS=true).
#
# Provides:
#   _check_test_health   — Test file presence, naming, framework detection
#   _check_code_quality  — Linter config, TODO density, magic numbers
#
# Shared helpers (_health_sample_files, _health_json_escape) and
# infrastructure checks (_check_dependency_health, _check_doc_quality,
# _check_project_hygiene) live in lib/health_checks_infra.sh.
# =============================================================================

# --- Test Health (weight: 30%) -----------------------------------------------

# _check_test_health PROJECT_DIR
# Evaluates test infrastructure via file presence, naming conventions, and
# framework detection. Does NOT execute tests unless HEALTH_RUN_TESTS=true.
_check_test_health() {
    local proj_dir="$1"
    local score=0
    local sub_scores="{}"

    # Count source files and test files
    local source_files=0 test_files=0
    local test_pattern='(test_.*|.*_test|.*\.test|.*\.spec|.*_spec)\.'
    local file_list
    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        file_list=$(git -C "$proj_dir" ls-files 2>/dev/null | sort || true)
    else
        file_list=$(find "$proj_dir" -type f -not -path '*/.git/*' \
            -not -path '*/node_modules/*' -not -path '*/.venv/*' \
            -not -path '*/vendor/*' 2>/dev/null | \
            sed "s|^${proj_dir}/||" | sort || true)
    fi

    local src_ext_pattern='\.(py|ts|tsx|js|jsx|go|rs|java|rb|cs|kt|swift|sh|c|cpp|h)$'
    source_files=$(echo "$file_list" | grep -cE "$src_ext_pattern" || true)
    test_files=$(echo "$file_list" | grep -ciE "$test_pattern" || true)

    # Sub-score: test file ratio (0-30)
    local ratio_score=0
    if [[ "$source_files" -gt 0 ]] && [[ "$test_files" -gt 0 ]]; then
        local ratio=$(( (test_files * 100) / source_files ))
        if [[ "$ratio" -ge 50 ]]; then ratio_score=30
        elif [[ "$ratio" -ge 30 ]]; then ratio_score=25
        elif [[ "$ratio" -ge 20 ]]; then ratio_score=20
        elif [[ "$ratio" -ge 10 ]]; then ratio_score=15
        elif [[ "$ratio" -ge 5 ]]; then ratio_score=10
        else ratio_score=5
        fi
    fi

    # Sub-score: test command detected (0-20)
    local cmd_score=0
    if [[ -n "${TEST_CMD:-}" ]] && [[ "${TEST_CMD}" != "true" ]]; then
        cmd_score=20
    elif command -v detect_test_frameworks &>/dev/null 2>&1; then
        local fw_output
        fw_output=$(detect_test_frameworks "$proj_dir" 2>/dev/null || true)
        if [[ -n "$fw_output" ]]; then
            cmd_score=10
        fi
    fi

    # Sub-score: naming conventions consistent (0-20)
    local naming_score=0
    if [[ "$test_files" -gt 0 ]]; then
        # Check that test files follow a consistent pattern
        local prefix_count suffix_count spec_count
        prefix_count=$(echo "$file_list" | grep -cE '(^|/)test_' || true)
        suffix_count=$(echo "$file_list" | grep -cE '_test\.' || true)
        spec_count=$(echo "$file_list" | grep -cE '\.(spec|test)\.' || true)

        local max_pattern=0
        [[ "$prefix_count" -gt "$max_pattern" ]] && max_pattern="$prefix_count"
        [[ "$suffix_count" -gt "$max_pattern" ]] && max_pattern="$suffix_count"
        [[ "$spec_count" -gt "$max_pattern" ]] && max_pattern="$spec_count"

        if [[ "$test_files" -gt 0 ]]; then
            local consistency=$(( (max_pattern * 100) / test_files ))
            if [[ "$consistency" -ge 80 ]]; then naming_score=20
            elif [[ "$consistency" -ge 60 ]]; then naming_score=15
            elif [[ "$consistency" -ge 40 ]]; then naming_score=10
            else naming_score=5
            fi
        fi
    fi

    # Sub-score: test framework detected (0-15)
    local framework_score=0
    if command -v detect_test_frameworks &>/dev/null 2>&1; then
        local fw_out
        fw_out=$(detect_test_frameworks "$proj_dir" 2>/dev/null || true)
        if [[ -n "$fw_out" ]]; then
            framework_score=15
        fi
    else
        # Heuristic: check for common test framework config files
        for f in jest.config.js jest.config.ts vitest.config.ts pytest.ini \
                 setup.cfg pyproject.toml .rspec Cargo.toml go.mod; do
            if [[ -f "$proj_dir/$f" ]]; then
                framework_score=10
                break
            fi
        done
    fi

    # Sub-score: test execution (0-15) — only if HEALTH_RUN_TESTS=true
    local exec_score=0
    if [[ "${HEALTH_RUN_TESTS:-false}" == "true" ]] && \
       [[ -n "${TEST_CMD:-}" ]] && [[ "${TEST_CMD}" != "true" ]]; then
        local test_exit=0
        (cd "$proj_dir" && eval "$TEST_CMD" >/dev/null 2>&1) || test_exit=$?
        if [[ "$test_exit" -eq 0 ]]; then
            exec_score=15
        else
            exec_score=5  # Tests exist and run, just some fail
        fi
    fi

    score=$((ratio_score + cmd_score + naming_score + framework_score + exec_score))
    [[ "$score" -gt 100 ]] && score=100

    local note=""
    if [[ "${HEALTH_RUN_TESTS:-false}" != "true" ]]; then
        note="Estimated from file presence. Run with HEALTH_RUN_TESTS=true for actual pass rate."
    fi

    sub_scores="{\"ratio\":${ratio_score},\"command\":${cmd_score},\"naming\":${naming_score},\"framework\":${framework_score},\"execution\":${exec_score},\"test_files\":${test_files},\"source_files\":${source_files},\"note\":\"$(_health_json_escape "$note")\"}"

    echo "test_health|${score}|${sub_scores}"
}

# --- Code Quality (weight: 25%) ----------------------------------------------

# _check_code_quality PROJECT_DIR
# Evaluates linter config, TODO density, magic numbers, function length, type safety.
_check_code_quality() {
    local proj_dir="$1"
    local sample_size="${HEALTH_SAMPLE_SIZE:-20}"
    local score=0

    # Get deterministic sample of source files
    local sample_files
    sample_files=$(_health_sample_files "$proj_dir" "$sample_size")

    # Sub-score: linter config (0-20)
    local linter_score=0
    for f in .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml eslint.config.js \
             eslint.config.mjs .pylintrc .flake8 pyproject.toml setup.cfg \
             .rubocop.yml .golangci.yml .golangci.yaml clippy.toml \
             biome.json deno.json .prettierrc .prettierrc.js; do
        if [[ -f "$proj_dir/$f" ]]; then
            linter_score=20
            break
        fi
    done

    # Sub-score: pre-commit hooks (0-10)
    local precommit_score=0
    if [[ -f "$proj_dir/.pre-commit-config.yaml" ]] || \
       [[ -f "$proj_dir/.husky/pre-commit" ]] || \
       [[ -f "$proj_dir/.git/hooks/pre-commit" ]]; then
        precommit_score=10
    fi

    # Sub-score: TODO/FIXME density (0-20, inverse)
    local todo_score=20
    if [[ -n "$sample_files" ]]; then
        local total_lines=0 todo_count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fpath="$proj_dir/$f"
            [[ ! -f "$fpath" ]] && continue
            local lines
            lines=$(wc -l < "$fpath" 2>/dev/null | tr -d '[:space:]')
            total_lines=$((total_lines + lines))
            local todos
            todos=$(grep -ciE '\bTODO\b|\bFIXME\b|\bHACK\b|\bXXX\b' "$fpath" 2>/dev/null || true)
            todo_count=$((todo_count + todos))
        done <<< "$sample_files"

        if [[ "$total_lines" -gt 0 ]]; then
            local per_1000=$(( (todo_count * 1000) / total_lines ))
            if [[ "$per_1000" -ge 20 ]]; then todo_score=0
            elif [[ "$per_1000" -ge 10 ]]; then todo_score=5
            elif [[ "$per_1000" -ge 5 ]]; then todo_score=10
            elif [[ "$per_1000" -ge 2 ]]; then todo_score=15
            fi
        fi
    fi

    # Sub-score: magic number density (0-20, inverse)
    local magic_score=20
    if [[ -n "$sample_files" ]]; then
        local total_lines_m=0 magic_count=0
        # Common constants to exclude: 0, 1, -1, 2, 10, 100, 1000, 1024, 255, 256, 404, 200, 500
        local exclude_nums='^(0|1|2|3|10|16|32|64|100|128|200|255|256|404|500|1000|1024|8080|8443|3000|443|80)$'
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fpath="$proj_dir/$f"
            [[ ! -f "$fpath" ]] && continue
            local lines
            lines=$(wc -l < "$fpath" 2>/dev/null | tr -d '[:space:]')
            total_lines_m=$((total_lines_m + lines))
            # Count numeric literals that are NOT common constants
            # Focus on numbers appearing as arguments or in conditionals
            local nums
            nums=$(grep -oE '\b[0-9]{2,}\b' "$fpath" 2>/dev/null | \
                   grep -cvE "$exclude_nums" || true)
            magic_count=$((magic_count + nums))
        done <<< "$sample_files"

        if [[ "$total_lines_m" -gt 0 ]]; then
            local per_1000m=$(( (magic_count * 1000) / total_lines_m ))
            if [[ "$per_1000m" -ge 50 ]]; then magic_score=0
            elif [[ "$per_1000m" -ge 30 ]]; then magic_score=5
            elif [[ "$per_1000m" -ge 15 ]]; then magic_score=10
            elif [[ "$per_1000m" -ge 5 ]]; then magic_score=15
            fi
        fi
    fi

    # Sub-score: type safety (0-15)
    local type_score=0
    # Typed languages get full marks
    local has_typed=false
    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        local typed_count
        typed_count=$(git -C "$proj_dir" ls-files 2>/dev/null | \
            grep -cE '\.(ts|tsx|go|rs|java|cs|kt|swift)$' || true)
        if [[ "$typed_count" -gt 0 ]]; then
            has_typed=true
        fi
    fi
    if [[ "$has_typed" == true ]]; then
        type_score=15
    else
        # Check for TypeScript config (JS project using TS)
        if [[ -f "$proj_dir/tsconfig.json" ]]; then
            type_score=15
        # Check for Python type hints (mypy config or py.typed marker)
        elif [[ -f "$proj_dir/mypy.ini" ]] || [[ -f "$proj_dir/.mypy.ini" ]] || \
             grep -q 'mypy' "$proj_dir/pyproject.toml" 2>/dev/null; then
            type_score=10
        fi
    fi

    # Sub-score: function length (0-15)
    local length_score=15
    if [[ -n "$sample_files" ]]; then
        local long_funcs=0 total_funcs=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fpath="$proj_dir/$f"
            [[ ! -f "$fpath" ]] && continue
            # Heuristic: count function signatures and gaps between them
            local func_count
            func_count=$(grep -cE '^\s*(def |func |function |fn |public |private |protected |static )' "$fpath" 2>/dev/null || true)
            total_funcs=$((total_funcs + func_count))
            # Estimate long functions: files with few functions but many lines
            if [[ "$func_count" -gt 0 ]]; then
                local lines
                lines=$(wc -l < "$fpath" 2>/dev/null | tr -d '[:space:]')
                local avg_len=$((lines / func_count))
                if [[ "$avg_len" -gt 60 ]]; then
                    long_funcs=$((long_funcs + 1))
                fi
            fi
        done <<< "$sample_files"

        local sample_count
        [[ -z "$sample_files" ]] && sample_count=0 || sample_count=$(echo "$sample_files" | wc -l)
        if [[ "$sample_count" -gt 0 ]] && [[ "$long_funcs" -gt 0 ]]; then
            local long_pct=$(( (long_funcs * 100) / sample_count ))
            if [[ "$long_pct" -ge 50 ]]; then length_score=0
            elif [[ "$long_pct" -ge 30 ]]; then length_score=5
            elif [[ "$long_pct" -ge 15 ]]; then length_score=10
            fi
        fi
    fi

    score=$((linter_score + precommit_score + todo_score + magic_score + type_score + length_score))
    [[ "$score" -gt 100 ]] && score=100

    local sub_scores="{\"linter\":${linter_score},\"precommit\":${precommit_score},\"todo_density\":${todo_score},\"magic_numbers\":${magic_score},\"type_safety\":${type_score},\"function_length\":${length_score}}"

    echo "code_quality|${score}|${sub_scores}"
}
