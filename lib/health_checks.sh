#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# health_checks.sh — Individual dimension check functions for project health
#
# Sourced by lib/health.sh — do not run directly.
# Each function outputs: DIMENSION|SCORE|DETAIL_JSON (pipe-delimited)
# All checks are read-only. They never run project code, never install
# dependencies, never execute test suites (unless HEALTH_RUN_TESTS=true).
#
# Provides:
#   _check_test_health         — Test file presence, naming, framework detection
#   _check_code_quality        — Linter config, TODO density, magic numbers
#   _check_dependency_health   — Lock files, dep counts, vulnerability scanner
#   _check_doc_quality         — Delegates to M12 assess_doc_quality()
#   _check_project_hygiene     — .gitignore, CI, .env safety, README setup
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

# --- Dependency Health (weight: 15%) -----------------------------------------

# _check_dependency_health PROJECT_DIR
# Evaluates lock file presence, dependency count ratio, vulnerability scanning.
_check_dependency_health() {
    local proj_dir="$1"
    local score=0

    # Sub-score: lock file exists (0-25)
    local lock_score=0
    local lock_file=""
    for f in package-lock.json yarn.lock pnpm-lock.yaml Pipfile.lock \
             poetry.lock Cargo.lock go.sum Gemfile.lock composer.lock; do
        if [[ -f "$proj_dir/$f" ]]; then
            lock_score=15
            lock_file="$f"
            break
        fi
    done

    # Lock file committed to git? (+10)
    if [[ -n "$lock_file" ]] && git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        if git -C "$proj_dir" ls-files --error-unmatch "$lock_file" &>/dev/null 2>&1; then
            lock_score=25
        fi
    fi

    # Sub-score: dependency count ratio (0-25)
    local dep_ratio_score=25
    local dep_count=0 src_count=0
    if [[ -f "$proj_dir/package.json" ]]; then
        dep_count=$(grep -cE '"[^"]+"\s*:' "$proj_dir/package.json" 2>/dev/null || true)
        # Rough: count deps + devDeps entries
        dep_count=$(( dep_count > 10 ? dep_count - 10 : 0 ))  # Subtract non-dep keys
    elif [[ -f "$proj_dir/pyproject.toml" ]]; then
        dep_count=$(grep -cE '^\s*"?[a-zA-Z]' "$proj_dir/pyproject.toml" 2>/dev/null || true)
    elif [[ -f "$proj_dir/go.mod" ]]; then
        dep_count=$(grep -c '^	' "$proj_dir/go.mod" 2>/dev/null || true)
    fi

    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        src_count=$(git -C "$proj_dir" ls-files 2>/dev/null | \
            grep -cE '\.(py|ts|tsx|js|jsx|go|rs|java|rb)$' || true)
    fi

    if [[ "$src_count" -gt 0 ]] && [[ "$dep_count" -gt 0 ]]; then
        local ratio=$(( (dep_count * 100) / src_count ))
        if [[ "$ratio" -gt 500 ]]; then dep_ratio_score=5
        elif [[ "$ratio" -gt 200 ]]; then dep_ratio_score=10
        elif [[ "$ratio" -gt 100 ]]; then dep_ratio_score=15
        elif [[ "$ratio" -gt 50 ]]; then dep_ratio_score=20
        fi
    fi

    # Sub-score: vulnerability scanner config (0-25)
    local vuln_score=0
    for f in .snyk snyk.yml .github/dependabot.yml renovate.json .github/renovate.json \
             .dependabot/config.yml .trivyignore; do
        if [[ -f "$proj_dir/$f" ]]; then
            vuln_score=25
            break
        fi
    done

    # Sub-score: manifest file exists (0-25)
    local manifest_score=0
    for f in package.json pyproject.toml setup.py setup.cfg Cargo.toml go.mod \
             Gemfile build.gradle pom.xml composer.json pubspec.yaml; do
        if [[ -f "$proj_dir/$f" ]]; then
            manifest_score=25
            break
        fi
    done

    score=$((lock_score + dep_ratio_score + vuln_score + manifest_score))
    [[ "$score" -gt 100 ]] && score=100

    local sub_scores="{\"lock_file\":${lock_score},\"dep_ratio\":${dep_ratio_score},\"vuln_scanner\":${vuln_score},\"manifest\":${manifest_score}}"

    echo "dependency_health|${score}|${sub_scores}"
}

