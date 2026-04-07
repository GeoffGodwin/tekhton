#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight.sh — Unit tests for lib/preflight.sh
#
# Tests:
#   run_preflight_checks: enabled/disabled toggle, report generation
#   _preflight_check_dependencies: missing/stale node_modules detection
#   _preflight_check_tools: tool availability via mock, Playwright/Cypress cache
#   _preflight_check_env_vars: .env presence and key completeness
#   _preflight_check_runtime_version: version file matching
#   _preflight_check_lock_freshness: manifest vs lock mtime
#   _preflight_check_ports: port availability detection
#   PREFLIGHT_AUTO_FIX: reports but doesn't fix when false
#
# Milestone 55: Pre-flight Environment Validation
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/detect_test_frameworks.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_checks_env.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services_infer.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

# --- Test fixture setup -------------------------------------------------------

_make_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "$tmpdir"
}

_cleanup_test_dir() {
    [[ -n "${1:-}" ]] && rm -rf "$1"
}

# =============================================================================
# PREFLIGHT_ENABLED=false skips all checks
# =============================================================================

echo "=== PREFLIGHT_ENABLED=false ==="

export PREFLIGHT_ENABLED=false
PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

run_preflight_checks
rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass
else
    fail "PREFLIGHT_ENABLED=false should return 0, got $rc"
fi

# No report file should be created
if [[ ! -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]]; then
    pass
else
    fail "Report should not be created when disabled"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_ENABLED=true

# =============================================================================
# Missing node_modules detection
# =============================================================================

echo "=== Dependency check: missing node_modules ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

# Create lock file but no node_modules
echo '{}' > "$PROJECT_DIR/package-lock.json"

# Reset state and run check
_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_dependencies

if [[ "$_PF_FAIL" -ge 1 ]]; then
    pass
else
    fail "Missing node_modules should produce a fail (got fail=$_PF_FAIL)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Stale node_modules detection (lock newer than install marker)
# =============================================================================

echo "=== Dependency check: stale node_modules ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

mkdir -p "$PROJECT_DIR/node_modules"
# Create install marker first (older)
touch "$PROJECT_DIR/node_modules/.package-lock.json"
sleep 1
# Then lock file (newer)
echo '{}' > "$PROJECT_DIR/package-lock.json"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_dependencies

if [[ "$_PF_FAIL" -ge 1 ]]; then
    pass
else
    fail "Stale node_modules should produce a fail (got fail=$_PF_FAIL)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Up-to-date node_modules passes
# =============================================================================

echo "=== Dependency check: fresh node_modules ==="

PROJECT_DIR=$(_make_test_dir)

echo '{}' > "$PROJECT_DIR/package-lock.json"
mkdir -p "$PROJECT_DIR/node_modules"
# Install marker newer than lock
sleep 1
touch "$PROJECT_DIR/node_modules/.package-lock.json"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_dependencies

if [[ "$_PF_PASS" -ge 1 ]] && [[ "$_PF_FAIL" -eq 0 ]]; then
    pass
else
    fail "Fresh node_modules should pass (pass=$_PF_PASS, fail=$_PF_FAIL)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Environment variable check: missing .env
# =============================================================================

echo "=== Env vars: missing .env ==="

PROJECT_DIR=$(_make_test_dir)

printf 'DATABASE_URL=postgres://localhost\nSECRET_KEY=changeme\n' > "$PROJECT_DIR/.env.example"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_env_vars

if [[ "$_PF_WARN" -ge 1 ]]; then
    pass
else
    fail "Missing .env should produce a warning (warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Environment variable check: missing keys in .env
# =============================================================================

echo "=== Env vars: missing keys ==="

PROJECT_DIR=$(_make_test_dir)

printf 'DATABASE_URL=postgres://localhost\nSECRET_KEY=changeme\n' > "$PROJECT_DIR/.env.example"
printf 'DATABASE_URL=postgres://localhost\n' > "$PROJECT_DIR/.env"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_env_vars

if [[ "$_PF_WARN" -ge 1 ]]; then
    pass
else
    fail "Missing key SECRET_KEY should produce a warning (warn=$_PF_WARN)"
fi

# Verify the report mentions the missing key
local_report=$(printf '%s\n' "${_PF_REPORT_LINES[@]}")
if echo "$local_report" | grep -q "SECRET_KEY"; then
    pass
