#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight_checks.sh — Pre-flight checks: dependencies, tools, generated code,
#                        environment variables
#
# Sourced by tekhton.sh after preflight.sh — do not run directly.
# Provides: _preflight_check_dependencies, _preflight_check_tools,
#           _preflight_check_generated_code, _preflight_check_env_vars
# Depends on: preflight.sh (_pf_record, _pf_try_fix, _pf_has_language,
#             _pf_detect_test_frameworks)
#
# Extracted from preflight.sh to keep files under the 300-line ceiling.
# =============================================================================

# =============================================================================
# Check 1: Dependency Freshness
# =============================================================================
_preflight_check_dependencies() {
    local proj="${PROJECT_DIR:-.}"

    # Node.js
    if [[ -f "$proj/package-lock.json" ]] || [[ -f "$proj/yarn.lock" ]] || [[ -f "$proj/pnpm-lock.yaml" ]]; then
        if [[ ! -d "$proj/node_modules" ]]; then
            _pf_try_fix "npm install" "Dependencies (node_modules)" \
                "node_modules/ is missing but a lock file exists." || true
        elif [[ -f "$proj/package-lock.json" ]] && [[ "$proj/package-lock.json" -nt "$proj/node_modules/.package-lock.json" ]] 2>/dev/null; then
            # Only flag if mtime differs (skip on identical — CI clones)
            if [[ -f "$proj/node_modules/.package-lock.json" ]]; then
                _pf_try_fix "npm install" "Dependencies (node_modules)" \
                    "node_modules is stale (lock file is newer)." || true
            else
                _pf_record "pass" "Dependencies (node_modules)" "node_modules exists."
            fi
        else
            _pf_record "pass" "Dependencies (node_modules)" "node_modules is up-to-date."
        fi
    fi

    # Python
    if _pf_has_language "python"; then
        local lock_file=""
        [[ -f "$proj/requirements.txt" ]] && lock_file="requirements.txt"
        [[ -f "$proj/poetry.lock" ]] && lock_file="poetry.lock"
        [[ -f "$proj/Pipfile.lock" ]] && lock_file="Pipfile.lock"

        if [[ -n "$lock_file" ]]; then
            local venv_dir=""
            [[ -d "$proj/.venv" ]] && venv_dir=".venv"
            [[ -d "$proj/venv" ]] && venv_dir="venv"

            if [[ -z "$venv_dir" ]]; then
                _pf_record "warn" "Dependencies (Python venv)" \
                    "No virtualenv found (.venv/ or venv/) but ${lock_file} exists."
            else
                _pf_record "pass" "Dependencies (Python)" \
                    "Virtualenv ${venv_dir}/ exists with ${lock_file}."
            fi
        fi
    fi

    # Go
    if [[ -f "$proj/go.sum" ]] && [[ -f "$proj/go.mod" ]]; then
        _pf_record "pass" "Dependencies (Go)" "go.sum exists."
    fi

    # Ruby
    if [[ -f "$proj/Gemfile.lock" ]]; then
        if [[ -d "$proj/vendor/bundle" ]]; then
            _pf_record "pass" "Dependencies (Ruby)" "vendor/bundle exists."
        elif _pf_has_language "ruby"; then
            _pf_record "warn" "Dependencies (Ruby)" \
                "Gemfile.lock exists but vendor/bundle/ not found. Consider: bundle install --path vendor/bundle"
        fi
    fi

    # Rust
    if [[ -f "$proj/Cargo.lock" ]] && [[ -f "$proj/Cargo.toml" ]]; then
        _pf_record "pass" "Dependencies (Rust)" "Cargo.lock exists."
    fi

    # PHP
    if [[ -f "$proj/composer.lock" ]]; then
        if [[ -f "$proj/vendor/autoload.php" ]]; then
            _pf_record "pass" "Dependencies (PHP)" "vendor/autoload.php exists."
        elif _pf_has_language "php"; then
            _pf_try_fix "composer install --no-interaction" "Dependencies (PHP)" \
                "composer.lock exists but vendor/autoload.php is missing." || true
        fi
    fi
}

