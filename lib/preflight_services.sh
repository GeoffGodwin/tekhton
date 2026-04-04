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

    # Method 1: bash /dev/tcp (most portable for bash builds that support it)
    if (echo >/dev/tcp/"$host"/"$port") 2>/dev/null; then
        return 0
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

# --- _pf_infer_from_compose -------------------------------------------------
# Parses docker-compose.yml for service images and port mappings.
_pf_infer_from_compose() {
    local proj="${PROJECT_DIR:-.}"
    local compose_file=""

    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$proj/$candidate" ]] && { compose_file="$proj/$candidate"; break; }
    done
    [[ -z "$compose_file" ]] && return 0

    local current_service="" current_image="" current_host_port=""
    local in_services=0 in_ports=0
    local line

    while IFS= read -r line; do
        # Top-level services: key
        if [[ "$line" =~ ^services: ]]; then
            in_services=1; continue
        fi
        # Another top-level key ends services block
        if [[ "$in_services" -eq 1 ]] && [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            _pf_emit_compose_service "$current_service" "$current_image" "$current_host_port"
            in_services=0; continue
        fi
        [[ "$in_services" -ne 1 ]] && continue

        # Service name (2-space indent)
        if [[ "$line" =~ ^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_-]*: ]]; then
            _pf_emit_compose_service "$current_service" "$current_image" "$current_host_port"
            current_service=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            current_image=""; current_host_port=""; in_ports=0
        fi

        # Image line
        if [[ "$line" =~ image: ]]; then
            current_image=$(echo "$line" | sed 's/.*image:[[:space:]]*//' | sed "s/[\"']//g" | sed 's/[[:space:]]*$//')
            # Strip tag: postgres:15 → postgres
            current_image="${current_image%%:*}"
            # Strip registry prefix: docker.io/library/postgres → postgres
            current_image="${current_image##*/}"
        fi

        # Port mapping section
        if [[ "$line" =~ ^[[:space:]]*ports: ]]; then
            in_ports=1; continue
        fi
        if [[ "$in_ports" -eq 1 ]]; then
            # Port lines: - "5433:5432" or - 5433:5432
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]] ]]; then
                local port_spec
                port_spec=$(echo "$line" | sed "s/.*-[[:space:]]*//" | sed "s/[\"']//g" | tr -d '[:space:]')
                # Extract host port from HOST:CONTAINER
                if [[ "$port_spec" == *":"* ]]; then
                    current_host_port="${port_spec%%:*}"
                fi
            else
                in_ports=0
            fi
        fi
    done < "$compose_file"

    # Emit last service
    _pf_emit_compose_service "$current_service" "$current_image" "$current_host_port"
}

_pf_emit_compose_service() {
    local name="$1" image="$2" host_port="$3"
    [[ -z "$name" ]] && return 0

    # Try to match image name to a known service
    local svc_key=""
    if [[ -n "$image" ]]; then
        local img_lower
        img_lower=$(echo "$image" | tr '[:upper:]' '[:lower:]')
        for key in "${!_PF_SVC_PORTS[@]}"; do
            if [[ "$img_lower" == *"$key"* ]]; then
                svc_key="$key"; break
            fi
        done
    fi

    # Fallback: try service name itself
    if [[ -z "$svc_key" ]]; then
        local name_lower
        name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')
        [[ -n "${_PF_SVC_PORTS[$name_lower]+x}" ]] && svc_key="$name_lower"
    fi

    [[ -z "$svc_key" ]] && return 0
    _pf_add_service "$svc_key" "docker-compose" "$host_port"
}