else
    fail "Report should mention missing key SECRET_KEY"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Environment variable check: all keys present
# =============================================================================

echo "=== Env vars: all keys present ==="

PROJECT_DIR=$(_make_test_dir)

printf 'DATABASE_URL=postgres://localhost\nSECRET_KEY=changeme\n' > "$PROJECT_DIR/.env.example"
printf 'DATABASE_URL=postgres://localhost\nSECRET_KEY=mykey\n' > "$PROJECT_DIR/.env"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_env_vars

if [[ "$_PF_PASS" -ge 1 ]] && [[ "$_PF_WARN" -eq 0 ]]; then
    pass
else
    fail "All keys present should pass (pass=$_PF_PASS, warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Tool availability: pipeline config command check
# =============================================================================

echo "=== Tool check: pipeline config commands ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
# These are read via ${!cmd_var:-} in preflight.sh
export ANALYZE_CMD="bash -c 'echo test'"
export BUILD_CHECK_CMD=""
export TEST_CMD="true"
export UI_TEST_CMD=""

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_tools

# bash should be found (it's always available)
if [[ "$_PF_PASS" -ge 1 ]]; then
    pass
else
    fail "bash should be available (pass=$_PF_PASS)"
fi

# TEST_CMD=true should be skipped (no-op default)
if [[ "$_PF_WARN" -eq 0 ]]; then
    pass
else
    fail "TEST_CMD=true should be skipped, not warned (warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"
unset ANALYZE_CMD BUILD_CHECK_CMD TEST_CMD UI_TEST_CMD

# =============================================================================
# Lock freshness: package.json newer than lock file
# =============================================================================

echo "=== Lock freshness: stale lock ==="

PROJECT_DIR=$(_make_test_dir)

# Create lock file first (older)
echo '{}' > "$PROJECT_DIR/package-lock.json"
sleep 1
# Then manifest (newer)
echo '{"name":"test"}' > "$PROJECT_DIR/package.json"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_lock_freshness

if [[ "$_PF_WARN" -ge 1 ]]; then
    pass
else
    fail "Stale lock should produce a warning (warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Lock freshness: lock newer than manifest (OK)
# =============================================================================

echo "=== Lock freshness: fresh lock ==="

PROJECT_DIR=$(_make_test_dir)

echo '{"name":"test"}' > "$PROJECT_DIR/package.json"
sleep 1
echo '{}' > "$PROJECT_DIR/package-lock.json"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_lock_freshness

if [[ "$_PF_PASS" -ge 1 ]] && [[ "$_PF_WARN" -eq 0 ]]; then
    pass
else
    fail "Fresh lock should pass (pass=$_PF_PASS, warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Report generation format
# =============================================================================

echo "=== Report generation ==="

PROJECT_DIR=$(_make_test_dir)

# Set up a project with various markers
echo '{}' > "$PROJECT_DIR/package-lock.json"
mkdir -p "$PROJECT_DIR/node_modules"
touch "$PROJECT_DIR/node_modules/.package-lock.json"
printf 'DATABASE_URL=x\n' > "$PROJECT_DIR/.env.example"
printf 'DATABASE_URL=x\n' > "$PROJECT_DIR/.env"

export PREFLIGHT_AUTO_FIX=false
run_preflight_checks

if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]]; then
    pass
else
    fail "PREFLIGHT_REPORT.md should be created"
fi

# Check report structure
if grep -q "^# Pre-flight Report" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should have title header"
fi

if grep -q "## Summary" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should have Summary section"
fi

if grep -q "## Checks" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should have Checks section"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# PREFLIGHT_AUTO_FIX=false reports but doesn't fix
# =============================================================================

echo "=== PREFLIGHT_AUTO_FIX=false ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

# Missing node_modules — normally would try to fix
echo '{}' > "$PROJECT_DIR/package-lock.json"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_dependencies

# Should fail, not fix
if [[ "$_PF_REMEDIATED" -eq 0 ]]; then
    pass
else
    fail "Auto-fix disabled should not remediate (remediated=$_PF_REMEDIATED)"
fi

if [[ "$_PF_FAIL" -ge 1 ]]; then
    pass
else
    fail "Should report fail when auto-fix disabled (fail=$_PF_FAIL)"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_AUTO_FIX=true

