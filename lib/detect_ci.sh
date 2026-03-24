#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_ci.sh — CI/CD config parsing (Milestone 12)
#
# Parses CI/CD configuration files to extract build/test/lint commands,
# language versions, and deployment targets. Read-only: never executes
# CI commands, never reads secrets.
#
# Sourced by tekhton.sh — do not run directly.
# Provides: detect_ci_config()
# =============================================================================

# detect_ci_config — Parses CI/CD configs for build/test/lint commands.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per finding: CI_SYSTEM|BUILD_CMD|TEST_CMD|LINT_CMD|DEPLOY_TARGET|_LANG|CONFIDENCE
detect_ci_config() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    _detect_github_actions "$proj_dir"
    _detect_gitlab_ci "$proj_dir"
    _detect_circleci "$proj_dir"
    _detect_jenkinsfile "$proj_dir"
    _detect_bitbucket_pipelines "$proj_dir"
    _detect_dockerfile_langs "$proj_dir"
}

# --- GitHub Actions ----------------------------------------------------------

_detect_github_actions() {
    local proj_dir="$1"
    local workflows_dir="$proj_dir/.github/workflows"
    [[ ! -d "$workflows_dir" ]] && return 0

    local wf
    while IFS= read -r wf; do
        [[ -z "$wf" ]] && continue
        _parse_github_workflow "$wf"
    done < <(find "$workflows_dir" -maxdepth 1 \( -name "*.yml" -o -name "*.yaml" \) 2>/dev/null | head -10)
}

_parse_github_workflow() {
    local file="$1"
    local deploy_target=""

    local line
    while IFS= read -r line; do
        # Skip secrets/env references (intentional literal $ match — SC2016)
        # shellcheck disable=SC2016
        [[ "$line" == *'${{secrets'* ]] && continue
        # shellcheck disable=SC2016
        [[ "$line" == *'${{ secrets'* ]] && continue

        # run: commands — extract build/test/lint
        if [[ "$line" =~ run:[[:space:]]*(.*) ]]; then
            local cmd="${BASH_REMATCH[1]}"
            cmd=$(echo "$cmd" | sed 's/^[|>-]*//' | tr -d '"' | sed 's/^[[:space:]]*//')
            [[ -z "$cmd" ]] && continue

            _classify_ci_command "github-actions" "$cmd"
        fi

        # Deployment targets
        if [[ "$line" == *"deploy"* ]] || [[ "$line" == *"publish"* ]]; then
            if [[ "$line" == *"aws"* ]] || [[ "$line" == *"s3"* ]]; then
                deploy_target="aws"
            elif [[ "$line" == *"gcloud"* ]] || [[ "$line" == *"gcp"* ]]; then
                deploy_target="gcp"
            elif [[ "$line" == *"azure"* ]]; then
                deploy_target="azure"
            elif [[ "$line" == *"heroku"* ]]; then
                deploy_target="heroku"
            elif [[ "$line" == *"vercel"* ]]; then
                deploy_target="vercel"
            elif [[ "$line" == *"netlify"* ]]; then
                deploy_target="netlify"
            fi
        fi
    done < "$file"

    # Emit deploy target if found
    if [[ -n "$deploy_target" ]]; then
        echo "github-actions||||${deploy_target}||medium"
    fi
}

# --- GitLab CI ---------------------------------------------------------------

_detect_gitlab_ci() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/.gitlab-ci.yml" ]] && return 0

    local line
    while IFS= read -r line; do
        # shellcheck disable=SC2016
        [[ "$line" == *'$CI_'* ]] && continue
        # shellcheck disable=SC2016
        [[ "$line" == *'${'* ]] && continue

        if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
            local cmd="${BASH_REMATCH[1]}"
            cmd=$(echo "$cmd" | tr -d '"' | sed 's/^[[:space:]]*//')
            [[ -z "$cmd" ]] && continue
            _classify_ci_command "gitlab-ci" "$cmd"
        fi
    done < "$proj_dir/.gitlab-ci.yml"
}

# --- CircleCI ----------------------------------------------------------------

_detect_circleci() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/.circleci/config.yml" ]] && return 0

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ command:[[:space:]]*(.*) ]]; then
            local cmd="${BASH_REMATCH[1]}"
            cmd=$(echo "$cmd" | tr -d '"' | sed 's/^[[:space:]]*//')
            [[ -z "$cmd" ]] && continue
            _classify_ci_command "circleci" "$cmd"
        fi
        if [[ "$line" =~ run:[[:space:]]*(.*) ]]; then
            local cmd="${BASH_REMATCH[1]}"
            # Skip if it's a mapping key (run: with nested keys)
            [[ "$cmd" =~ ^[[:space:]]*$ ]] && continue
            cmd=$(echo "$cmd" | tr -d '"' | sed 's/^[[:space:]]*//')
            [[ -z "$cmd" ]] && continue
            [[ "$cmd" == "name:"* ]] && continue
            _classify_ci_command "circleci" "$cmd"
        fi
    done < "$proj_dir/.circleci/config.yml"
}

# --- Jenkinsfile -------------------------------------------------------------

