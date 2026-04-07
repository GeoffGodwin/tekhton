#!/usr/bin/env bash
# Test: Milestone 12 — Brownfield deep analysis & inference quality
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source detection libraries
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/detect_commands.sh
source "${TEKHTON_HOME}/lib/detect_commands.sh"
# shellcheck source=../lib/detect_workspaces.sh
source "${TEKHTON_HOME}/lib/detect_workspaces.sh"
# shellcheck source=../lib/detect_services.sh
source "${TEKHTON_HOME}/lib/detect_services.sh"
# shellcheck source=../lib/detect_ci.sh
source "${TEKHTON_HOME}/lib/detect_ci.sh"
# shellcheck source=../lib/detect_infrastructure.sh
source "${TEKHTON_HOME}/lib/detect_infrastructure.sh"
# shellcheck source=../lib/detect_test_frameworks.sh
source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
# shellcheck source=../lib/detect_doc_quality.sh
source "${TEKHTON_HOME}/lib/detect_doc_quality.sh"

# =============================================================================
# Helper: make a fresh project dir
# =============================================================================
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# detect_workspaces — npm workspaces
# =============================================================================
echo "=== detect_workspaces: npm workspaces ==="

NPM_WS=$(make_proj "npm_ws")
cat > "$NPM_WS/package.json" << 'EOF'
{
  "name": "my-monorepo",
  "workspaces": ["packages/*", "apps/*"]
}
EOF
mkdir -p "$NPM_WS/packages/lib-a" "$NPM_WS/packages/lib-b" "$NPM_WS/apps/web"

ws_output=$(detect_workspaces "$NPM_WS")
if echo "$ws_output" | grep -q "npm-workspaces|package.json"; then
    pass "npm workspaces detected"
else
    fail "npm workspaces NOT detected: $ws_output"
fi

# =============================================================================
# detect_workspaces — Cargo workspace
# =============================================================================
echo "=== detect_workspaces: Cargo workspace ==="

CARGO_WS=$(make_proj "cargo_ws")
cat > "$CARGO_WS/Cargo.toml" << 'EOF'
[workspace]
members = [
    "crates/core",
    "crates/cli"
]
EOF
mkdir -p "$CARGO_WS/crates/core" "$CARGO_WS/crates/cli"

ws_output=$(detect_workspaces "$CARGO_WS")
if echo "$ws_output" | grep -q "cargo-workspace|Cargo.toml"; then
    pass "Cargo workspace detected"
else
    fail "Cargo workspace NOT detected: $ws_output"
fi

# =============================================================================
# detect_workspaces — Go workspace
# =============================================================================
echo "=== detect_workspaces: Go workspace ==="

GO_WS=$(make_proj "go_ws")
cat > "$GO_WS/go.work" << 'EOF'
go 1.22

use (
    ./svc-a
    ./svc-b
)
EOF
mkdir -p "$GO_WS/svc-a" "$GO_WS/svc-b"

ws_output=$(detect_workspaces "$GO_WS")
if echo "$ws_output" | grep -q "go-workspace|go.work"; then
    pass "Go workspace detected"
else
    fail "Go workspace NOT detected: $ws_output"
fi

# =============================================================================
# detect_workspaces — Maven multi-module
# =============================================================================
echo "=== detect_workspaces: Maven multi-module ==="

MVN_WS=$(make_proj "mvn_ws")
cat > "$MVN_WS/pom.xml" << 'EOF'
<project>
    <modules>
        <module>core</module>
        <module>web</module>
    </modules>
</project>
EOF
mkdir -p "$MVN_WS/core" "$MVN_WS/web"

ws_output=$(detect_workspaces "$MVN_WS")
if echo "$ws_output" | grep -q "maven-multimodule|pom.xml"; then
    pass "Maven multi-module detected"
else
    fail "Maven multi-module NOT detected: $ws_output"
fi

# =============================================================================
# detect_workspaces — Single project (no workspace)
# =============================================================================
echo "=== detect_workspaces: Single project ==="

SINGLE=$(make_proj "single_proj")
echo '{"name":"simple-app"}' > "$SINGLE/package.json"

ws_output=$(detect_workspaces "$SINGLE")
if [[ -z "$ws_output" ]]; then
    pass "No workspace detected for single project"
else
    fail "Workspace falsely detected for single project: $ws_output"
fi

# =============================================================================
# detect_services — docker-compose
# =============================================================================
echo "=== detect_services: docker-compose ==="

DC_DIR=$(make_proj "docker_compose")
cat > "$DC_DIR/docker-compose.yml" << 'EOF'
version: "3"
services:
  web:
    build: ./web
  api:
    build: ./api
  db:
    image: postgres:15
EOF
mkdir -p "$DC_DIR/web" "$DC_DIR/api"
echo '{"name":"web-app"}' > "$DC_DIR/web/package.json"
echo '{"compilerOptions":{}}' > "$DC_DIR/web/tsconfig.json"
touch "$DC_DIR/api/requirements.txt"

