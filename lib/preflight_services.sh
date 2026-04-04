#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight_services.sh — Service readiness probing for pre-flight validation
#
# Sourced by tekhton.sh after preflight.sh — do not run directly.
# Provides: _preflight_check_services, _preflight_check_docker,
#           _preflight_check_dev_server, _probe_service_port,
#           _pf_get_service_report
# Depends on: preflight.sh (_pf_record), common.sh (log, warn),
#             detect_services.sh (detect_services)
#
# Milestone 56: Service Readiness Probing & Enhanced Diagnosis.
#
# Cross-references docker-compose, package dependencies, and .env patterns
# to infer required services, then probes their expected ports. Service
# failures are warnings only — services may be optional or test-only.
# =============================================================================

# --- Service data (populated by inference, consumed by probe + report) ------
# Each entry: SERVICE_NAME|PORT|SOURCE|STATUS|HOST_PORT
# STATUS: running, not_running, skipped, unknown
_PF_SERVICES=()

# --- Service→port mapping ---------------------------------------------------
declare -A _PF_SVC_PORTS=(
    [postgres]=5432 [postgresql]=5432 [postgis]=5432
    [mysql]=3306 [mariadb]=3306
    [mongo]=27017 [mongodb]=27017
    [redis]=6379
    [rabbitmq]=5672
    [kafka]=9092
    [elasticsearch]=9200 [opensearch]=9200
    [minio]=9000
    [mailhog]=1025 [mailpit]=1025
)

# --- Service→display name mapping ------------------------------------------
declare -A _PF_SVC_NAMES=(
    [postgres]="PostgreSQL" [postgresql]="PostgreSQL" [postgis]="PostgreSQL"
    [mysql]="MySQL" [mariadb]="MariaDB"
    [mongo]="MongoDB" [mongodb]="MongoDB"
    [redis]="Redis"
    [rabbitmq]="RabbitMQ"
    [kafka]="Kafka"
    [elasticsearch]="Elasticsearch" [opensearch]="OpenSearch"
    [minio]="MinIO" [mailhog]="Mailhog" [mailpit]="Mailpit"
)

# --- _probe_service_port ----------------------------------------------------
# Probes a TCP port on a host. Returns 0 if open, 1 if closed/unreachable.
# Args: $1=host (default 127.0.0.1), $2=port, $3=timeout_s (default 2)
_probe_service_port() {
    local host="${1:-127.0.0.1}"
    local port="$2"
    local timeout_s="${3:-2}"

    # Method 1: bash /dev/tcp with timeout enforcement.
    # Without timeout, a filtered port could block indefinitely.
    # Use GNU timeout if available; fall back to alarm-based subshell.
    if command -v timeout &>/dev/null; then
        if timeout "$timeout_s" bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
            return 0
        fi
    else
        if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
            return 0
        fi
    fi

    # Method 2: nc/ncat fallback
    if command -v nc &>/dev/null; then
        nc -z -w "$timeout_s" "$host" "$port" 2>/dev/null && return 0
    fi

    return 1
}

# --- _pf_add_service --------------------------------------------------------
# Registers a detected service (deduplicates by name).
# Args: $1=service_key, $2=source, $3=host_port (optional override)
_pf_add_service() {
    local svc_key="$1" source="$2" host_port="${3:-}"
    local default_port="${_PF_SVC_PORTS[$svc_key]:-}"
    [[ -z "$default_port" ]] && return 0

    local port="${host_port:-$default_port}"
    local display="${_PF_SVC_NAMES[$svc_key]:-$svc_key}"

    # Dedup: skip if we already have this service
    local entry
    for entry in "${_PF_SERVICES[@]+"${_PF_SERVICES[@]}"}"; do
        local existing_name
        existing_name="${entry%%|*}"
        [[ "$existing_name" == "$display" ]] && return 0
    done

    _PF_SERVICES+=("${display}|${port}|${source}|pending|${default_port}")
}

# Inference functions (_pf_infer_from_compose, _pf_infer_from_packages,
# _pf_infer_from_env) live in preflight_services_infer.sh (sourced separately).

# --- _preflight_check_docker ------------------------------------------------
# Checks Docker daemon availability when docker-compose is present.
_preflight_check_docker() {
    local proj="${PROJECT_DIR:-.}"
    local compose_file=""

    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$proj/$candidate" ]] && { compose_file="$candidate"; break; }
    done
    [[ -z "$compose_file" ]] && return 0

    if ! command -v docker &>/dev/null; then
        _pf_record "warn" "Docker" \
            "docker-compose config found (${compose_file}) but \`docker\` is not installed."
        return 0
    fi

    if docker info &>/dev/null; then
        _pf_record "pass" "Docker" "Docker daemon is running."
    else
        _pf_record "warn" "Docker" \
            "Docker daemon is not running. Start it with: \`sudo systemctl start docker\` or open Docker Desktop."
    fi
}

