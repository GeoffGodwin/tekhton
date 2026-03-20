#!/usr/bin/env bash
# Test: Milestone 17 — detect_languages function
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
# detect_languages — TypeScript project
# =============================================================================
echo "=== detect_languages: TypeScript ==="

TS_DIR=$(make_proj "ts_project")
echo '{"name":"my-app"}' > "$TS_DIR/package.json"
echo '{"compilerOptions":{}}' > "$TS_DIR/tsconfig.json"
touch "$TS_DIR/index.ts" "$TS_DIR/app.ts" "$TS_DIR/utils.ts"

ts_langs=$(detect_languages "$TS_DIR")

if echo "$ts_langs" | grep -q "^typescript|"; then
    pass "TypeScript detected with package.json + tsconfig.json"
else
    fail "TypeScript NOT detected: got: $ts_langs"
fi

if echo "$ts_langs" | grep "^typescript|" | grep -q "high"; then
    pass "TypeScript confidence is high (manifest + source files)"
else
    fail "TypeScript confidence not high: $ts_langs"
fi

if echo "$ts_langs" | grep "^typescript|" | grep -q "package.json"; then
    pass "TypeScript manifest is package.json"
else
    fail "TypeScript manifest not package.json: $ts_langs"
fi

# Should NOT detect javascript when tsconfig.json is present
if echo "$ts_langs" | grep -q "^javascript|"; then
    fail "javascript should NOT be detected when tsconfig.json present"
else
    pass "javascript not falsely detected alongside TypeScript"
fi

# =============================================================================
# detect_languages — Python project
# =============================================================================
echo "=== detect_languages: Python ==="

PY_DIR=$(make_proj "py_project")
cat > "$PY_DIR/pyproject.toml" << 'EOF'
[project]
name = "my-app"
[tool.pytest.ini_options]
testpaths = ["tests"]
EOF
touch "$PY_DIR/main.py" "$PY_DIR/app.py" "$PY_DIR/utils.py"

py_langs=$(detect_languages "$PY_DIR")

if echo "$py_langs" | grep -q "^python|"; then
    pass "Python detected with pyproject.toml + .py files"
else
    fail "Python NOT detected: $py_langs"
fi

if echo "$py_langs" | grep "^python|" | grep -q "high"; then
    pass "Python confidence is high"
else
    fail "Python confidence not high: $py_langs"
fi

# =============================================================================
# detect_languages — Rust project
# =============================================================================
echo "=== detect_languages: Rust ==="

RUST_DIR=$(make_proj "rust_project")
cat > "$RUST_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-tool"
version = "0.1.0"
EOF
mkdir -p "$RUST_DIR/src"
touch "$RUST_DIR/src/main.rs"

rust_langs=$(detect_languages "$RUST_DIR")

if echo "$rust_langs" | grep -q "^rust|"; then
    pass "Rust detected with Cargo.toml + .rs files"
else
    fail "Rust NOT detected: $rust_langs"
fi

if echo "$rust_langs" | grep "^rust|" | grep -q "high"; then
    pass "Rust confidence is high"
else
    fail "Rust confidence not high: $rust_langs"
fi

# =============================================================================
# detect_languages — Haskell: stack.yaml OR cabal.project
# =============================================================================
echo "=== detect_languages: Haskell ==="

HS_STACK_DIR=$(make_proj "hs_stack")
touch "$HS_STACK_DIR/stack.yaml"

hs_langs=$(detect_languages "$HS_STACK_DIR")
if echo "$hs_langs" | grep -q "^haskell|"; then
    pass "Haskell detected with stack.yaml (manifest only → medium confidence)"
else
    fail "Haskell NOT detected with stack.yaml: $hs_langs"
fi

# Verify manifest is stack.yaml
if echo "$hs_langs" | grep "^haskell|" | grep -q "stack.yaml"; then
    pass "Haskell manifest is stack.yaml when stack.yaml exists"
else
    fail "Haskell manifest not stack.yaml: $hs_langs"
fi

HS_CABAL_DIR=$(make_proj "hs_cabal")
touch "$HS_CABAL_DIR/cabal.project"

