#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# detect_services.sh — Multi-service detection (Milestone 12)
#
# Detects services from docker-compose, Procfile, and k8s manifests.
# Maps services to directories and tech stacks.
#
# Sourced by tekhton.sh — do not run directly.
# Depends on: detect.sh (_DETECT_EXCLUDE_DIRS)
# Provides: detect_services()
# =============================================================================

# detect_services — Detects services from orchestration configs.
# Args: $1 = project directory (defaults to PROJECT_DIR)
# Output: One line per service: SERVICE_NAME|DIRECTORY|TECH_STACK|SOURCE
detect_services() {
    local proj_dir="${1:-${PROJECT_DIR:-.}}"

    _detect_docker_compose_services "$proj_dir"
    _detect_procfile_services "$proj_dir"
    _detect_k8s_services "$proj_dir"
}

# --- docker-compose detection ------------------------------------------------

_detect_docker_compose_services() {
    local proj_dir="$1"
    local compose_file=""
    for candidate in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
        [[ -f "$proj_dir/$candidate" ]] && { compose_file="$proj_dir/$candidate"; break; }
    done
    [[ -z "$compose_file" ]] && return 0

    local in_services=0
    local current_service=""
    local current_build=""
    local line

    while IFS= read -r line; do
        # Top-level services: key
        if [[ "$line" =~ ^services: ]]; then
            in_services=1
            continue
        fi

        # Another top-level key ends services block
        if [[ "$in_services" -eq 1 ]] && [[ "$line" =~ ^[a-z] ]] && [[ ! "$line" =~ ^[[:space:]] ]]; then
            # Emit previous service
            [[ -n "$current_service" ]] && _emit_compose_service "$proj_dir" "$current_service" "$current_build"
            in_services=0
            continue
        fi

        [[ "$in_services" -ne 1 ]] && continue

        # Service name (2-space indent, no leading dash)
        if [[ "$line" =~ ^[[:space:]][[:space:]][a-zA-Z_][a-zA-Z0-9_-]*: ]]; then
            # Emit previous service
            [[ -n "$current_service" ]] && _emit_compose_service "$proj_dir" "$current_service" "$current_build"
            current_service=$(echo "$line" | sed 's/^[[:space:]]*//' | cut -d: -f1)
            current_build=""
        fi

        # Build context
        if [[ "$line" =~ build: ]]; then
            current_build=$(echo "$line" | sed 's/.*build:[[:space:]]*//' | sed 's/[[:space:]]*$//')
            # Handle build: . or build: ./dir
            [[ "$current_build" == "." ]] && current_build=""
        fi
        if [[ "$line" =~ context: ]]; then
            current_build=$(echo "$line" | sed 's/.*context:[[:space:]]*//' | sed "s/[\"']//g" | sed 's/[[:space:]]*$//')
            [[ "$current_build" == "." ]] && current_build=""
        fi
    done < "$compose_file"

    # Emit last service
    [[ -n "$current_service" ]] && _emit_compose_service "$proj_dir" "$current_service" "$current_build"
}

_emit_compose_service() {
    local proj_dir="$1"
    local service_name="$2"
    local build_dir="${3:-.}"
    build_dir="${build_dir#./}"
    [[ -z "$build_dir" ]] && build_dir="."

    local tech_stack="unknown"
    local check_dir="$proj_dir"
    [[ "$build_dir" != "." ]] && check_dir="$proj_dir/$build_dir"

    if [[ -d "$check_dir" ]]; then
        tech_stack=$(_infer_tech_from_dir "$check_dir")
    fi

    echo "${service_name}|${build_dir}|${tech_stack}|docker-compose"
}

# --- Procfile detection ------------------------------------------------------

_detect_procfile_services() {
    local proj_dir="$1"
    [[ ! -f "$proj_dir/Procfile" ]] && return 0

    local line proc_name
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        [[ "$line" =~ ^# ]] && continue
        proc_name=$(echo "$line" | cut -d: -f1 | tr -d '[:space:]')
        [[ -z "$proc_name" ]] && continue
        echo "${proc_name}|.|unknown|procfile"
    done < "$proj_dir/Procfile"
}

# --- Kubernetes manifest detection -------------------------------------------

_detect_k8s_services() {
    local proj_dir="$1"
    local -a k8s_dirs=()

    # Check conventional k8s directories
    local d
    for d in k8s deploy manifests charts kubernetes .k8s; do
        [[ -d "$proj_dir/$d" ]] && k8s_dirs+=("$proj_dir/$d")
    done

    [[ ${#k8s_dirs[@]} -eq 0 ]] && return 0

    local -A _k8s_seen_svcs=()
    local yaml_file
    for d in "${k8s_dirs[@]}"; do
        while IFS= read -r yaml_file; do
            [[ -z "$yaml_file" ]] && continue
            _parse_k8s_service_yaml "$proj_dir" "$yaml_file" _k8s_seen_svcs
        done < <(find "$d" -maxdepth 3 -name "*.yaml" -o -name "*.yml" 2>/dev/null | head -50)
    done
}

_parse_k8s_service_yaml() {
    local proj_dir="$1"
    local yaml_file="$2"
    local -n _seen="$3"

    # Check for Deployment/Service kind
    if ! grep -qE '^kind:\s*(Deployment|Service|StatefulSet)' "$yaml_file" 2>/dev/null; then
        return 0
    fi

    local service_name
    service_name=$(awk '/^metadata:/{m=1} m && /name:/{print $2; exit}' "$yaml_file" 2>/dev/null | tr -d '[:space:]"' || true)
    [[ -z "$service_name" ]] && return 0

    # Deduplicate
    [[ -n "${_seen[$service_name]+x}" ]] && return 0
    _seen[$service_name]=1

    # Try to map to directory
    local dir="."
    if [[ -d "$proj_dir/$service_name" ]]; then
        dir="$service_name"
    fi

    echo "${service_name}|${dir}|unknown|k8s"
}

# --- Tech stack inference from directory -------------------------------------

_infer_tech_from_dir() {
    local dir="$1"
    if [[ -f "$dir/package.json" ]]; then
        if [[ -f "$dir/tsconfig.json" ]]; then echo "typescript"; else echo "node"; fi
    elif [[ -f "$dir/pyproject.toml" ]] || [[ -f "$dir/requirements.txt" ]]; then
        echo "python"
    elif [[ -f "$dir/go.mod" ]]; then
        echo "go"
    elif [[ -f "$dir/Cargo.toml" ]]; then
        echo "rust"
    elif [[ -f "$dir/Gemfile" ]]; then
        echo "ruby"
    elif [[ -f "$dir/pom.xml" ]] || [[ -f "$dir/build.gradle" ]]; then
        echo "java"
    elif compgen -G "$dir"/*.csproj >/dev/null 2>&1; then
        echo "csharp"
    else
        echo "unknown"
    fi
}
