#!/usr/bin/env bash
# Test: Milestone 17 — detect_entry_points function
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

# Source detection library
# shellcheck source=../lib/detect_commands.sh
source "${TEKHTON_HOME}/lib/detect_commands.sh"

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
# detect_entry_points — standard entry points exist
# =============================================================================
echo "=== detect_entry_points ==="

EP_DIR=$(make_proj "ep_project")
mkdir -p "$EP_DIR/src"
touch "$EP_DIR/src/main.rs"
touch "$EP_DIR/Makefile"
touch "$EP_DIR/Dockerfile"

ep_list=$(detect_entry_points "$EP_DIR")

if echo "$ep_list" | grep -q "^src/main.rs$"; then
    pass "src/main.rs detected as entry point"
else
    fail "src/main.rs not detected: $ep_list"
fi

if echo "$ep_list" | grep -q "^Makefile$"; then
    pass "Makefile detected as entry point"
else
    fail "Makefile not detected: $ep_list"
fi

if echo "$ep_list" | grep -q "^Dockerfile$"; then
    pass "Dockerfile detected as entry point"
else
    fail "Dockerfile not detected: $ep_list"
fi

# =============================================================================
# detect_entry_points — Go cmd/ pattern
# =============================================================================
echo "=== detect_entry_points: Go cmd/ pattern ==="

GO_EP_DIR=$(make_proj "go_ep")
mkdir -p "$GO_EP_DIR/cmd/server" "$GO_EP_DIR/cmd/worker"
touch "$GO_EP_DIR/cmd/server/main.go"
touch "$GO_EP_DIR/cmd/worker/main.go"

go_ep=$(detect_entry_points "$GO_EP_DIR")

if echo "$go_ep" | grep -q "cmd/server/main.go"; then
    pass "cmd/server/main.go detected as Go entry point"
else
    fail "cmd/server/main.go not detected: $go_ep"
fi

if echo "$go_ep" | grep -q "cmd/worker/main.go"; then
    pass "cmd/worker/main.go detected as Go entry point"
else
    fail "cmd/worker/main.go not detected: $go_ep"
fi

# =============================================================================
# detect_entry_points — empty dir (safe)
# =============================================================================
echo "=== detect_entry_points: empty directory ==="

EMPTY_EP_DIR=$(make_proj "empty_ep")
empty_ep=$(detect_entry_points "$EMPTY_EP_DIR")
if [[ -z "$empty_ep" ]]; then
    pass "Empty dir returns empty entry point list"
else
    fail "Empty dir should return empty list, got: $empty_ep"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "────────────────────────────────────────"
echo "  Passed: ${PASS}  Failed: ${FAIL}"
echo "────────────────────────────────────────"

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
