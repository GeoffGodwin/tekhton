#!/usr/bin/env bash
# Deployment helper for the sample project.
set -euo pipefail

build_artifacts() {
    echo "Building..."
}

deploy_to_staging() {
    build_artifacts
    echo "Deploying to staging..."
}

deploy_to_production() {
    build_artifacts
    echo "Deploying to production..."
}

deploy_to_staging
