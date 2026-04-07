#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight_checks_env.sh — Pre-flight checks: runtime versions, ports,
#                            lock file freshness
#
# Sourced by tekhton.sh after preflight_checks.sh — do not run directly.
# Provides: _preflight_check_runtime_version, _preflight_check_ports,
#           _preflight_check_lock_freshness, _pf_is_port_in_use
# Depends on: preflight.sh (_pf_record, _pf_has_language)
#
# Extracted from preflight.sh to keep files under the 300-line ceiling.
# =============================================================================

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
    local cmd_var cmd_val
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
