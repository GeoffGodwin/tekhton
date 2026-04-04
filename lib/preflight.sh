#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight.sh — Pre-flight environment validation
#
# Sourced by tekhton.sh — do not run directly.
# Provides: run_preflight_checks()
# Depends on: common.sh (log, warn, error, success), detect.sh, detect_test_frameworks.sh
#
# Milestone 55: Pre-flight Environment Validation.
#
# Runs fast, deterministic checks BEFORE agent invocation to catch environment
# issues (stale deps, missing tools, env vars, version mismatches) that would
# waste turns in the build gate. No network calls, no agent invocations.
# =============================================================================

# --- Preflight state ---------------------------------------------------------
_PF_PASS=0
_PF_WARN=0
_PF_FAIL=0
_PF_REMEDIATED=0
_PF_REPORT_LINES=()

# --- _pf_record --------------------------------------------------------------
# Records a check result and appends a report line.
# Args: $1=status (pass|warn|fail|fixed), $2=check_name, $3=detail
_pf_record() {
    local status="$1" name="$2" detail="$3"
    case "$status" in
        pass)  _PF_PASS=$((_PF_PASS + 1));  _PF_REPORT_LINES+=("### ✓ ${name}"); ;;
        warn)  _PF_WARN=$((_PF_WARN + 1));  _PF_REPORT_LINES+=("### ⚠ ${name}"); ;;
        fail)  _PF_FAIL=$((_PF_FAIL + 1));  _PF_REPORT_LINES+=("### ✗ ${name}"); ;;
        fixed) _PF_REMEDIATED=$((_PF_REMEDIATED + 1)); _PF_REPORT_LINES+=("### 🔧 ${name}"); ;;
    esac
    _PF_REPORT_LINES+=("${detail}")
    _PF_REPORT_LINES+=("")
}

# --- _pf_try_fix -------------------------------------------------------------
# Attempts auto-remediation of a safe issue. Returns 0 on success, 1 on failure.
# Args: $1=command, $2=check_name, $3=diagnosis
_pf_try_fix() {
    local cmd="$1" name="$2" diagnosis="$3"

    if [[ "${PREFLIGHT_AUTO_FIX:-true}" != "true" ]]; then
        _pf_record "fail" "$name" "${diagnosis} Auto-fix disabled."
        return 1
    fi

    if command -v _run_safe_remediation &>/dev/null; then
        local start_ts=$SECONDS
        _run_safe_remediation "$cmd" >/dev/null 2>&1 && {
            local dur=$(( SECONDS - start_ts ))
            _pf_record "fixed" "$name" "${diagnosis} Auto-fixed: \`${cmd}\` (${dur}s)"
            if command -v emit_event &>/dev/null; then
                emit_event "preflight_fix" "preflight" \
                    "check=${name} command=${cmd} duration_s=${dur}" "" "" "" > /dev/null 2>&1 || true
            fi
            return 0
        }
        _pf_record "fail" "$name" "${diagnosis} Auto-fix failed: \`${cmd}\`"
        return 1
    fi

    # No remediation engine available — report as failure
    _pf_record "fail" "$name" "${diagnosis} Fix: \`${cmd}\`"
    return 1
}

# --- _pf_detect_languages_cached ---------------------------------------------
# Calls detect_languages once and caches for this preflight run.
_PF_LANGUAGES=""
_pf_detect_languages() {
    if [[ -z "$_PF_LANGUAGES" ]]; then
        _PF_LANGUAGES=$(detect_languages "${PROJECT_DIR:-.}" 2>/dev/null || true)
    fi
    echo "$_PF_LANGUAGES"
}

# --- _pf_has_language --------------------------------------------------------
# Returns 0 if the given language was detected.
_pf_has_language() {
    local lang="$1"
    _pf_detect_languages | grep -qi "^${lang}|" 2>/dev/null
}

# --- _pf_detect_test_frameworks_cached ---------------------------------------
_PF_TEST_FWS=""
_pf_detect_test_frameworks() {
    if [[ -z "$_PF_TEST_FWS" ]]; then
        if command -v detect_test_frameworks &>/dev/null; then
            _PF_TEST_FWS=$(detect_test_frameworks "${PROJECT_DIR:-.}" 2>/dev/null || true)
        fi
    fi
    echo "$_PF_TEST_FWS"
}

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

