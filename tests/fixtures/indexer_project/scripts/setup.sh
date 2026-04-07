#!/usr/bin/env bash
# Setup script for the sample project.
set -euo pipefail

setup_database() {
    echo "Initializing database..."
    mkdir -p data
}

check_dependencies() {
    local missing=0
    for cmd in python3 node; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "Missing: $cmd"
            missing=$((missing + 1))
        fi
    done
    return "$missing"
}

run_migrations() {
    echo "Running migrations..."
    setup_database
}

main() {
    check_dependencies
    run_migrations
    echo "Setup complete."
}

main "$@"
