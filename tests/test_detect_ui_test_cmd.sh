#!/usr/bin/env bash
# =============================================================================
# test_detect_ui_test_cmd.sh — Unit tests for detect_ui_test_cmd() (Milestone 28)
#
# Tests:
#   1.  playwright framework → "npx playwright test"
#   2.  cypress framework → "npx cypress run"
#   3.  detox framework → "npx detox test"
#   4.  selenium framework (Python/requirements.txt) → "pytest tests/ -k e2e"
#   5.  selenium framework without requirements.txt → empty (no command)
#   6.  empty framework → empty output
#   7.  unknown framework string → empty output
#   8.  package.json "test:e2e" script → "npm run test:e2e"
#   9.  package.json "e2e" script → "npm run e2e"
#  10.  package.json "test:ui" script → "npm run test:ui"
#  11.  package.json "test:integration" script → "npm run test:integration"
#  12.  package.json scripts take priority over framework convention
#  13.  framework convention used when no matching package.json scripts
#  14.  testing-library framework → empty (no conventional test command)
#  15.  puppeteer framework → empty (no conventional test command)
# =============================================================================
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

# Source detection libraries (detect.sh provides _extract_json_keys)
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"
# shellcheck source=../lib/detect_commands.sh
source "${TEKHTON_HOME}/lib/detect_commands.sh"

# =============================================================================
# Helper
# =============================================================================
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# =============================================================================
# Test 1: playwright → npx playwright test
# =============================================================================
echo "=== detect_ui_test_cmd: playwright framework ==="

EMPTY_DIR=$(make_proj "plain_playwright")
result=$(detect_ui_test_cmd "$EMPTY_DIR" "playwright")
if [[ "$result" == "npx playwright test" ]]; then
    pass "playwright framework → 'npx playwright test'"
else
    fail "playwright framework → expected 'npx playwright test', got '$result'"
fi

# =============================================================================
# Test 2: cypress → npx cypress run
# =============================================================================
echo "=== detect_ui_test_cmd: cypress framework ==="

CY_DIR=$(make_proj "plain_cypress")
result=$(detect_ui_test_cmd "$CY_DIR" "cypress")
if [[ "$result" == "npx cypress run" ]]; then
    pass "cypress framework → 'npx cypress run'"
else
    fail "cypress framework → expected 'npx cypress run', got '$result'"
fi

# =============================================================================
# Test 3: detox → npx detox test
# =============================================================================
echo "=== detect_ui_test_cmd: detox framework ==="

DETOX_DIR=$(make_proj "plain_detox")
result=$(detect_ui_test_cmd "$DETOX_DIR" "detox")
if [[ "$result" == "npx detox test" ]]; then
    pass "detox framework → 'npx detox test'"
else
    fail "detox framework → expected 'npx detox test', got '$result'"
fi

# =============================================================================
# Test 4: selenium with requirements.txt → pytest tests/ -k e2e
# =============================================================================
echo "=== detect_ui_test_cmd: selenium (Python) ==="

SEL_PY_DIR=$(make_proj "selenium_py_cmd")
touch "$SEL_PY_DIR/requirements.txt"
result=$(detect_ui_test_cmd "$SEL_PY_DIR" "selenium")
if [[ "$result" == "pytest tests/ -k e2e" ]]; then
    pass "selenium (Python) → 'pytest tests/ -k e2e'"
else
    fail "selenium (Python) → expected 'pytest tests/ -k e2e', got '$result'"
fi

# =============================================================================
# Test 5: selenium without requirements.txt → empty (no Java fallback)
# =============================================================================
echo "=== detect_ui_test_cmd: selenium without requirements.txt ==="

SEL_NOREQ_DIR=$(make_proj "selenium_noreq")
result=$(detect_ui_test_cmd "$SEL_NOREQ_DIR" "selenium")
if [[ -z "$result" ]]; then
    pass "selenium without requirements.txt → empty (no convention)"
else
    fail "selenium without requirements.txt → expected empty, got '$result'"
fi

# =============================================================================
# Test 6: empty framework → empty output
# =============================================================================
echo "=== detect_ui_test_cmd: empty framework ==="

EMPTY_FW_DIR=$(make_proj "empty_fw")
result=$(detect_ui_test_cmd "$EMPTY_FW_DIR" "")
if [[ -z "$result" ]]; then
    pass "empty framework → empty output"
else
    fail "empty framework → expected empty, got '$result'"
fi

# =============================================================================
# Test 7: unknown framework → empty output
# =============================================================================
echo "=== detect_ui_test_cmd: unknown framework ==="

UNK_DIR=$(make_proj "unknown_fw")
result=$(detect_ui_test_cmd "$UNK_DIR" "unknownframework")
if [[ -z "$result" ]]; then
    pass "unknown framework → empty output"
else
    fail "unknown framework → expected empty, got '$result'"
fi