svc_output=$(detect_services "$DC_DIR")
if echo "$svc_output" | grep -q "web|web|"; then
    pass "docker-compose web service detected"
else
    fail "docker-compose web service NOT detected: $svc_output"
fi

if echo "$svc_output" | grep -q "api|api|"; then
    pass "docker-compose api service detected"
else
    fail "docker-compose api service NOT detected: $svc_output"
fi

# =============================================================================
# detect_services — Procfile
# =============================================================================
echo "=== detect_services: Procfile ==="

PROC_DIR=$(make_proj "procfile")
cat > "$PROC_DIR/Procfile" << 'EOF'
web: npm start
worker: node worker.js
EOF

svc_output=$(detect_services "$PROC_DIR")
if echo "$svc_output" | grep -q "web|.*|.*|procfile"; then
    pass "Procfile web process detected"
else
    fail "Procfile web process NOT detected: $svc_output"
fi

if echo "$svc_output" | grep -q "worker|.*|.*|procfile"; then
    pass "Procfile worker process detected"
else
    fail "Procfile worker process NOT detected: $svc_output"
fi

# =============================================================================
# detect_ci_config — GitHub Actions
# =============================================================================
echo "=== detect_ci_config: GitHub Actions ==="

GHA_DIR=$(make_proj "gha")
mkdir -p "$GHA_DIR/.github/workflows"
cat > "$GHA_DIR/.github/workflows/ci.yml" << 'EOF'
name: CI
on: push
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - run: npm test
      - run: npm run lint
      - run: npm run build
EOF

ci_output=$(detect_ci_config "$GHA_DIR")
if echo "$ci_output" | grep -q "github-actions"; then
    pass "GitHub Actions detected"
else
    fail "GitHub Actions NOT detected: $ci_output"
fi

if echo "$ci_output" | grep -q "npm test"; then
    pass "GitHub Actions test command detected"
else
    fail "GitHub Actions test command NOT detected: $ci_output"
fi

# =============================================================================
# detect_ci_config — GitLab CI
# =============================================================================
echo "=== detect_ci_config: GitLab CI ==="

GL_DIR=$(make_proj "gitlab")
cat > "$GL_DIR/.gitlab-ci.yml" << 'EOF'
test:
  script:
    - pytest
    - ruff check .
EOF

ci_output=$(detect_ci_config "$GL_DIR")
if echo "$ci_output" | grep -q "gitlab-ci"; then
    pass "GitLab CI detected"
else
    fail "GitLab CI NOT detected: $ci_output"
fi

# =============================================================================
# detect_infrastructure — Terraform
# =============================================================================
echo "=== detect_infrastructure: Terraform ==="

TF_DIR=$(make_proj "terraform")
mkdir -p "$TF_DIR/terraform"
cat > "$TF_DIR/terraform/main.tf" << 'EOF'
provider "aws" {
  region = "us-east-1"
}
EOF

infra_output=$(detect_infrastructure "$TF_DIR")
if echo "$infra_output" | grep -q "terraform|terraform|"; then
    pass "Terraform detected in terraform/ directory"
else
    fail "Terraform NOT detected: $infra_output"
fi

# =============================================================================
# detect_infrastructure — Pulumi
# =============================================================================
echo "=== detect_infrastructure: Pulumi ==="

PU_DIR=$(make_proj "pulumi")
cat > "$PU_DIR/Pulumi.yaml" << 'EOF'
name: my-infra
runtime: python
EOF

infra_output=$(detect_infrastructure "$PU_DIR")
if echo "$infra_output" | grep -q "pulumi|.|"; then
    pass "Pulumi detected"
else
    fail "Pulumi NOT detected: $infra_output"
fi

# =============================================================================
# detect_infrastructure — CDK
# =============================================================================
echo "=== detect_infrastructure: CDK ==="

CDK_DIR=$(make_proj "cdk")
echo '{"app":"npx ts-node bin/app.ts"}' > "$CDK_DIR/cdk.json"

infra_output=$(detect_infrastructure "$CDK_DIR")
if echo "$infra_output" | grep -q "aws-cdk|.|aws|high"; then
    pass "AWS CDK detected"
else
    fail "AWS CDK NOT detected: $infra_output"
fi

# =============================================================================
# detect_test_frameworks — Python pytest
# =============================================================================
echo "=== detect_test_frameworks: Python pytest ==="

PY_DIR=$(make_proj "py_pytest")
cat > "$PY_DIR/pyproject.toml" << 'EOF'
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

tf_output=$(detect_test_frameworks "$PY_DIR")
if echo "$tf_output" | grep -q "pytest|pyproject.toml|high"; then
    pass "pytest detected from pyproject.toml"
else
    fail "pytest NOT detected: $tf_output"
fi

# =============================================================================
# detect_test_frameworks — JavaScript jest
# =============================================================================
echo "=== detect_test_frameworks: JavaScript jest ==="

JS_DIR=$(make_proj "js_jest")
cat > "$JS_DIR/package.json" << 'EOF'
{
  "name": "my-app",
  "devDependencies": { "jest": "^29.0.0" }
}
EOF

