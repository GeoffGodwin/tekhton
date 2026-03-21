#!/usr/bin/env bash
# Test: run_smart_init() integration — Node.js, Rust, Python detection + config output
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# =============================================================================
# Helper: run --init from a given project directory
# =============================================================================
run_init() {
    local proj_dir="$1"
    cd "$proj_dir"
    TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init </dev/null >/dev/null 2>&1 || true
    cd - >/dev/null
}

# =============================================================================
# Node.js / TypeScript scenario (Acceptance criterion 1)
# =============================================================================
echo "=== Node.js init scenario ==="

NODE_DIR="${TEST_TMPDIR}/node_proj"
mkdir -p "$NODE_DIR/src"
cat > "$NODE_DIR/package.json" << 'EOF'
{
  "name": "my-node-app",
  "scripts": {
    "test": "npm test",
    "lint": "eslint ."
  },
  "devDependencies": {
    "eslint": "^8.0.0"
  }
}
EOF
echo '{"compilerOptions":{"target":"es2020"}}' > "$NODE_DIR/tsconfig.json"
touch "$NODE_DIR/src/index.ts" "$NODE_DIR/src/app.ts"

run_init "$NODE_DIR"

conf="${NODE_DIR}/.claude/pipeline.conf"
[ -f "$conf" ] || { fail "Node.js: pipeline.conf not created"; }

if [ -f "$conf" ]; then
    required_tools=$(grep "^REQUIRED_TOOLS=" "$conf" | cut -d= -f2 | tr -d '"')
    if echo "$required_tools" | grep -q "node" && echo "$required_tools" | grep -q "npm"; then
        pass "Node.js: REQUIRED_TOOLS contains node and npm"
    else
        fail "Node.js: REQUIRED_TOOLS expected 'node npm', got '$required_tools'"
    fi

    if echo "$required_tools" | grep -q "claude" && echo "$required_tools" | grep -q "git"; then
        pass "Node.js: REQUIRED_TOOLS contains claude and git"
    else
        fail "Node.js: REQUIRED_TOOLS missing claude or git: '$required_tools'"
    fi

    # Project name should match directory name
    proj_name=$(grep "^PROJECT_NAME=" "$conf" | cut -d= -f2 | tr -d '"')
    if [[ "$proj_name" = "node_proj" ]]; then
        pass "Node.js: PROJECT_NAME set from directory name"
    else
        fail "Node.js: PROJECT_NAME expected 'node_proj', got '$proj_name'"
    fi
fi

# Verify agent role files were created
if [ -f "${NODE_DIR}/.claude/agents/coder.md" ]; then
    pass "Node.js: coder.md agent role created"
else
    fail "Node.js: coder.md not created"
fi

# Verify CLAUDE.md stub was created with detection results
if [ -f "${NODE_DIR}/CLAUDE.md" ]; then
    if grep -q "Detected Tech Stack" "${NODE_DIR}/CLAUDE.md"; then
        pass "Node.js: CLAUDE.md stub contains detection results"
    else
        fail "Node.js: CLAUDE.md stub missing 'Detected Tech Stack' section"
    fi
else
    fail "Node.js: CLAUDE.md not created"
fi

# =============================================================================
# Rust scenario (Acceptance criterion 2)
# =============================================================================
echo "=== Rust init scenario ==="

RUST_DIR="${TEST_TMPDIR}/rust_proj"
mkdir -p "$RUST_DIR/src"
cat > "$RUST_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-rust-tool"
version = "0.1.0"
edition = "2021"

[[bin]]
name = "my-rust-tool"
path = "src/main.rs"
EOF
echo 'fn main() { println!("hello"); }' > "$RUST_DIR/src/main.rs"

run_init "$RUST_DIR"

conf="${RUST_DIR}/.claude/pipeline.conf"
[ -f "$conf" ] || { fail "Rust: pipeline.conf not created"; }

if [ -f "$conf" ]; then
    required_tools=$(grep "^REQUIRED_TOOLS=" "$conf" | cut -d= -f2 | tr -d '"')
    if echo "$required_tools" | grep -q "cargo"; then
        pass "Rust: REQUIRED_TOOLS contains cargo"
    else
        fail "Rust: REQUIRED_TOOLS expected 'cargo', got '$required_tools'"
    fi

    if echo "$required_tools" | grep -q "claude" && echo "$required_tools" | grep -q "git"; then
        pass "Rust: REQUIRED_TOOLS contains claude and git"
    else
        fail "Rust: REQUIRED_TOOLS missing claude or git: '$required_tools'"
    fi
fi

# =============================================================================
# Python scenario (Acceptance criterion 3)
# =============================================================================
echo "=== Python init scenario ==="

PY_DIR="${TEST_TMPDIR}/python_proj"
mkdir -p "$PY_DIR"
cat > "$PY_DIR/pyproject.toml" << 'EOF'
[project]
name = "my-python-app"
version = "0.1.0"

[tool.pytest.ini_options]
testpaths = ["tests"]