# =============================================================================
# Test 8: package.json "test:e2e" script → npm run test:e2e
# =============================================================================
echo "=== detect_ui_test_cmd: package.json test:e2e ==="

E2E_DIR=$(make_proj "e2e_script")
cat > "$E2E_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test": "jest",
    "test:e2e": "playwright test"
  }
}
EOF
result=$(detect_ui_test_cmd "$E2E_DIR" "")
if [[ "$result" == "npm run test:e2e" ]]; then
    pass "package.json test:e2e script → 'npm run test:e2e'"
else
    fail "package.json test:e2e → expected 'npm run test:e2e', got '$result'"
fi

# =============================================================================
# Test 9: package.json "e2e" script → npm run e2e
# =============================================================================
echo "=== detect_ui_test_cmd: package.json e2e ==="

E2E2_DIR=$(make_proj "e2e2_script")
cat > "$E2E2_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test": "jest",
    "e2e": "cypress run"
  }
}
EOF
result=$(detect_ui_test_cmd "$E2E2_DIR" "")
if [[ "$result" == "npm run e2e" ]]; then
    pass "package.json e2e script → 'npm run e2e'"
else
    fail "package.json e2e → expected 'npm run e2e', got '$result'"
fi

# =============================================================================
# Test 10: package.json "test:ui" script → npm run test:ui
# =============================================================================
echo "=== detect_ui_test_cmd: package.json test:ui ==="

UI_SCRIPT_DIR=$(make_proj "ui_script")
cat > "$UI_SCRIPT_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test:ui": "wdio run wdio.conf.js"
  }
}
EOF
result=$(detect_ui_test_cmd "$UI_SCRIPT_DIR" "")
if [[ "$result" == "npm run test:ui" ]]; then
    pass "package.json test:ui script → 'npm run test:ui'"
else
    fail "package.json test:ui → expected 'npm run test:ui', got '$result'"
fi

# =============================================================================
# Test 11: package.json "test:integration" script → npm run test:integration
# =============================================================================
echo "=== detect_ui_test_cmd: package.json test:integration ==="

INT_DIR=$(make_proj "integration_script")
cat > "$INT_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test:integration": "jest --config jest.integration.config.js"
  }
}
EOF
result=$(detect_ui_test_cmd "$INT_DIR" "")
if [[ "$result" == "npm run test:integration" ]]; then
    pass "package.json test:integration script → 'npm run test:integration'"
else
    fail "package.json test:integration → expected 'npm run test:integration', got '$result'"
fi

# =============================================================================
# Test 12: package.json e2e script takes priority over framework convention
# =============================================================================
echo "=== detect_ui_test_cmd: package.json script priority over convention ==="

PRIORITY_DIR=$(make_proj "priority_pkg")
cat > "$PRIORITY_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test:e2e": "playwright test --project=chromium"
  }
}
EOF
# Framework is playwright, but package.json should win
result=$(detect_ui_test_cmd "$PRIORITY_DIR" "playwright")
if [[ "$result" == "npm run test:e2e" ]]; then
    pass "package.json test:e2e takes priority over playwright convention"
else
    fail "priority test → expected 'npm run test:e2e', got '$result'"
fi

# =============================================================================
# Test 13: framework convention used when no matching package.json scripts
# =============================================================================
echo "=== detect_ui_test_cmd: framework convention fallback ==="

FALLBACK_DIR=$(make_proj "fallback_pkg")
cat > "$FALLBACK_DIR/package.json" << 'EOF'
{
  "name": "app",
  "scripts": {
    "test": "jest",
    "build": "tsc"
  }
}
EOF
result=$(detect_ui_test_cmd "$FALLBACK_DIR" "cypress")
if [[ "$result" == "npx cypress run" ]]; then
    pass "cypress convention used when no e2e/test:e2e scripts in package.json"
else
    fail "convention fallback → expected 'npx cypress run', got '$result'"
fi

# =============================================================================
# Test 14: testing-library → empty (no conventional command)
# =============================================================================
echo "=== detect_ui_test_cmd: testing-library framework ==="

TL_DIR=$(make_proj "testing_library_cmd")
result=$(detect_ui_test_cmd "$TL_DIR" "testing-library")
if [[ -z "$result" ]]; then
    pass "testing-library framework → empty (no standalone E2E command)"
else
    fail "testing-library → expected empty, got '$result'"
fi

# =============================================================================
# Test 15: puppeteer → empty (no conventional command in implementation)
# =============================================================================
echo "=== detect_ui_test_cmd: puppeteer framework ==="

PUP_DIR=$(make_proj "puppeteer_cmd")
result=$(detect_ui_test_cmd "$PUP_DIR" "puppeteer")
if [[ -z "$result" ]]; then
    pass "puppeteer framework → empty (no conventional test command)"
else
    fail "puppeteer → expected empty, got '$result'"
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
