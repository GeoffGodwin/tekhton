#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# preflight_services_infer.sh — Service inference from project manifests
#
# Sourced by tekhton.sh after preflight_services.sh — do not run directly.
# Provides: _pf_infer_from_compose, _pf_emit_compose_service,
#           _pf_infer_from_packages, _pf_infer_from_env
# Depends on: preflight_services.sh (_pf_add_service, _PF_SVC_PORTS)
#
# Extracted from preflight_services.sh to keep files under the 300-line ceiling.
# Inference functions scan docker-compose, package manifests, and .env patterns
# to detect required services. The parent module handles probing and reporting.
# =============================================================================

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

        # Service name (2-space indent) — continue after match so the service
        # name line is never re-evaluated by port/image checks below.
        if [[ "$line" =~ ^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_-]*: ]]; then
            _pf_emit_compose_service "$current_service" "$current_image" "$current_host_port"
            current_service=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            current_image=""; current_host_port=""; in_ports=0
            continue
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