# --- _preflight_check_dev_server -------------------------------------------
# Detects dev server dependency from Playwright config or UI_TEST_CMD.
_preflight_check_dev_server() {
    local proj="${PROJECT_DIR:-.}"
    local dev_port=""
    local source=""

    # Check Playwright config for webServer
    local pw_config=""
    for f in playwright.config.ts playwright.config.js playwright.config.mjs; do
        [[ -f "$proj/$f" ]] && { pw_config="$proj/$f"; break; }
    done

    if [[ -n "$pw_config" ]]; then
        # Extract port from webServer config: url: 'http://localhost:3000'
        local pw_port
        pw_port=$(grep -o 'localhost:[0-9]*' "$pw_config" 2>/dev/null | head -1 | sed 's/.*://' || true)
        if [[ -n "$pw_port" ]]; then
            dev_port="$pw_port"
            source="playwright.config"
        fi
    fi

    # Check UI_TEST_CMD for URL patterns
    if [[ -z "$dev_port" ]] && [[ -n "${UI_TEST_CMD:-}" ]]; then
        local cmd_port
        cmd_port=$(echo "${UI_TEST_CMD}" | grep -o 'localhost:[0-9]*' 2>/dev/null | head -1 | sed 's/.*://' || true)
        if [[ -n "$cmd_port" ]]; then
            dev_port="$cmd_port"
            source="UI_TEST_CMD"
        fi
    fi

    [[ -z "$dev_port" ]] && return 0

    if _probe_service_port "127.0.0.1" "$dev_port" 1; then
        _pf_record "pass" "Dev Server (:${dev_port})" \
            "Dev server detected (${source}) and port ${dev_port} is responding."
    else
        _pf_record "warn" "Dev Server (:${dev_port})" \
            "Dev server expected on port ${dev_port} (detected via ${source}) but not running. Many test frameworks handle startup internally."
    fi
}

# --- _pf_build_startup_instructions ----------------------------------------
# Returns context-aware startup instructions for a service.
# Args: $1=service_display_name, $2=port, $3=source
_pf_build_startup_instructions() {
    local display="$1" port="$2" source="$3"
    local proj="${PROJECT_DIR:-.}"
    local instructions=""

    # Docker-compose recommendation
    local compose_file=""
    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$proj/$candidate" ]] && { compose_file="$candidate"; break; }
    done

    local svc_lower
    svc_lower=$(echo "$display" | tr '[:upper:]' '[:lower:]')

    if [[ -n "$compose_file" ]]; then
        # Try docker compose (v2) then docker-compose (v1)
        if command -v docker &>/dev/null && docker compose version &>/dev/null; then
            instructions+="  docker compose up -d ${svc_lower}"$'\n'
        elif command -v docker-compose &>/dev/null; then
            instructions+="  docker-compose up -d ${svc_lower}"$'\n'
        else
            instructions+="  docker-compose up -d ${svc_lower}  (${compose_file} detected)"$'\n'
        fi
    fi

    # Platform-specific
    local uname_s
    uname_s=$(uname -s 2>/dev/null || echo "unknown")
    case "$uname_s" in
        Darwin)
            instructions+="  brew services start ${svc_lower}"$'\n'
            ;;
        Linux)
            if command -v systemctl &>/dev/null; then
                instructions+="  sudo systemctl start ${svc_lower}"$'\n'
            fi
            ;;
    esac

    echo "$instructions"
}

# --- _preflight_check_services ----------------------------------------------
# Main service readiness check: infer → probe → record.
_preflight_check_services() {
    _PF_SERVICES=()

    # Infer services from multiple signal sources
    _pf_infer_from_compose
    _pf_infer_from_packages
    _pf_infer_from_env

    [[ ${#_PF_SERVICES[@]} -eq 0 ]] && return 0

    # Determine if we're in CI (downgrade warnings to info)
    local is_ci=false
    [[ "${CI:-}" == "true" ]] && is_ci=true

    # Probe each service
    local i
    for i in "${!_PF_SERVICES[@]}"; do
        local entry="${_PF_SERVICES[$i]}"
        local display port source _status _default_port
        IFS='|' read -r display port source _status _default_port <<< "$entry"

        if _probe_service_port "127.0.0.1" "$port" 2; then
            _PF_SERVICES[$i]="${display}|${port}|${source}|running|${_default_port}"
            _pf_record "pass" "Service (${display})" \
                "${display} is running on port ${port}."
        else
            _PF_SERVICES[$i]="${display}|${port}|${source}|not_running|${_default_port}"

            local instructions
            instructions=$(_pf_build_startup_instructions "$display" "$port" "$source")
            local detail="${display} is not running on port ${port} (detected via ${source})."
            if [[ -n "$instructions" ]]; then
                detail+=$'\n'"Start it with:"$'\n'"${instructions}"
            fi

            if [[ "$is_ci" == "true" ]]; then
                # CI: downgrade to info-level pass (services managed externally)
                _pf_record "pass" "Service (${display})" \
                    "${display} not detected on port ${port} (CI environment — may be managed externally)."
            else
                _pf_record "warn" "Service (${display})" "$detail"
            fi
        fi
    done
}

# --- _pf_emit_services_report -----------------------------------------------
# Returns markdown for the services section of PREFLIGHT_REPORT.md.
# Called by _emit_preflight_report in preflight.sh.
_pf_emit_services_report() {
    [[ ${#_PF_SERVICES[@]} -eq 0 ]] && return 0

    echo "## Services"
    echo ""
    echo "| Service | Port | Status | Source |"
    echo "|---------|------|--------|--------|"

    local entry
    for entry in "${_PF_SERVICES[@]}"; do
        local display port source status _default_port
        IFS='|' read -r display port source status _default_port <<< "$entry"

        local indicator
        case "$status" in
            running)     indicator="✓ Running" ;;
            not_running) indicator="✗ Not running" ;;
            *)           indicator="— Unknown" ;;
        esac

        echo "| ${display} | ${port} | ${indicator} | ${source} |"
    done
    echo ""

    # Detail sections for not-running services
    for entry in "${_PF_SERVICES[@]}"; do
        local display port source status _default_port
        IFS='|' read -r display port source status _default_port <<< "$entry"

        if [[ "$status" == "not_running" ]]; then
            echo "#### ✗ ${display} (port ${port})"
            echo "${display} is required (detected via \`${source}\`) but not running."

            local instructions
            instructions=$(_pf_build_startup_instructions "$display" "$port" "$source")
            if [[ -n "$instructions" ]]; then
                echo "Start it with:"
                echo "$instructions"
            fi
        fi
    done
}