# --- Documentation Quality (weight: 15%) -------------------------------------

# _check_doc_quality PROJECT_DIR
# Delegates to M12 assess_doc_quality() when available.
_check_doc_quality() {
    local proj_dir="$1"
    local score=0

    if command -v assess_doc_quality &>/dev/null 2>&1; then
        local dq_output
        dq_output=$(assess_doc_quality "$proj_dir" 2>/dev/null || true)
        if [[ -n "$dq_output" ]]; then
            score="${dq_output%%|*}"
            local details="${dq_output#*|}"
            echo "doc_quality|${score}|{\"source\":\"m12\",\"details\":\"$(_health_json_escape "$details")\"}"
            return 0
        fi
    fi

    # Fallback: lightweight doc checks
    local readme_score=0 contrib_score=0 arch_score=0 inline_score=0

    # README (0-30)
    for f in README.md README.rst README.txt README; do
        if [[ -f "$proj_dir/$f" ]]; then
            local lines
            lines=$(wc -l < "$proj_dir/$f" 2>/dev/null | tr -d '[:space:]')
            readme_score=10
            [[ "$lines" -gt 50 ]] && readme_score=20
            [[ "$lines" -gt 150 ]] && readme_score=30
            break
        fi
    done

    # Contributing guide (0-20)
    for f in CONTRIBUTING.md DEVELOPMENT.md docs/CONTRIBUTING.md .github/CONTRIBUTING.md; do
        if [[ -f "$proj_dir/$f" ]]; then
            contrib_score=20
            break
        fi
    done

    # Architecture docs (0-25)
    for f in ARCHITECTURE.md docs/ARCHITECTURE.md DESIGN.md docs/design.md; do
        if [[ -f "$proj_dir/$f" ]]; then
            arch_score=25
            break
        fi
    done

    # Inline docs presence (0-25)
    local sample
    sample=$(_health_sample_files "$proj_dir" 10)
    if [[ -n "$sample" ]]; then
        local doc_count=0 total_count=0
        while IFS= read -r f; do
            [[ -z "$f" ]] && continue
            local fpath="$proj_dir/$f"
            [[ ! -f "$fpath" ]] && continue
            total_count=$((total_count + 1))
            if grep -qE '"""|/\*\*|///|#\s+[A-Z]' "$fpath" 2>/dev/null; then
                doc_count=$((doc_count + 1))
            fi
        done <<< "$sample"
        if [[ "$total_count" -gt 0 ]]; then
            local pct=$(( (doc_count * 100) / total_count ))
            if [[ "$pct" -ge 60 ]]; then inline_score=25
            elif [[ "$pct" -ge 40 ]]; then inline_score=15
            elif [[ "$pct" -ge 20 ]]; then inline_score=10
            fi
        fi
    fi

    score=$((readme_score + contrib_score + arch_score + inline_score))
    [[ "$score" -gt 100 ]] && score=100

    local sub_scores="{\"source\":\"fallback\",\"readme\":${readme_score},\"contributing\":${contrib_score},\"architecture\":${arch_score},\"inline_docs\":${inline_score}}"

    echo "doc_quality|${score}|${sub_scores}"
}

# --- Project Hygiene (weight: 15%) -------------------------------------------