# --- _pf_infer_from_packages -----------------------------------------------
# Checks package manifests for database client libraries.
_pf_infer_from_packages() {
    local proj="${PROJECT_DIR:-.}"

    # Node.js: package.json
    if [[ -f "$proj/package.json" ]]; then
        local pkg_content
        pkg_content=$(cat "$proj/package.json" 2>/dev/null || true)

        # PostgreSQL
        if echo "$pkg_content" | grep -qE '"(pg|prisma|typeorm|sequelize|knex)"' 2>/dev/null; then
            _pf_add_service "postgres" "package.json"
        fi
        # Redis
        if echo "$pkg_content" | grep -qE '"(redis|ioredis|bull|bullmq)"' 2>/dev/null; then
            _pf_add_service "redis" "package.json"
        fi
        # MongoDB
        if echo "$pkg_content" | grep -qE '"(mongoose|mongodb)"' 2>/dev/null; then
            _pf_add_service "mongo" "package.json"
        fi
        # RabbitMQ
        if echo "$pkg_content" | grep -qE '"(amqplib|amqp-connection-manager)"' 2>/dev/null; then
            _pf_add_service "rabbitmq" "package.json"
        fi
        # Kafka
        if echo "$pkg_content" | grep -qE '"kafkajs"' 2>/dev/null; then
            _pf_add_service "kafka" "package.json"
        fi
    fi

    # Python: requirements.txt, pyproject.toml, Pipfile
    local py_file=""
    for f in requirements.txt pyproject.toml Pipfile; do
        [[ -f "$proj/$f" ]] && { py_file="$proj/$f"; break; }
    done
    if [[ -n "$py_file" ]]; then
        local py_content
        py_content=$(cat "$py_file" 2>/dev/null || true)

        if echo "$py_content" | grep -qiE '(psycopg2|asyncpg|sqlalchemy|django\.db)' 2>/dev/null; then
            _pf_add_service "postgres" "$py_file"
        fi
        if echo "$py_content" | grep -qiE '(^redis|celery)' 2>/dev/null; then
            _pf_add_service "redis" "$py_file"
        fi
        if echo "$py_content" | grep -qiE '(pymongo|mongoengine|motor)' 2>/dev/null; then
            _pf_add_service "mongo" "$py_file"
        fi
    fi

    # Go: go.mod
    if [[ -f "$proj/go.mod" ]]; then
        local go_content
        go_content=$(cat "$proj/go.mod" 2>/dev/null || true)

        if echo "$go_content" | grep -qE '(pgx|lib/pq)' 2>/dev/null; then
            _pf_add_service "postgres" "go.mod"
        fi
        if echo "$go_content" | grep -qE 'go-redis' 2>/dev/null; then
            _pf_add_service "redis" "go.mod"
        fi
        if echo "$go_content" | grep -qE 'mongo-driver' 2>/dev/null; then
            _pf_add_service "mongo" "go.mod"
        fi
    fi
}

# --- _pf_infer_from_env ----------------------------------------------------
# Scans .env.example for known service-related variable patterns.
_pf_infer_from_env() {
    local proj="${PROJECT_DIR:-.}"
    local env_name=""

    for candidate in .env.example .env.template .env.sample; do
        [[ -f "$proj/$candidate" ]] && { env_name="$candidate"; break; }
    done
    [[ -z "$env_name" ]] && return 0

    local content
    content=$(cat "$proj/$env_name" 2>/dev/null || true)

    # PostgreSQL
    if echo "$content" | grep -qiE '^(DATABASE_URL|DB_HOST|POSTGRES_)' 2>/dev/null; then
        _pf_add_service "postgres" "$env_name"
    fi
    # Redis
    if echo "$content" | grep -qiE '^(REDIS_URL|REDIS_HOST)' 2>/dev/null; then
        _pf_add_service "redis" "$env_name"
    fi
    # MongoDB
    if echo "$content" | grep -qiE '^(MONGO_URI|MONGODB_URI|MONGO_URL)' 2>/dev/null; then
        _pf_add_service "mongo" "$env_name"
    fi
    # RabbitMQ
    if echo "$content" | grep -qiE '^(RABBITMQ_URL|AMQP_URL)' 2>/dev/null; then
        _pf_add_service "rabbitmq" "$env_name"
    fi
}

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

    if docker info &>/dev/null 2>&1; then
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
        pw_port=$(grep -oP "localhost:\K\d+" "$pw_config" 2>/dev/null | head -1 || true)
        if [[ -n "$pw_port" ]]; then
            dev_port="$pw_port"
            source="playwright.config"
        fi
    fi

    # Check UI_TEST_CMD for URL patterns
    if [[ -z "$dev_port" ]] && [[ -n "${UI_TEST_CMD:-}" ]]; then
        local cmd_port
        cmd_port=$(echo "${UI_TEST_CMD}" | grep -oP 'localhost:\K\d+' 2>/dev/null || true)
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
        if command -v docker &>/dev/null && docker compose version &>/dev/null 2>&1; then
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