[tool.ruff]
line-length = 88
EOF
touch "$PY_DIR/main.py" "$PY_DIR/app.py"

run_init "$PY_DIR"

conf="${PY_DIR}/.claude/pipeline.conf"
[ -f "$conf" ] || { fail "Python: pipeline.conf not created"; }

if [ -f "$conf" ]; then
    required_tools=$(grep "^REQUIRED_TOOLS=" "$conf" | cut -d= -f2 | tr -d '"')
    if echo "$required_tools" | grep -q "python"; then
        pass "Python: REQUIRED_TOOLS contains python"
    else
        fail "Python: REQUIRED_TOOLS expected 'python', got '$required_tools'"
    fi

    if echo "$required_tools" | grep -q "claude" && echo "$required_tools" | grep -q "git"; then
        pass "Python: REQUIRED_TOOLS contains claude and git"
    else
        fail "Python: REQUIRED_TOOLS missing claude or git: '$required_tools'"
    fi
fi

# =============================================================================
# --reinit flag: re-initialization of existing project
# =============================================================================
echo "=== --reinit flag ==="

REINIT_DIR="${TEST_TMPDIR}/reinit_proj"
mkdir -p "$REINIT_DIR"
cat > "$REINIT_DIR/package.json" << 'EOF'
{"name":"reinit-test"}
EOF

# First init
run_init "$REINIT_DIR"
conf="${REINIT_DIR}/.claude/pipeline.conf"

if [ -f "$conf" ]; then
    pass "--reinit scenario: first --init created pipeline.conf"
else
    fail "--reinit scenario: first --init did not create pipeline.conf"
fi

# Re-run --init without --reinit: should fail (conf exists)
cd "$REINIT_DIR"
if TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init </dev/null >/dev/null 2>&1; then
    fail "--init on existing project should exit non-zero (use --reinit)"
else
    pass "--init on existing project exits non-zero (warns to use --reinit)"
fi
cd - >/dev/null

# =============================================================================
# Brownfield routing: project with >50 tracked files
# Routes to --plan-from-index hint in output
# =============================================================================
echo "=== Brownfield routing (>50 files) ==="

BROWNFIELD_DIR="${TEST_TMPDIR}/brownfield_proj"
mkdir -p "$BROWNFIELD_DIR"
# Create 55 stub files to cross the brownfield threshold
for i in $(seq 1 55); do
    touch "${BROWNFIELD_DIR}/file${i}.txt"
done

cd "$BROWNFIELD_DIR"
init_output=$(TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init </dev/null 2>&1) || true
cd - >/dev/null

if echo "$init_output" | grep -q "plan-from-index"; then
    pass "Brownfield (>50 files): routing suggests --plan-from-index"
else
    fail "Brownfield (>50 files): expected --plan-from-index in output, got: $(echo "$init_output" | tail -5)"
fi

# =============================================================================
# Greenfield routing: project with <50 tracked files
# Routes to --plan hint in output
# =============================================================================
echo "=== Greenfield routing (<50 files) ==="

GREENFIELD_DIR="${TEST_TMPDIR}/greenfield_proj"
mkdir -p "$GREENFIELD_DIR"
# Only a few files — greenfield
touch "$GREENFIELD_DIR/main.py"

cd "$GREENFIELD_DIR"
green_output=$(TEKHTON_NON_INTERACTIVE=true bash "${TEKHTON_HOME}/tekhton.sh" --init </dev/null 2>&1) || true
cd - >/dev/null

# Should suggest --plan (not --plan-from-index)
if echo "$green_output" | grep -q "tekhton --plan" && ! echo "$green_output" | grep -q "plan-from-index"; then
    pass "Greenfield (<50 files): routing suggests --plan"
else
    fail "Greenfield (<50 files): expected '--plan' routing, got: $(echo "$green_output" | tail -5)"
fi

# =============================================================================
# TypeScript addendum appended to agent role files
# =============================================================================
echo "=== TypeScript addendum appended to agent roles ==="

TS_ADD_DIR="${TEST_TMPDIR}/ts_addendum_proj"
mkdir -p "$TS_ADD_DIR/src"
cat > "$TS_ADD_DIR/package.json" << 'EOF'
{"name":"ts-addendum-test"}
EOF
echo '{"compilerOptions":{}}' > "$TS_ADD_DIR/tsconfig.json"
touch "$TS_ADD_DIR/src/index.ts"

run_init "$TS_ADD_DIR"

addendum="${TEKHTON_HOME}/templates/agents/addenda/typescript.md"
if [ -f "$addendum" ] && [ -f "${TS_ADD_DIR}/.claude/agents/coder.md" ]; then
    # The last few lines of the addendum should appear in the coder.md
    last_line=$(tail -1 "$addendum")
    if grep -qF -- "$last_line" "${TS_ADD_DIR}/.claude/agents/coder.md"; then
        pass "TypeScript addendum content appended to coder.md"
    else
        fail "TypeScript addendum not found in coder.md (last line of addendum not present)"
    fi
else
    pass "TypeScript addendum file absent — skip addendum append test"
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