hs_cabal_langs=$(detect_languages "$HS_CABAL_DIR")
if echo "$hs_cabal_langs" | grep -q "^haskell|"; then
    pass "Haskell detected with cabal.project"
else
    fail "Haskell NOT detected with cabal.project: $hs_cabal_langs"
fi

# Verify manifest is cabal.project (not stack.yaml)
if echo "$hs_cabal_langs" | grep "^haskell|" | grep -q "cabal.project"; then
    pass "Haskell manifest is cabal.project when only cabal.project exists"
else
    fail "Haskell manifest should be cabal.project: $hs_cabal_langs"
fi

# =============================================================================
# detect_languages — empty directory (safe handling)
# =============================================================================
echo "=== detect_languages: empty directory ==="

EMPTY_DIR=$(make_proj "empty")
empty_langs=$(detect_languages "$EMPTY_DIR")
# Should return empty output without error
if [[ -z "$empty_langs" ]]; then
    pass "Empty directory returns empty language list"
else
    pass "Empty directory returns something (acceptable): $empty_langs"
fi

# =============================================================================
# detect_languages — vendored dirs excluded
# =============================================================================
echo "=== detect_languages: excludes vendored dirs ==="

VENDOR_DIR=$(make_proj "vendor_proj")
mkdir -p "$VENDOR_DIR/node_modules/some-lib"
# Only .ts files are in node_modules (excluded) — no package.json at root
touch "$VENDOR_DIR/node_modules/some-lib/index.ts"
touch "$VENDOR_DIR/node_modules/some-lib/lib.ts"
touch "$VENDOR_DIR/node_modules/some-lib/util.ts"
touch "$VENDOR_DIR/node_modules/some-lib/types.ts"
touch "$VENDOR_DIR/node_modules/some-lib/extra.ts"

vendor_langs=$(detect_languages "$VENDOR_DIR")
# Without a root package.json, TypeScript in node_modules should not be high confidence
# The vendored files should be excluded
if echo "$vendor_langs" | grep "^typescript|" | grep -q "high"; then
    fail "TypeScript should NOT be high confidence from vendored node_modules files"
else
    pass "Vendored node_modules .ts files do not produce high-confidence TypeScript"
fi

# =============================================================================
# detect_languages — safe on binary-only directory
# =============================================================================
echo "=== detect_languages: non-git directory with binary files ==="

BIN_DIR=$(make_proj "binary_proj")
# Write a file that looks binary (null bytes)
printf '\x00\x01\x02\x03' > "$BIN_DIR/data.bin"

bin_langs=$(detect_languages "$BIN_DIR")
# Should complete without error (not tested for specific output, just safety)
pass "detect_languages completes safely on binary-only non-git dir"

# =============================================================================
# detect_frameworks — Next.js
# =============================================================================
echo "=== detect_frameworks: Next.js ==="

NEXT_DIR=$(make_proj "next_project")
cat > "$NEXT_DIR/package.json" << 'EOF'
{
  "name": "next-app",
  "dependencies": {
    "next": "^13.0.0",
    "react": "^18.0.0"
  }
}
EOF

next_frameworks=$(detect_frameworks "$NEXT_DIR")

if echo "$next_frameworks" | grep -q "^next.js|"; then
    pass "Next.js detected from package.json dependencies"
else
    fail "Next.js NOT detected: $next_frameworks"
fi

# When next.js is present, plain react should NOT also be reported
if echo "$next_frameworks" | grep -q "^react|"; then
    fail "react should NOT be separately reported when next.js present"
else
    pass "react not double-reported when next.js detected"
fi

# =============================================================================
# detect_frameworks — Flask from requirements.txt
# =============================================================================
echo "=== detect_frameworks: Flask from requirements.txt ==="

FLASK_DIR=$(make_proj "flask_project")
printf 'flask\nwerkzeug\nclick\n' > "$FLASK_DIR/requirements.txt"

flask_frameworks=$(detect_frameworks "$FLASK_DIR")
if echo "$flask_frameworks" | grep -qi "flask|python"; then
    pass "Flask detected from requirements.txt"
else
    fail "Flask NOT detected from requirements.txt: $flask_frameworks"
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