# _check_project_hygiene PROJECT_DIR
# Evaluates .gitignore coverage, .env safety, CI config, README setup, changelog.
_check_project_hygiene() {
    local proj_dir="$1"
    local score=0

    # Sub-score: .gitignore exists and covers common patterns (0-20)
    local gitignore_score=0
    if [[ -f "$proj_dir/.gitignore" ]]; then
        gitignore_score=10
        local patterns_found=0
        for pattern in node_modules __pycache__ .env vendor .venv build dist; do
            if grep -qF "$pattern" "$proj_dir/.gitignore" 2>/dev/null; then
                patterns_found=$((patterns_found + 1))
            fi
        done
        if [[ "$patterns_found" -ge 2 ]]; then
            gitignore_score=20
        fi
    fi

    # Sub-score: .env NOT committed to git (0-20, security check)
    local env_score=20
    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        # Only check if the FILENAME is tracked — never read .env contents
        if git -C "$proj_dir" ls-files --error-unmatch .env &>/dev/null 2>&1; then
            env_score=0  # .env is tracked — hygiene failure
        fi
    fi

    # Sub-score: CI/CD configured (0-20)
    local ci_score=0
    if command -v detect_ci_config &>/dev/null 2>&1; then
        local ci_out
        ci_out=$(detect_ci_config "$proj_dir" 2>/dev/null || true)
        if [[ -n "$ci_out" ]]; then
            ci_score=20
        fi
    else
        for f in .github/workflows .gitlab-ci.yml .circleci/config.yml \
                 Jenkinsfile .travis.yml bitbucket-pipelines.yml; do
            if [[ -e "$proj_dir/$f" ]]; then
                ci_score=20
                break
            fi
        done
    fi

    # Sub-score: README has setup/install instructions (0-20)
    local setup_score=0
    for f in README.md README.rst README; do
        if [[ -f "$proj_dir/$f" ]]; then
            if grep -qiE 'install|setup|getting.started|quick.start|how to run' "$proj_dir/$f" 2>/dev/null; then
                setup_score=20
            fi
            break
        fi
    done

    # Sub-score: CHANGELOG or release tags present (0-20)
    local changelog_score=0
    for f in CHANGELOG.md CHANGELOG CHANGES.md HISTORY.md RELEASES.md; do
        if [[ -f "$proj_dir/$f" ]]; then
            changelog_score=20
            break
        fi
    done
    if [[ "$changelog_score" -eq 0 ]] && git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        local tag_count
        tag_count=$(git -C "$proj_dir" tag 2>/dev/null | head -5 | wc -l | tr -d '[:space:]')
        if [[ "$tag_count" -gt 0 ]]; then
            changelog_score=15
        fi
    fi

    score=$((gitignore_score + env_score + ci_score + setup_score + changelog_score))
    [[ "$score" -gt 100 ]] && score=100

    local sub_scores="{\"gitignore\":${gitignore_score},\"env_safety\":${env_score},\"ci_cd\":${ci_score},\"setup_docs\":${setup_score},\"changelog\":${changelog_score}}"

    echo "project_hygiene|${score}|${sub_scores}"
}

# --- Shared helpers -----------------------------------------------------------

# _health_sample_files PROJECT_DIR COUNT
# Returns a deterministic sorted list of source files for sampling.
_health_sample_files() {
    local proj_dir="$1"
    local count="${2:-20}"

    local src_ext='(py|ts|tsx|js|jsx|go|rs|java|rb|cs|kt|swift|sh)$'

    if git -C "$proj_dir" rev-parse --git-dir &>/dev/null 2>&1; then
        git -C "$proj_dir" ls-files 2>/dev/null | \
            grep -E "\\.$src_ext" | \
            sort | \
            head -n "$count"
    else
        find "$proj_dir" -type f -not -path '*/.git/*' \
            -not -path '*/node_modules/*' -not -path '*/.venv/*' \
            -not -path '*/vendor/*' 2>/dev/null | \
            sed "s|^${proj_dir}/||" | \
            grep -E "\\.$src_ext" | \
            sort | \
            head -n "$count"
    fi
}

# _health_json_escape STRING
# Escapes a string for safe JSON embedding.
_health_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}