# =============================================================================
# Check 5: Runtime Version
# =============================================================================
_preflight_check_runtime_version() {
    local proj="${PROJECT_DIR:-.}"

    # Node.js
    local node_ver_file=""
    [[ -f "$proj/.node-version" ]] && node_ver_file=".node-version"
    [[ -f "$proj/.nvmrc" ]] && node_ver_file=".nvmrc"

    if [[ -n "$node_ver_file" ]] && command -v node &>/dev/null; then
        local expected actual
        expected=$(tr -d 'v \n\r' < "$proj/$node_ver_file" | cut -d. -f1)
        actual=$(node --version 2>/dev/null | tr -d 'v' | cut -d. -f1)
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$expected" == "$actual" ]]; then
                _pf_record "pass" "Runtime Version (Node.js)" \
                    "${node_ver_file} requires ${expected}.x, running ${actual}.x. ✓"
            else
                _pf_record "warn" "Runtime Version (Node.js)" \
                    "${node_ver_file} requires ${expected}.x, but running ${actual}.x."
            fi
        fi
    fi

    # Python
    if [[ -f "$proj/.python-version" ]] && command -v python3 &>/dev/null; then
        local expected actual
        expected=$(tr -d ' \n\r' < "$proj/.python-version" | cut -d. -f1-2)
        actual=$(python3 --version 2>/dev/null | awk '{print $2}' | cut -d. -f1-2)
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$expected" == "$actual" ]]; then
                _pf_record "pass" "Runtime Version (Python)" \
                    ".python-version requires ${expected}, running ${actual}. ✓"
            else
                _pf_record "warn" "Runtime Version (Python)" \
                    ".python-version requires ${expected}, but running ${actual}."
            fi
        fi
    fi

    # Ruby
    if [[ -f "$proj/.ruby-version" ]] && command -v ruby &>/dev/null; then
        local expected actual
        expected=$(tr -d ' \n\r' < "$proj/.ruby-version" | cut -d. -f1-2)
        actual=$(ruby --version 2>/dev/null | awk '{print $2}' | cut -d. -f1-2)
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$expected" == "$actual" ]]; then
                _pf_record "pass" "Runtime Version (Ruby)" \
                    ".ruby-version requires ${expected}, running ${actual}. ✓"
            else
                _pf_record "warn" "Runtime Version (Ruby)" \
                    ".ruby-version requires ${expected}, but running ${actual}."
            fi
        fi
    fi

    # Go
    if [[ -f "$proj/.go-version" ]] && command -v go &>/dev/null; then
        local expected actual
        expected=$(tr -d ' \n\r' < "$proj/.go-version" | cut -d. -f1-2)
        actual=$(go version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$expected" == "$actual" ]]; then
                _pf_record "pass" "Runtime Version (Go)" \
                    ".go-version requires ${expected}, running ${actual}. ✓"
            else
                _pf_record "warn" "Runtime Version (Go)" \
                    ".go-version requires ${expected}, but running ${actual}."
            fi
        fi
    fi

    # Java
    if [[ -f "$proj/.java-version" ]] && command -v java &>/dev/null; then
        local expected actual
        expected=$(tr -d ' \n\r' < "$proj/.java-version" | cut -d. -f1)
        actual=$(java -version 2>&1 | head -1 | grep -oP '\d+' | head -1)
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$expected" == "$actual" ]]; then
                _pf_record "pass" "Runtime Version (Java)" \
                    ".java-version requires ${expected}, running ${actual}. ✓"
            else
                _pf_record "warn" "Runtime Version (Java)" \
                    ".java-version requires ${expected}, but running ${actual}."
            fi
        fi
    fi

    # Rust
    if [[ -f "$proj/rust-toolchain.toml" ]] && command -v rustc &>/dev/null; then
        local expected actual
        expected=$(grep -oP 'channel\s*=\s*"\K[^"]+' "$proj/rust-toolchain.toml" 2>/dev/null || true)
        actual=$(rustc --version 2>/dev/null | awk '{print $2}')
        if [[ -n "$expected" ]] && [[ -n "$actual" ]]; then
            if [[ "$actual" == *"$expected"* ]]; then
                _pf_record "pass" "Runtime Version (Rust)" \
                    "rust-toolchain.toml channel ${expected}, running ${actual}. ✓"
            else
                _pf_record "warn" "Runtime Version (Rust)" \
                    "rust-toolchain.toml expects channel ${expected}, but running ${actual}."
            fi
        fi
    fi
}

# =============================================================================
# Check 6: Port Availability
# =============================================================================
_preflight_check_ports() {
    local proj="${PROJECT_DIR:-.}"

    # Identify ports from config commands
    local -a ports_to_check=()
    local cmd_val
    for cmd_var in UI_TEST_CMD BUILD_CHECK_CMD; do
        cmd_val="${!cmd_var:-}"
        [[ -z "$cmd_val" ]] && continue

        # Extract port from common dev server patterns
        case "$cmd_val" in
            *"next dev"*|*"next start"*)   ports_to_check+=(3000) ;;
            *"vite"*)                       ports_to_check+=(5173) ;;
            *"webpack-dev-server"*)         ports_to_check+=(8080) ;;
            *"ng serve"*)                   ports_to_check+=(4200) ;;
            *"flask run"*)                  ports_to_check+=(5000) ;;
            *"django"*|*"manage.py"*)       ports_to_check+=(8000) ;;
        esac

        # Also try to extract --port=NNNN or -p NNNN
        local extracted
        extracted=$(echo "$cmd_val" | grep -oP '(?:--port[= ]|[ ]-p[ ])\K\d+' 2>/dev/null || true)
        [[ -n "$extracted" ]] && ports_to_check+=("$extracted")
    done

    [[ ${#ports_to_check[@]} -eq 0 ]] && return 0

    local port
    for port in "${ports_to_check[@]}"; do
        if _pf_is_port_in_use "$port"; then
            _pf_record "warn" "Port Availability (:${port})" \
                "Port ${port} is already in use. This may cause conflicts with dev server."
        else
            _pf_record "pass" "Port Availability (:${port})" "Port ${port} is available."
        fi
    done
}

# --- _pf_is_port_in_use ------------------------------------------------------
# Returns 0 if port is in use, 1 otherwise. Platform-aware fallback.
_pf_is_port_in_use() {
    local port="$1"
    # Linux: ss
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null | grep -q ":${port} " && return 0
        return 1
    fi
    # macOS: lsof
    if command -v lsof &>/dev/null; then
        lsof -i ":${port}" -sTCP:LISTEN &>/dev/null && return 0
        return 1
    fi
    # No tool available — assume port is free
    return 1
}

# =============================================================================
# Check 7: Lock File Freshness
# =============================================================================
_preflight_check_lock_freshness() {
    local proj="${PROJECT_DIR:-.}"

    # Node.js: package.json newer than lock file
    if [[ -f "$proj/package.json" ]]; then
        local lock=""
        [[ -f "$proj/package-lock.json" ]] && lock="package-lock.json"
        [[ -f "$proj/yarn.lock" ]] && lock="yarn.lock"
        [[ -f "$proj/pnpm-lock.yaml" ]] && lock="pnpm-lock.yaml"

        if [[ -n "$lock" ]] && [[ "$proj/package.json" -nt "$proj/$lock" ]] 2>/dev/null; then
            _pf_record "warn" "Lock Freshness (Node.js)" \
                "package.json is newer than ${lock}. Dependencies may have been added. Consider: npm install"
        elif [[ -n "$lock" ]]; then
            _pf_record "pass" "Lock Freshness (Node.js)" "${lock} is up-to-date with package.json."
        fi
    fi

    # Python: pyproject.toml newer than lock
    if [[ -f "$proj/pyproject.toml" ]] && [[ -f "$proj/poetry.lock" ]]; then
        if [[ "$proj/pyproject.toml" -nt "$proj/poetry.lock" ]] 2>/dev/null; then
            _pf_record "warn" "Lock Freshness (Python)" \
                "pyproject.toml is newer than poetry.lock. Consider: poetry lock"
        fi
    fi

    # Ruby: Gemfile newer than Gemfile.lock
    if [[ -f "$proj/Gemfile" ]] && [[ -f "$proj/Gemfile.lock" ]]; then
        if [[ "$proj/Gemfile" -nt "$proj/Gemfile.lock" ]] 2>/dev/null; then
            _pf_record "warn" "Lock Freshness (Ruby)" \
                "Gemfile is newer than Gemfile.lock. Consider: bundle install"
        fi
    fi

    # Go: go.mod newer than go.sum
    if [[ -f "$proj/go.mod" ]] && [[ -f "$proj/go.sum" ]]; then
        if [[ "$proj/go.mod" -nt "$proj/go.sum" ]] 2>/dev/null; then
            _pf_record "warn" "Lock Freshness (Go)" \
                "go.mod is newer than go.sum. Consider: go mod tidy"
        fi
    fi
}

# =============================================================================
# Report Emitter
# =============================================================================
_emit_preflight_report() {
    local proj="${PROJECT_DIR:-.}"
    local report_file="$proj/PREFLIGHT_REPORT.md"
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "unknown")

    {
        echo "# Pre-flight Report — ${timestamp}"
        echo ""
        echo "## Summary"
        echo "✓ ${_PF_PASS} passed  ⚠ ${_PF_WARN} warned  ✗ ${_PF_FAIL} failed  🔧 ${_PF_REMEDIATED} auto-fixed"
        echo ""
        echo "## Checks"
        echo ""
        local line
        for line in "${_PF_REPORT_LINES[@]}"; do
            echo "$line"
        done

        # Emit services section if preflight_services.sh is loaded
        if command -v _pf_emit_services_report &>/dev/null; then
            _pf_emit_services_report
        fi
    } > "$report_file"
}

# =============================================================================
# Main Orchestrator
# =============================================================================
run_preflight_checks() {
    # Skip if disabled
    [[ "${PREFLIGHT_ENABLED:-true}" == "true" ]] || return 0

    log "Running pre-flight environment checks..."

    # Reset state
    _PF_PASS=0
    _PF_WARN=0
    _PF_FAIL=0
    _PF_REMEDIATED=0
    _PF_REPORT_LINES=()
    _PF_LANGUAGES=""
    _PF_TEST_FWS=""

    # Run all checks
    _preflight_check_dependencies
    _preflight_check_tools
    _preflight_check_generated_code
    _preflight_check_env_vars
    _preflight_check_runtime_version
    _preflight_check_ports
    _preflight_check_lock_freshness

    # Service readiness probing (M56) — requires preflight_services.sh
    if command -v _preflight_check_docker &>/dev/null; then
        _preflight_check_docker
        _preflight_check_services
        _preflight_check_dev_server
    fi

    # Skip report if nothing was checked
    local total=$(( _PF_PASS + _PF_WARN + _PF_FAIL + _PF_REMEDIATED ))
    if [[ "$total" -eq 0 ]]; then
        log "Pre-flight: no checks applicable (no ecosystem markers found)."
        return 0
    fi

    # Emit report
    _emit_preflight_report

    # Log summary
    local summary="Pre-flight: ${_PF_PASS} passed, ${_PF_WARN} warned, ${_PF_FAIL} failed, ${_PF_REMEDIATED} auto-fixed"
    if [[ "$_PF_FAIL" -gt 0 ]]; then
        error "$summary"
        error "Pre-flight failed: ${_PF_FAIL} blocking issue(s). See PREFLIGHT_REPORT.md."
        return 1
    elif [[ "$_PF_WARN" -gt 0 ]] && [[ "${PREFLIGHT_FAIL_ON_WARN:-false}" == "true" ]]; then
        warn "$summary"
        error "Pre-flight failed: PREFLIGHT_FAIL_ON_WARN is set. See PREFLIGHT_REPORT.md."
        return 1
    elif [[ "$_PF_WARN" -gt 0 ]]; then
        warn "$summary"
    else
        success "$summary"
    fi

    # Emit causal event
    if command -v emit_event &>/dev/null; then
        emit_event "preflight_complete" "preflight" \
            "pass=${_PF_PASS} warn=${_PF_WARN} fail=${_PF_FAIL} fixed=${_PF_REMEDIATED}" \
            "" "" "" > /dev/null 2>&1 || true
    fi

    return 0
}
