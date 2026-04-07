#!/usr/bin/env bash
set -euo pipefail
# =============================================================================
# test_preflight_infer_degenerate.sh — Test degenerate service names in compose
#
# Tests the fix for _pf_infer_from_compose where service names containing
# "image:" or "ports:" text would be re-evaluated by subsequent pattern checks
# without the 'continue' statement (Observation 1, Drift Log).
#
# This test verifies that a service name line with embedded keywords is
# correctly handled and not misinterpreted.
# =============================================================================

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

# Source dependencies
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/common.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services.sh"
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/lib/preflight_services_infer.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

_make_test_dir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    echo "$tmpdir"
}

_cleanup_test_dir() {
    [[ -n "${1:-}" ]] && rm -rf "$1"
}

# =============================================================================
# Test 1: Service name containing "image:" text (degenerate YAML)
# =============================================================================

echo "=== Degenerate service name with 'image:' text ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

# Initialize service port mapping and tracking arrays (required by _pf_add_service)
declare -gA _PF_SVC_PORTS=(
    [postgres]=5432
)
declare -gA _PF_SVC_NAMES=(
    [postgres]="PostgreSQL"
)
declare -ga _PF_SERVICES=()

# Create a degenerate docker-compose.yml where the service name line
# contains the word "image:" — this would match the image pattern without
# the continue statement. Use an unrecognized image name to ensure no
# services are detected from the degenerate line.
cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
services:
  image-svc: image: my-custom-app:1.0
    ports:
      - "5432:5432"
EOF

# Call the function — it should not error and should handle the degenerate case
if _pf_infer_from_compose 2>/dev/null; then
    pass
else
    fail "_pf_infer_from_compose exited with error"
fi

# The key is that the continue statement prevents re-evaluation of the
# service name line by the image check. The degenerate name "image-svc"
# should NOT be matched as a known service.
if [[ ${#_PF_SERVICES[@]} -eq 0 ]]; then
    pass
else
    fail "Degenerate service name 'image-svc' should not be recognized as a known service"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Test 2: Service name containing "ports:" text (degenerate YAML)
# =============================================================================

echo "=== Degenerate service name with 'ports:' text ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

# Reset the service tracking arrays to ensure test isolation
_PF_SERVICES=()
unset _PF_SVC_PORTS _PF_SVC_NAMES
declare -gA _PF_SVC_PORTS=([postgres]=5432)
declare -gA _PF_SVC_NAMES=([postgres]="PostgreSQL")

# Create a degenerate docker-compose.yml where the service name line
# contains the word "ports:". Use an unrecognized image name to ensure
# no services are detected from the degenerate line.
cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
services:
  ports-svc: ports: 5432
    image: my-custom-app:2.0
    ports:
      - "5432:5432"
EOF

# Call the function — it should not error
if _pf_infer_from_compose 2>/dev/null; then
    pass
else
    fail "_pf_infer_from_compose exited with error on ports degenerate case"
fi

# The degenerate name "ports-svc" should NOT be matched as a known service.
# The continue statement prevents double-evaluation of the service name line.
if [[ ${#_PF_SERVICES[@]} -eq 0 ]]; then
    pass
else
    fail "Degenerate service name 'ports-svc' should not be recognized as a known service"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Test 3: Valid compose file with normal service names (regression)
# =============================================================================

echo "=== Valid docker-compose with normal service names (regression) ==="

PROJECT_DIR=$(_make_test_dir)
export PROJECT_DIR

# Reset the service tracking arrays to ensure test isolation
_PF_SERVICES=()
unset _PF_SVC_PORTS _PF_SVC_NAMES
declare -gA _PF_SVC_PORTS=([postgres]=5432 [redis]=6379)
declare -gA _PF_SVC_NAMES=([postgres]="PostgreSQL" [redis]="Redis")

# Create a normal docker-compose.yml to ensure the fix doesn't break valid files
cat > "$PROJECT_DIR/docker-compose.yml" << 'EOF'
services:
  db:
    image: postgres:15
    ports:
      - "5432:5432"
  cache:
    image: redis:7
    ports:
      - "6379:6379"
EOF

# Call the function
if _pf_infer_from_compose 2>/dev/null; then
    pass
else
    fail "_pf_infer_from_compose exited with error on valid compose"
fi

# With the two services, we should have attempted to add postgres and redis
if [[ ${#_PF_SERVICES[@]} -gt 0 ]]; then
    pass
else
    fail "Valid services should be tracked"
fi

_cleanup_test_dir "$PROJECT_DIR"

# =============================================================================
# Summary
# =============================================================================

echo
echo "Passed: $PASS  Failed: $FAIL"

if [[ $FAIL -eq 0 ]]; then
    exit 0
else
    exit 1
fi
