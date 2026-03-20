#!/usr/bin/env bash
# Test: Milestone 17 — detect_commands function
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

# Source detection libraries (detect.sh provides _extract_json_keys used by detect_commands.sh)
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
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
# detect_commands — npm test from package.json scripts.test
# =============================================================================
echo "=== detect_commands: npm test from package.json ==="

NPM_CMD_DIR=$(make_proj "npm_cmd")
cat > "$NPM_CMD_DIR/package.json" << 'EOF'
{
  "name": "my-app",
  "scripts": {
    "test": "jest --coverage",
    "lint": "eslint .",
    "build": "tsc"
  }
}
EOF

npm_cmds=$(detect_commands "$NPM_CMD_DIR")

if echo "$npm_cmds" | grep -q "^test|npm test|package.json scripts.test|high"; then
    pass "npm test detected from package.json scripts.test with high confidence"
else
    fail "npm test not correctly detected: $npm_cmds"
fi

if echo "$npm_cmds" | grep -q "^analyze|npm run lint|package.json scripts.lint|high"; then
    pass "npm run lint detected from package.json scripts.lint"
else
    fail "npm run lint not detected: $npm_cmds"
fi

if echo "$npm_cmds" | grep -q "^build|npm run build|package.json scripts.build|high"; then
    pass "npm run build detected from package.json scripts.build"
else
    fail "npm run build not detected: $npm_cmds"
fi

# =============================================================================
# detect_commands — cargo test from Cargo.toml
# =============================================================================
echo "=== detect_commands: cargo test from Cargo.toml ==="

CARGO_CMD_DIR=$(make_proj "cargo_cmd")
cat > "$CARGO_CMD_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-crate"
version = "0.1.0"
EOF

cargo_cmds=$(detect_commands "$CARGO_CMD_DIR")

if echo "$cargo_cmds" | grep -q "^test|cargo test|Cargo.toml present|high"; then
    pass "cargo test detected from Cargo.toml presence with high confidence"
else
    fail "cargo test not detected: $cargo_cmds"
fi

if echo "$cargo_cmds" | grep -q "^build|cargo build|Cargo.toml present|high"; then
    pass "cargo build detected from Cargo.toml"
else
    fail "cargo build not detected: $cargo_cmds"
fi

# =============================================================================
# detect_commands — pytest from pyproject.toml [tool.pytest]
# =============================================================================
echo "=== detect_commands: pytest from pyproject.toml [tool.pytest] ==="

PY_CMD_DIR=$(make_proj "py_cmd")
cat > "$PY_CMD_DIR/pyproject.toml" << 'EOF'
[project]
name = "my-app"

[tool.pytest.ini_options]
testpaths = ["tests"]
EOF

py_cmds=$(detect_commands "$PY_CMD_DIR")

if echo "$py_cmds" | grep -q "^test|pytest|pyproject.toml \[tool.pytest\]|high"; then
    pass "pytest detected from pyproject.toml [tool.pytest] with high confidence"
else
    fail "pytest high-confidence not detected: $py_cmds"
fi

# =============================================================================
# detect_commands — pytest medium confidence (pyproject.toml without [tool.pytest])
# =============================================================================
echo "=== detect_commands: pytest medium from plain pyproject.toml ==="

PY_MED_DIR=$(make_proj "py_med")
cat > "$PY_MED_DIR/pyproject.toml" << 'EOF'
[project]
name = "my-app"
EOF

py_med_cmds=$(detect_commands "$PY_MED_DIR")

if echo "$py_med_cmds" | grep -q "^test|pytest|pyproject.toml present|medium"; then
    pass "pytest detected with medium confidence from plain pyproject.toml"
else
    fail "pytest medium-confidence not detected: $py_med_cmds"
fi

# =============================================================================
# detect_commands — go test from go.mod
# =============================================================================
echo "=== detect_commands: go test from go.mod ==="

GO_CMD_DIR=$(make_proj "go_cmd")
cat > "$GO_CMD_DIR/go.mod" << 'EOF'
module github.com/example/myapp

go 1.21
EOF

go_cmds=$(detect_commands "$GO_CMD_DIR")

if echo "$go_cmds" | grep -q "^test|go test ./\.\.\.|go.mod present|high"; then
    pass "go test ./... detected from go.mod"
else
    fail "go test not detected: $go_cmds"
fi

# =============================================================================
# detect_commands — Makefile targets
# =============================================================================
echo "=== detect_commands: Makefile targets ==="

MAKE_DIR=$(make_proj "make_proj")
cat > "$MAKE_DIR/Makefile" << 'EOF'
test:
	bash tests/run_tests.sh

lint:
	shellcheck lib/*.sh

build:
	echo "build"
EOF

make_cmds=$(detect_commands "$MAKE_DIR")

if echo "$make_cmds" | grep -q "^test|make test|Makefile test target|high"; then
    pass "make test detected from Makefile test: target"
else
    fail "make test not detected: $make_cmds"
fi

if echo "$make_cmds" | grep -q "^analyze|make lint|Makefile lint target|high"; then
    pass "make lint detected from Makefile lint: target"
else
    fail "make lint not detected: $make_cmds"
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