tf_output=$(detect_test_frameworks "$JS_DIR")
if echo "$tf_output" | grep -q "jest|"; then
    pass "jest detected from package.json"
else
    fail "jest NOT detected: $tf_output"
fi

# =============================================================================
# detect_test_frameworks — Rust cargo test
# =============================================================================
echo "=== detect_test_frameworks: Rust cargo test ==="

RS_DIR=$(make_proj "rust_proj")
cat > "$RS_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-crate"
version = "0.1.0"
EOF

tf_output=$(detect_test_frameworks "$RS_DIR")
if echo "$tf_output" | grep -q "cargo-test|Cargo.toml|high"; then
    pass "cargo test detected"
else
    fail "cargo test NOT detected: $tf_output"
fi

# =============================================================================
# assess_doc_quality — Good documentation
# =============================================================================
echo "=== assess_doc_quality: Good documentation ==="

GOOD_DOC=$(make_proj "good_docs")
cat > "$GOOD_DOC/README.md" << 'EOF'
# My Project

## Installation

Run `pip install my-project` to get started.

```python
import my_project
my_project.run()
```

## Getting Started

This is a detailed getting started guide with examples.

## Architecture

The project uses a layered architecture...

## Contributing

Please read our contributing guide before submitting PRs.

## License

MIT
EOF
cat > "$GOOD_DOC/CONTRIBUTING.md" << 'EOF'
# Contributing Guide

## Setup

1. Clone the repo
2. Run `pip install -e .`
3. Run tests with `pytest`

## Code Style

We use ruff for linting and black for formatting.
EOF
mkdir -p "$GOOD_DOC/docs/adr"
touch "$GOOD_DOC/docs/adr/001-use-postgres.md"
cat > "$GOOD_DOC/ARCHITECTURE.md" << 'EOF'
# Architecture

## Overview

The system uses a three-layer design...

$(seq 1 50 | while read -r i; do echo "Line $i of architecture documentation."; done)
EOF

dq_output=$(assess_doc_quality "$GOOD_DOC")
dq_score=$(echo "$dq_output" | cut -d'|' -f1)
if [[ "$dq_score" -ge 40 ]]; then
    pass "Good docs score >= 40 (got ${dq_score})"
else
    fail "Good docs score too low: ${dq_score}"
fi

# =============================================================================
# assess_doc_quality — No documentation
# =============================================================================
echo "=== assess_doc_quality: No documentation ==="

NO_DOC=$(make_proj "no_docs")
touch "$NO_DOC/main.py"

dq_output=$(assess_doc_quality "$NO_DOC")
dq_score=$(echo "$dq_output" | cut -d'|' -f1)
if [[ "$dq_score" -le 20 ]]; then
    pass "No docs score <= 20 (got ${dq_score})"
else
    fail "No docs score too high: ${dq_score}"
fi

# =============================================================================
# detect_commands — Priority cascade
# =============================================================================
echo "=== detect_commands: Priority cascade ==="

CASCADE_DIR=$(make_proj "cascade")
cat > "$CASCADE_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test": "jest",
    "build": "tsc"
  }
}
EOF

cascade_output=$(detect_commands "$CASCADE_DIR")
# Should get deduplicated output
test_lines=$(echo "$cascade_output" | grep -c "^test|" || true)
if [[ "$test_lines" -eq 1 ]]; then
    pass "Deduplicated: single test command emitted"
else
    fail "Not deduplicated: ${test_lines} test command lines"
fi

# =============================================================================
# detect_workspaces — Gradle multi-project
# =============================================================================
echo "=== detect_workspaces: Gradle multi-project ==="

GRADLE_WS=$(make_proj "gradle_ws")
cat > "$GRADLE_WS/settings.gradle" << 'EOF'
include ':core', ':web', ':api'
EOF
mkdir -p "$GRADLE_WS/core" "$GRADLE_WS/web" "$GRADLE_WS/api"

ws_output=$(detect_workspaces "$GRADLE_WS")
if echo "$ws_output" | grep -q "gradle-multiproject|settings.gradle"; then
    pass "Gradle multi-project detected"
else
    fail "Gradle multi-project NOT detected: $ws_output"
fi

# =============================================================================
# Single-project backward compatibility
# =============================================================================
echo "=== Backward compatibility: Single project ==="

SINGLE_COMPAT=$(make_proj "compat")
echo '{"name":"simple"}' > "$SINGLE_COMPAT/package.json"

ws=$(detect_workspaces "$SINGLE_COMPAT")
svc=$(detect_services "$SINGLE_COMPAT")
ci=$(detect_ci_config "$SINGLE_COMPAT")
infra=$(detect_infrastructure "$SINGLE_COMPAT")

if [[ -z "$ws" ]] && [[ -z "$svc" ]] && [[ -z "$ci" ]] && [[ -z "$infra" ]]; then
    pass "Single project: all extended detections return empty"
else
    fail "Single project: unexpected detection output"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Milestone 12 Detection Tests ==="
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo ""

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
