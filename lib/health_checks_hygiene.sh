#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# health_checks_hygiene.sh — Project hygiene dimension check
#
# Sourced by lib/health.sh — do not run directly.
# Extracted from health_checks_infra.sh to stay under the 300-line ceiling.
#
# Provides:
#   _check_project_hygiene  — .gitignore, CI, .env safety, README setup
# =============================================================================

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