# =============================================================================
# No applicable checks produces no report
# =============================================================================

echo "=== No applicable checks ==="

PROJECT_DIR=$(_make_test_dir)
# Empty project — no markers

run_preflight_checks
rc=$?

if [[ "$rc" -eq 0 ]]; then
    pass
else
    fail "Empty project should return 0 (got $rc)"
fi

if [[ ! -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]]; then
    pass
else
    fail "No report should be created when no checks apply"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# PREFLIGHT_FAIL_ON_WARN=true treats warnings as failures
# =============================================================================

echo "=== PREFLIGHT_FAIL_ON_WARN=true ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_FAIL_ON_WARN=true
export PREFLIGHT_AUTO_FIX=false

# Create a scenario that only produces warnings (missing .env)
printf 'DATABASE_URL=x\n' > "$PROJECT_DIR/.env.example"
# Also need some passing check so we generate a report
echo '{}' > "$PROJECT_DIR/package.json"

rc=0
run_preflight_checks || rc=$?

if [[ "$rc" -ne 0 ]]; then
    pass
else
    fail "PREFLIGHT_FAIL_ON_WARN should cause failure on warnings (got rc=$rc)"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_FAIL_ON_WARN=false
export PREFLIGHT_AUTO_FIX=true

# =============================================================================
# Runtime version check: Node.js match
# =============================================================================

echo "=== Runtime version: Node.js ==="

PROJECT_DIR=$(_make_test_dir)

if command -v node &>/dev/null; then
    node_major=$(node --version | tr -d 'v' | cut -d. -f1)
    echo "$node_major" > "$PROJECT_DIR/.node-version"

    _PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
    _PF_LANGUAGES=""; _PF_TEST_FWS=""
    _preflight_check_runtime_version

    if [[ "$_PF_PASS" -ge 1 ]]; then
        pass
    else
        fail "Matching node version should pass (pass=$_PF_PASS)"
    fi
else
    # Node not installed — skip
    pass
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Runtime version check: Node.js mismatch
# =============================================================================

echo "=== Runtime version: Node.js mismatch ==="

PROJECT_DIR=$(_make_test_dir)

if command -v node &>/dev/null; then
    echo "999" > "$PROJECT_DIR/.node-version"

    _PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
    _PF_LANGUAGES=""; _PF_TEST_FWS=""
    _preflight_check_runtime_version

    if [[ "$_PF_WARN" -ge 1 ]]; then
        pass
    else
        fail "Mismatched node version should warn (warn=$_PF_WARN)"
    fi
else
    pass
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Generated code: Prisma schema without client
# =============================================================================

echo "=== Generated code: Prisma ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

mkdir -p "$PROJECT_DIR/prisma"
echo 'model User { id Int @id }' > "$PROJECT_DIR/prisma/schema.prisma"
mkdir -p "$PROJECT_DIR/node_modules"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_generated_code

if [[ "$_PF_FAIL" -ge 1 ]]; then
    pass
else
    fail "Missing Prisma client should produce a fail (fail=$_PF_FAIL)"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_AUTO_FIX=true

# =============================================================================
# Port check: smoke test (no port in use expected on random port)
# =============================================================================

echo "=== Port check: no server config ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export UI_TEST_CMD=""
export BUILD_CHECK_CMD=""

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_ports

# No ports to check — should produce no results
if [[ "$_PF_PASS" -eq 0 ]] && [[ "$_PF_WARN" -eq 0 ]]; then
    pass
else
    fail "No server config should produce no port checks (pass=$_PF_PASS, warn=$_PF_WARN)"
fi

_cleanup_test_dir "$PROJECT_DIR"
unset UI_TEST_CMD BUILD_CHECK_CMD

# =============================================================================
# Port check: with dev server pattern
# =============================================================================

echo "=== Port check: next dev ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export UI_TEST_CMD="next dev"
export BUILD_CHECK_CMD=""

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_ports

# Port 3000 — should be either pass or warn depending on system state
total=$(( _PF_PASS + _PF_WARN ))
if [[ "$total" -ge 1 ]]; then
    pass
else
    fail "next dev should check port 3000 (total checks=$total)"
fi

_cleanup_test_dir "$PROJECT_DIR"
unset UI_TEST_CMD BUILD_CHECK_CMD

# =============================================================================
# Full run_preflight_checks integration
# =============================================================================