_detect_jenkinsfile() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/Jenkinsfile" ]] && return 0

    # Only parse obvious sh/bat commands inside pipeline blocks
    local line
    while IFS= read -r line; do
        if [[ "$line" =~ sh[[:space:]]+[\"\'](.*)[\"\'] ]]; then
            local cmd="${BASH_REMATCH[1]}"
            [[ -z "$cmd" ]] && continue
            _classify_ci_command "jenkins" "$cmd"
        fi
    done < "$proj_dir/Jenkinsfile"
}

# --- Bitbucket Pipelines ----------------------------------------------------

_detect_bitbucket_pipelines() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/bitbucket-pipelines.yml" ]] && return 0

    local line
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]+-[[:space:]]+(.*) ]]; then
            local cmd="${BASH_REMATCH[1]}"
            cmd=$(echo "$cmd" | tr -d '"' | sed 's/^[[:space:]]*//')
            [[ -z "$cmd" ]] && continue
            # Skip pipe references
            [[ "$cmd" == "pipe:"* ]] && continue
            _classify_ci_command "bitbucket" "$cmd"
        fi
    done < "$proj_dir/bitbucket-pipelines.yml"
}

# --- Dockerfile language detection (nullglob for safe glob iteration) --------

_detect_dockerfile_langs() {
    local proj_dir="$1"
    shopt -s nullglob
    local dockerfile
    for dockerfile in "$proj_dir"/Dockerfile "$proj_dir"/Dockerfile.*; do
        [[ ! -f "$dockerfile" ]] && continue
        local full="$dockerfile"
        local from_line
        from_line=$(grep -i '^FROM' "$full" 2>/dev/null | head -1 || true)
        [[ -z "$from_line" ]] && continue

        local image
        image=$(echo "$from_line" | awk '{print $2}' | cut -d: -f1)
        case "$image" in
            *node*) echo "dockerfile||||node||medium" ;;
            *python*) echo "dockerfile||||python||medium" ;;
            *golang*|*go*) echo "dockerfile||||go||medium" ;;
            *rust*) echo "dockerfile||||rust||medium" ;;
            *ruby*) echo "dockerfile||||ruby||medium" ;;
        esac
    done
    shopt -u nullglob
}

# --- Command classification --------------------------------------------------

# _classify_ci_command — Classifies a CI command as build/test/lint.
# Args: $1 = CI system name, $2 = command string
# Output: One line per classification: CI_SYSTEM|BUILD_CMD|TEST_CMD|LINT_CMD|DEPLOY_TARGET|_LANG|CONFIDENCE
_classify_ci_command() {
    local ci_system="$1"
    local cmd="$2"

    # Normalize: strip leading sudo, env vars, etc.
    local norm_cmd
    norm_cmd=$(echo "$cmd" | sed 's/^sudo //' | sed 's/^[A-Z_]*=[^ ]* //')

    # Test commands
    if [[ "$norm_cmd" == *"test"* ]] || [[ "$norm_cmd" == *"pytest"* ]] || \
       [[ "$norm_cmd" == *"jest"* ]] || [[ "$norm_cmd" == *"vitest"* ]] || \
       [[ "$norm_cmd" == *"rspec"* ]] || [[ "$norm_cmd" == *"cargo test"* ]] || \
       [[ "$norm_cmd" == *"go test"* ]] || [[ "$norm_cmd" == *"dotnet test"* ]]; then
        # Skip install/setup commands that happen to contain "test"
        if [[ "$norm_cmd" != *"install"* ]] && [[ "$norm_cmd" != *"setup"* ]] && \
           [[ "$norm_cmd" != *"npm ci"* ]]; then
            echo "${ci_system}||${cmd}||||high"
        fi
        return 0
    fi

    # Lint/analyze commands
    if [[ "$norm_cmd" == *"lint"* ]] || [[ "$norm_cmd" == *"eslint"* ]] || \
       [[ "$norm_cmd" == *"ruff"* ]] || [[ "$norm_cmd" == *"flake8"* ]] || \
       [[ "$norm_cmd" == *"clippy"* ]] || [[ "$norm_cmd" == *"golangci-lint"* ]] || \
       [[ "$norm_cmd" == *"rubocop"* ]] || [[ "$norm_cmd" == *"prettier"* ]] || \
       [[ "$norm_cmd" == *"black --check"* ]] || [[ "$norm_cmd" == *"go vet"* ]] || \
       [[ "$norm_cmd" == *"shellcheck"* ]] || [[ "$norm_cmd" == *"analyze"* ]]; then
        echo "${ci_system}|||${cmd}|||high"
        return 0
    fi

    # Build commands
    if [[ "$norm_cmd" == *"build"* ]] || [[ "$norm_cmd" == *"compile"* ]] || \
       [[ "$norm_cmd" == *"cargo build"* ]] || [[ "$norm_cmd" == *"go build"* ]] || \
       [[ "$norm_cmd" == *"dotnet build"* ]] || [[ "$norm_cmd" == *"mvn package"* ]] || \
       [[ "$norm_cmd" == *"gradlew build"* ]]; then
        # Skip install/setup
        if [[ "$norm_cmd" != *"install"* ]] && [[ "$norm_cmd" != *"npm ci"* ]]; then
            echo "${ci_system}|${cmd}|||||high"
        fi
        return 0
    fi
}
