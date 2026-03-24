#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# health_checks_infra.sh — Infrastructure dimension check functions
#
# Sourced by lib/health.sh — do not run directly.
# Each function outputs: DIMENSION|SCORE|DETAIL_JSON (pipe-delimited)
# All checks are read-only. They never run project code, never install
# dependencies, never execute test suites.
#
# Provides:
#   _check_dependency_health   — Lock files, dep counts, vulnerability scanner
#   _check_doc_quality         — Delegates to M12 assess_doc_quality()
#   _check_project_hygiene     — .gitignore, CI, .env safety, README setup
#
# Depends on helpers from health_checks.sh (sourced first):
#   _health_json_escape
#   _health_sample_files
# =============================================================================

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