# =============================================================================
# Check 2: Tool Availability
# =============================================================================
_preflight_check_tools() {
    local proj="${PROJECT_DIR:-.}"
    local test_fws
    test_fws=$(_pf_detect_test_frameworks)

    # Playwright
    if echo "$test_fws" | grep -qi "^playwright|" 2>/dev/null; then
        # Check for browser binaries in common cache locations
        local pw_cache="${PLAYWRIGHT_BROWSERS_PATH:-${HOME}/.cache/ms-playwright}"
        if [[ -d "$pw_cache" ]] && [[ -n "$(ls -A "$pw_cache" 2>/dev/null)" ]]; then
            _pf_record "pass" "Tools (Playwright)" "Playwright browsers found in ${pw_cache}."
        else
            _pf_try_fix "npx playwright install" "Tools (Playwright)" \
                "Playwright browsers not found." || true
        fi
    fi

    # Cypress
    if echo "$test_fws" | grep -qi "^cypress|" 2>/dev/null; then
        local cy_cache="${CYPRESS_CACHE_FOLDER:-${HOME}/.cache/Cypress}"
        if [[ -d "$cy_cache" ]] && [[ -n "$(ls -A "$cy_cache" 2>/dev/null)" ]]; then
            _pf_record "pass" "Tools (Cypress)" "Cypress binary cache found."
        else
            _pf_try_fix "npx cypress install" "Tools (Cypress)" \
                "Cypress binary cache not found." || true
        fi
    fi

    # Pipeline config commands
    local cmd_var cmd_val cmd_token
    for cmd_var in ANALYZE_CMD BUILD_CHECK_CMD TEST_CMD UI_TEST_CMD; do
        cmd_val="${!cmd_var:-}"
        [[ -z "$cmd_val" ]] && continue
        [[ "$cmd_val" == "true" ]] && continue  # Skip no-op default

        # Extract first token (the executable)
        cmd_token="${cmd_val%% *}"

        # Skip shell builtins and common wrappers
        case "$cmd_token" in
            true|false|echo|:) continue ;;
        esac

        if command -v "$cmd_token" &>/dev/null; then
            _pf_record "pass" "Tools (${cmd_var})" "\`${cmd_token}\` is available."
        else
            _pf_record "warn" "Tools (${cmd_var})" \
                "\`${cmd_token}\` (from ${cmd_var}) is not found in PATH."
        fi
    done
}

# =============================================================================
# Check 3: Generated Code Freshness
# =============================================================================
_preflight_check_generated_code() {
    local proj="${PROJECT_DIR:-.}"

    # Prisma
    if [[ -f "$proj/prisma/schema.prisma" ]]; then
        local prisma_client="$proj/node_modules/.prisma/client"
        if [[ -d "$prisma_client" ]]; then
            if [[ "$proj/prisma/schema.prisma" -nt "$prisma_client" ]] 2>/dev/null; then
                _pf_try_fix "npx prisma generate" "Generated Code (Prisma)" \
                    "prisma/schema.prisma is newer than generated client." || true
            else
                _pf_record "pass" "Generated Code (Prisma)" "Prisma client is up-to-date."
            fi
        elif [[ -d "$proj/node_modules" ]]; then
            _pf_try_fix "npx prisma generate" "Generated Code (Prisma)" \
                "Prisma schema exists but no generated client found." || true
        fi
    fi

    # GraphQL Codegen
    if [[ -f "$proj/codegen.yml" ]] || [[ -f "$proj/codegen.ts" ]] || [[ -f "$proj/codegen.yaml" ]]; then
        # Check if npm run codegen script exists
        if [[ -f "$proj/package.json" ]] && grep -q '"codegen"' "$proj/package.json" 2>/dev/null; then
            _pf_record "warn" "Generated Code (GraphQL)" \
                "GraphQL codegen config found. Run \`npm run codegen\` if generated types are stale."
        fi
    fi

    # Protobuf
    if compgen -G "$proj"/*.proto >/dev/null 2>&1 || compgen -G "$proj"/proto/*.proto >/dev/null 2>&1; then
        _pf_record "warn" "Generated Code (Protobuf)" \
            "Protobuf .proto files detected. Ensure generated code is up-to-date."
    fi
}

# =============================================================================
# Check 4: Environment Variables
# =============================================================================
_preflight_check_env_vars() {
    local proj="${PROJECT_DIR:-.}"
    local example_file=""

    for candidate in .env.example .env.template .env.sample; do
        [[ -f "$proj/$candidate" ]] && { example_file="$candidate"; break; }
    done
    [[ -z "$example_file" ]] && return 0

    if [[ ! -f "$proj/.env" ]]; then
        _pf_record "warn" "Environment Variables" \
            "${example_file} exists but .env does not. Copy and configure: \`cp ${example_file} .env\`"
        return 0
    fi

    # Check key presence only (never read values — security requirement)
    local missing=()
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        if ! grep -q "^${key}=" "$proj/.env" 2>/dev/null; then
            missing+=("$key")
        fi
    done < <(grep -oP '^[A-Z_][A-Z0-9_]*(?==)' "$proj/$example_file" 2>/dev/null || true)

    if [[ ${#missing[@]} -gt 0 ]]; then
        local missing_list
        missing_list=$(printf '%s, ' "${missing[@]}")
        missing_list="${missing_list%, }"
        _pf_record "warn" "Environment Variables" \
            ".env is missing key(s) from ${example_file}: ${missing_list}."
    else
        _pf_record "pass" "Environment Variables" \
            "All keys from ${example_file} are present in .env."
    fi
}