echo "=== Full integration: mixed project ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

# Set up a project with some passing and some warning checks
echo '{"name":"test"}' > "$PROJECT_DIR/package.json"
echo '{}' > "$PROJECT_DIR/package-lock.json"
mkdir -p "$PROJECT_DIR/node_modules"
touch "$PROJECT_DIR/node_modules/.package-lock.json"
printf 'API_KEY=xxx\n' > "$PROJECT_DIR/.env.example"
# No .env — will warn

run_preflight_checks
rc=$?

# Should succeed (warnings don't fail by default)
if [[ "$rc" -eq 0 ]]; then
    pass
else
    fail "Mixed project with warnings should succeed (got rc=$rc)"
fi

# Report should exist
if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]]; then
    pass
else
    fail "Report should be created for mixed project"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_AUTO_FIX=true

# =============================================================================
# M56: Service inference from docker-compose.yml
# =============================================================================

echo "=== Service inference: docker-compose ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: postgres:15
    ports:
      - "5433:5432"
  cache:
    image: redis:7-alpine
COMPOSE

_PF_SERVICES=()
_pf_infer_from_compose

# Should detect 2 services
if [[ ${#_PF_SERVICES[@]} -eq 2 ]]; then
    pass
else
    fail "docker-compose should detect 2 services (got ${#_PF_SERVICES[@]})"
fi

# PostgreSQL should use host port 5433 (not default 5432)
local_pg=""
for entry in "${_PF_SERVICES[@]}"; do
    if [[ "$entry" == PostgreSQL* ]]; then
        local_pg="$entry"
        break
    fi
done
if [[ "$local_pg" == *"|5433|"* ]]; then
    pass
else
    fail "PostgreSQL should use host port 5433 from port mapping (got: $local_pg)"
fi

# Redis should use default port 6379
local_redis=""
for entry in "${_PF_SERVICES[@]}"; do
    if [[ "$entry" == Redis* ]]; then
        local_redis="$entry"
        break
    fi
done
if [[ "$local_redis" == *"|6379|"* ]]; then
    pass
else
    fail "Redis should use default port 6379 (got: $local_redis)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Service inference from package.json
# =============================================================================

echo "=== Service inference: package.json ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/package.json" <<'PKG'
{
  "name": "test-app",
  "dependencies": {
    "ioredis": "^5.0.0",
    "express": "^4.18.0"
  },
  "devDependencies": {
    "mongoose": "^7.0.0"
  }
}
PKG

_PF_SERVICES=()
_pf_infer_from_packages

# Should detect Redis (ioredis) and MongoDB (mongoose)
if [[ ${#_PF_SERVICES[@]} -eq 2 ]]; then
    pass
else
    fail "package.json should detect 2 services (got ${#_PF_SERVICES[@]})"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Service inference from .env.example
# =============================================================================

echo "=== Service inference: .env.example ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/.env.example" <<'ENV'
DATABASE_URL=postgres://localhost:5432/mydb
REDIS_URL=redis://localhost:6379
APP_SECRET=changeme
ENV

_PF_SERVICES=()
_pf_infer_from_env

# Should detect PostgreSQL and Redis
if [[ ${#_PF_SERVICES[@]} -eq 2 ]]; then
    pass
else
    fail ".env.example should detect 2 services (got ${#_PF_SERVICES[@]})"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Service deduplication across sources
# =============================================================================

echo "=== Service dedup: multiple sources ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

# Both docker-compose and package.json mention postgres
cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: postgres:15
COMPOSE

cat > "$PROJECT_DIR/package.json" <<'PKG'
{
  "dependencies": { "pg": "^8.0.0" }
}
PKG

_PF_SERVICES=()
_pf_infer_from_compose
_pf_infer_from_packages

# Should have only 1 PostgreSQL entry (deduplicated)
pg_count=0
for entry in "${_PF_SERVICES[@]}"; do
    [[ "$entry" == PostgreSQL* ]] && pg_count=$((pg_count + 1))
done

if [[ "$pg_count" -eq 1 ]]; then
    pass
else
    fail "PostgreSQL should be deduplicated (got $pg_count entries)"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Port probe with temporary listener
# =============================================================================

echo "=== Port probe: temporary listener ==="

# Start a temporary TCP listener on an ephemeral port
local_port=0
if command -v socat &>/dev/null; then
    socat TCP-LISTEN:0,fork,reuseaddr /dev/null &
    socat_pid=$!
    sleep 0.5
    # Get actual port from /proc or ss
    local_port=$(ss -tlnp 2>/dev/null | grep "pid=${socat_pid}" | grep -oP ':\K\d+' | head -1 || true)
    if [[ -z "$local_port" ]] || [[ "$local_port" == "0" ]]; then
        kill "$socat_pid" 2>/dev/null || true
        wait "$socat_pid" 2>/dev/null || true
        # Fallback: use a known available port with bash /dev/tcp approach
        local_port=""
    fi
fi

# If socat failed, use a fixed high port with a bash listener
if [[ -z "$local_port" ]] || [[ "$local_port" == "0" ]]; then
    local_port=39182
    # Start a simple listener using bash coproc or nc
    if command -v nc &>/dev/null; then
        nc -l -p "$local_port" &>/dev/null &
        socat_pid=$!
        sleep 0.5
    else
        # Skip if no listener tool available
        pass
        echo "  (skipped: no socat or nc available)"
        socat_pid=""
    fi
fi

if [[ -n "${socat_pid:-}" ]]; then
    if _probe_service_port "127.0.0.1" "$local_port" 2; then
        pass
    else
        fail "Port probe should detect open port $local_port"
    fi

    # Kill listener and verify closed port
    kill "$socat_pid" 2>/dev/null || true
    wait "$socat_pid" 2>/dev/null || true
    sleep 0.3

    if ! _probe_service_port "127.0.0.1" "$local_port" 1; then
        pass
    else
        fail "Port probe should detect closed port $local_port after listener stopped"
    fi
fi

# =============================================================================
# M56: Docker daemon check (mock docker command)
# =============================================================================

echo "=== Docker daemon check: not installed ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: postgres:15
COMPOSE

# Override PATH to hide real docker
_orig_path="$PATH"
export PATH="/usr/bin:/bin"

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""

# Only test if docker is truly not in the restricted PATH
if ! command -v docker &>/dev/null; then
    _preflight_check_docker

    if [[ "$_PF_WARN" -ge 1 ]]; then
        pass
    else
        fail "Missing docker should produce warning (warn=$_PF_WARN)"
    fi

    local_report=$(printf '%s\n' "${_PF_REPORT_LINES[@]}")
    if echo "$local_report" | grep -qi "docker.*not.*installed"; then
        pass
    else
        fail "Report should mention docker not installed"
    fi
else
    # docker exists even in restricted PATH — skip
    pass
    pass
fi

export PATH="$_orig_path"
_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Dev server detection from Playwright config
# =============================================================================

echo "=== Dev server: Playwright config ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/playwright.config.ts" <<'PW'
export default defineConfig({
  webServer: {
    command: 'npm run dev',
    url: 'http://localhost:3000',
  },
});
PW

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_preflight_check_dev_server

# Should produce either pass or warn for port 3000
local_total=$(( _PF_PASS + _PF_WARN ))
if [[ "$local_total" -ge 1 ]]; then
    pass
else
    fail "Playwright config should trigger dev server check (total=$local_total)"
fi

local_report=$(printf '%s\n' "${_PF_REPORT_LINES[@]}")
if echo "$local_report" | grep -q "3000"; then
    pass
else
    fail "Report should mention port 3000"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Services report section in PREFLIGHT_REPORT.md
# =============================================================================

echo "=== Services report section ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export PREFLIGHT_AUTO_FIX=false

# Set up project with a service dependency
cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: postgres:15
COMPOSE
echo '{}' > "$PROJECT_DIR/package.json"

run_preflight_checks || true

if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]]; then
    pass
else
    fail "PREFLIGHT_REPORT.md should be created"
fi

# Check for services section
if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]] && grep -q "## Services" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should have Services section"
fi

# Check for table header
if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]] && grep -q "| Service | Port | Status | Source |" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should have services status table"
fi

# Check PostgreSQL appears in table
if [[ -f "$PROJECT_DIR/PREFLIGHT_REPORT.md" ]] && grep -q "PostgreSQL" "$PROJECT_DIR/PREFLIGHT_REPORT.md"; then
    pass
else
    fail "Report should list PostgreSQL in services table"
fi

_cleanup_test_dir "$PROJECT_DIR"
export PREFLIGHT_AUTO_FIX=true

# =============================================================================
# M56: CI environment downgrades service warnings
# =============================================================================

echo "=== CI environment: downgrade warnings ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR
export CI=true

cat > "$PROJECT_DIR/.env.example" <<'ENV'
REDIS_URL=redis://localhost:6379
ENV

_PF_PASS=0; _PF_WARN=0; _PF_FAIL=0; _PF_REMEDIATED=0; _PF_REPORT_LINES=()
_PF_LANGUAGES=""; _PF_TEST_FWS=""
_PF_SERVICES=()
_preflight_check_services

# In CI, service not running should be pass (not warn)
if [[ "$_PF_WARN" -eq 0 ]]; then
    pass
else
    fail "CI should not produce service warnings (warn=$_PF_WARN)"
fi

unset CI
_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Service inference from requirements.txt (Python)
# =============================================================================

echo "=== Service inference: requirements.txt (Python) ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/requirements.txt" <<'REQ'
psycopg2-binary==2.9.9
redis==5.0.0
pymongo==4.6.0
flask==3.0.0
REQ

_PF_SERVICES=()
_pf_infer_from_packages

# Should detect PostgreSQL (psycopg2-binary), Redis, MongoDB (pymongo)
if [[ ${#_PF_SERVICES[@]} -eq 3 ]]; then
    pass
else
    fail "requirements.txt should detect 3 services: PostgreSQL, Redis, MongoDB (got ${#_PF_SERVICES[@]})"
fi

local_pg_found=false
for entry in "${_PF_SERVICES[@]}"; do
    [[ "$entry" == PostgreSQL* ]] && local_pg_found=true
done
if [[ "$local_pg_found" == "true" ]]; then
    pass
else
    fail "requirements.txt with psycopg2-binary should detect PostgreSQL"
fi

local_redis_found=false
for entry in "${_PF_SERVICES[@]}"; do
    [[ "$entry" == Redis* ]] && local_redis_found=true
done
if [[ "$local_redis_found" == "true" ]]; then
    pass
else
    fail "requirements.txt with redis should detect Redis"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Service inference from go.mod (Go)
# =============================================================================

echo "=== Service inference: go.mod (Go) ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

cat > "$PROJECT_DIR/go.mod" <<'GOMOD'
module example.com/app

go 1.21

require (
	github.com/jackc/pgx/v5 v5.4.3
	github.com/redis/go-redis/v9 v9.0.0
)
GOMOD

_PF_SERVICES=()
_pf_infer_from_packages

# Should detect PostgreSQL (pgx) and Redis (go-redis)
if [[ ${#_PF_SERVICES[@]} -eq 2 ]]; then
    pass
else
    fail "go.mod should detect 2 services: PostgreSQL and Redis (got ${#_PF_SERVICES[@]})"
fi

local_pg_found=false
for entry in "${_PF_SERVICES[@]}"; do
    [[ "$entry" == PostgreSQL* ]] && local_pg_found=true
done
if [[ "$local_pg_found" == "true" ]]; then
    pass
else
    fail "go.mod with pgx should detect PostgreSQL"
fi

local_redis_found=false
for entry in "${_PF_SERVICES[@]}"; do
    [[ "$entry" == Redis* ]] && local_redis_found=true
done
if [[ "$local_redis_found" == "true" ]]; then
    pass
else
    fail "go.mod with go-redis should detect Redis"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# M56: Startup instructions appear in services report for not-running services
# =============================================================================

echo "=== Services report: startup instructions ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

# Create compose file so startup instructions are always generated
cat > "$PROJECT_DIR/docker-compose.yml" <<'COMPOSE'
services:
  db:
    image: postgres:15
COMPOSE

# Inject a not_running entry directly — bypasses port probing for determinism
_PF_SERVICES=("PostgreSQL|5432|docker-compose|not_running|5432")

local_report=$(_pf_emit_services_report)

# Report should include the startup instructions header
if echo "$local_report" | grep -q "Start it with:"; then
    pass
else
    fail "Services report should include 'Start it with:' for not-running services"
fi

# When compose file is present, a docker command is always included
if echo "$local_report" | grep -qiE "docker"; then
    pass
else
    fail "Services report should include a docker command when compose file is present"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Results
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
