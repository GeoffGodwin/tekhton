#!/usr/bin/env bash
# =============================================================================
# test_detect_ui_framework.sh — Unit tests for detect_ui_framework() (Milestone 28)
#
# Tests:
#   1.  Playwright detected from playwright.config.ts
#   2.  Playwright detected from playwright.config.js
#   3.  Playwright detected from @playwright/test in package.json devDeps
#   4.  Cypress detected from cypress.config.ts
#   5.  Cypress detected from cypress.config.js
#   6.  Cypress detected from cypress/ directory
#   7.  Cypress detected from "cypress" in package.json devDeps
#   8.  Puppeteer detected from "puppeteer" in package.json devDeps
#   9.  Testing Library detected from @testing-library/react in devDeps
#  10.  Testing Library detected from @testing-library/vue in devDeps
#  11.  Testing Library detected from @testing-library/svelte in devDeps
#  12.  Detox detected from .detoxrc.js
#  13.  Detox detected from .detoxrc.json
#  14.  Detox detected from "detox" in package.json devDeps
#  15.  Selenium detected from requirements.txt
#  16.  Selenium detected from pom.xml
#  17.  Generic UI detected with tsx files + react dep (2 signals)
#  18.  Generic UI detected with templates dir + manage.py (Django signals)
#  19.  No detection on single signal only (< 2 signals)
#  20.  No detection on empty project
#  21.  Sets UI_PROJECT_DETECTED=true on detection
#  22.  Sets UI_FRAMEWORK to framework name (non-generic)
#  23.  Generic detection leaves UI_FRAMEWORK empty
#  24.  Explicit UI_FRAMEWORK is not overridden when non-auto
#  25.  Playwright takes priority over Testing Library when both present
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

# Source detection library
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# =============================================================================
# Helper: make a fresh project dir (non-git for predictable _find_source_files)
# =============================================================================
make_proj() {
    local name="$1"
    local dir="${TEST_TMPDIR}/${name}"
    mkdir -p "$dir"
    echo "$dir"
}

# Helper: reset UI globals before each test
reset_ui_globals() {
    UI_PROJECT_DETECTED=""
    UI_FRAMEWORK="auto"
    export UI_PROJECT_DETECTED UI_FRAMEWORK
}

# =============================================================================
# Test 1: Playwright config file — playwright.config.ts
# =============================================================================
echo "=== detect_ui_framework: Playwright config.ts ==="

PW_TS_DIR=$(make_proj "pw_ts")
touch "$PW_TS_DIR/playwright.config.ts"
reset_ui_globals

result=$(detect_ui_framework "$PW_TS_DIR")
if [[ "$result" == "playwright" ]]; then
    pass "playwright detected from playwright.config.ts"
else
    fail "playwright NOT detected from playwright.config.ts: got '$result'"
fi

# =============================================================================
# Test 2: Playwright config file — playwright.config.js
# =============================================================================
echo "=== detect_ui_framework: Playwright config.js ==="

PW_JS_DIR=$(make_proj "pw_js")
touch "$PW_JS_DIR/playwright.config.js"
reset_ui_globals

result=$(detect_ui_framework "$PW_JS_DIR")
if [[ "$result" == "playwright" ]]; then
    pass "playwright detected from playwright.config.js"
else
    fail "playwright NOT detected from playwright.config.js: got '$result'"
fi

# =============================================================================
# Test 3: Playwright via @playwright/test in package.json devDependencies
# =============================================================================
echo "=== detect_ui_framework: Playwright via package.json ==="

PW_PKG_DIR=$(make_proj "pw_pkg")
cat > "$PW_PKG_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "@playwright/test": "^1.40.0",
    "typescript": "^5.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$PW_PKG_DIR")
if [[ "$result" == "playwright" ]]; then
    pass "playwright detected from @playwright/test in devDependencies"
else
    fail "playwright NOT detected from @playwright/test: got '$result'"
fi

# =============================================================================
# Test 4: Cypress config file — cypress.config.ts
# =============================================================================
echo "=== detect_ui_framework: Cypress config.ts ==="

CY_TS_DIR=$(make_proj "cy_ts")
touch "$CY_TS_DIR/cypress.config.ts"
reset_ui_globals

result=$(detect_ui_framework "$CY_TS_DIR")
if [[ "$result" == "cypress" ]]; then
    pass "cypress detected from cypress.config.ts"
else
    fail "cypress NOT detected from cypress.config.ts: got '$result'"
fi

# =============================================================================
# Test 5: Cypress config file — cypress.config.js
# =============================================================================
echo "=== detect_ui_framework: Cypress config.js ==="

CY_JS_DIR=$(make_proj "cy_js")
touch "$CY_JS_DIR/cypress.config.js"
reset_ui_globals

result=$(detect_ui_framework "$CY_JS_DIR")
if [[ "$result" == "cypress" ]]; then
    pass "cypress detected from cypress.config.js"
else
    fail "cypress NOT detected from cypress.config.js: got '$result'"
fi

# =============================================================================
# Test 6: Cypress via cypress/ directory
# =============================================================================
echo "=== detect_ui_framework: Cypress directory ==="

CY_DIR_DIR=$(make_proj "cy_dir")
mkdir -p "$CY_DIR_DIR/cypress"
reset_ui_globals

result=$(detect_ui_framework "$CY_DIR_DIR")
if [[ "$result" == "cypress" ]]; then
    pass "cypress detected from cypress/ directory"
else
    fail "cypress NOT detected from cypress/ dir: got '$result'"
fi

# =============================================================================
# Test 7: Cypress via package.json devDependencies
# =============================================================================
echo "=== detect_ui_framework: Cypress via package.json ==="

CY_PKG_DIR=$(make_proj "cy_pkg")
cat > "$CY_PKG_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "cypress": "^13.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$CY_PKG_DIR")
if [[ "$result" == "cypress" ]]; then
    pass "cypress detected from cypress in devDependencies"
else
    fail "cypress NOT detected from package.json devDeps: got '$result'"
fi

# =============================================================================
# Test 8: Puppeteer via package.json
# =============================================================================
echo "=== detect_ui_framework: Puppeteer via package.json ==="

PUP_DIR=$(make_proj "pup_pkg")
cat > "$PUP_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "puppeteer": "^21.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$PUP_DIR")
if [[ "$result" == "puppeteer" ]]; then
    pass "puppeteer detected from puppeteer in devDependencies"
else
    fail "puppeteer NOT detected: got '$result'"
fi

# =============================================================================
# Test 9: Testing Library — @testing-library/react
# =============================================================================
echo "=== detect_ui_framework: Testing Library (react) ==="

TL_REACT_DIR=$(make_proj "tl_react")
cat > "$TL_REACT_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "@testing-library/react": "^14.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$TL_REACT_DIR")
if [[ "$result" == "testing-library" ]]; then
    pass "@testing-library/react detected as testing-library"
else
    fail "@testing-library/react NOT detected: got '$result'"
fi

# =============================================================================
# Test 10: Testing Library — @testing-library/vue
# =============================================================================
echo "=== detect_ui_framework: Testing Library (vue) ==="

TL_VUE_DIR=$(make_proj "tl_vue")
cat > "$TL_VUE_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "@testing-library/vue": "^7.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$TL_VUE_DIR")
if [[ "$result" == "testing-library" ]]; then
    pass "@testing-library/vue detected as testing-library"
else
    fail "@testing-library/vue NOT detected: got '$result'"
fi

# =============================================================================
# Test 11: Testing Library — @testing-library/svelte
# =============================================================================
echo "=== detect_ui_framework: Testing Library (svelte) ==="

TL_SVELTE_DIR=$(make_proj "tl_svelte")
cat > "$TL_SVELTE_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "@testing-library/svelte": "^4.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$TL_SVELTE_DIR")
if [[ "$result" == "testing-library" ]]; then
    pass "@testing-library/svelte detected as testing-library"
else
    fail "@testing-library/svelte NOT detected: got '$result'"
fi

# =============================================================================
# Test 12: Detox via .detoxrc.js
# =============================================================================
echo "=== detect_ui_framework: Detox .detoxrc.js ==="

DETOX_RC_DIR=$(make_proj "detox_rc_js")
touch "$DETOX_RC_DIR/.detoxrc.js"
reset_ui_globals

result=$(detect_ui_framework "$DETOX_RC_DIR")
if [[ "$result" == "detox" ]]; then
    pass "detox detected from .detoxrc.js"
else
    fail "detox NOT detected from .detoxrc.js: got '$result'"
fi

# =============================================================================
# Test 13: Detox via .detoxrc.json
# =============================================================================
echo "=== detect_ui_framework: Detox .detoxrc.json ==="

DETOX_JSON_DIR=$(make_proj "detox_rc_json")
touch "$DETOX_JSON_DIR/.detoxrc.json"
reset_ui_globals

result=$(detect_ui_framework "$DETOX_JSON_DIR")
if [[ "$result" == "detox" ]]; then
    pass "detox detected from .detoxrc.json"
else
    fail "detox NOT detected from .detoxrc.json: got '$result'"
fi

# =============================================================================
# Test 14: Detox via package.json devDependencies
# =============================================================================
echo "=== detect_ui_framework: Detox via package.json ==="

DETOX_PKG_DIR=$(make_proj "detox_pkg")
cat > "$DETOX_PKG_DIR/package.json" << 'EOF'
{
  "name": "my-app",
  "devDependencies": {
    "detox": "^20.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$DETOX_PKG_DIR")
if [[ "$result" == "detox" ]]; then
    pass "detox detected from detox in devDependencies"
else
    fail "detox NOT detected from package.json: got '$result'"
fi

# =============================================================================
# Test 15: Selenium via requirements.txt
# =============================================================================
echo "=== detect_ui_framework: Selenium via requirements.txt ==="

SEL_PY_DIR=$(make_proj "selenium_py")
printf 'selenium\nwebdriver_manager\n' > "$SEL_PY_DIR/requirements.txt"
reset_ui_globals

result=$(detect_ui_framework "$SEL_PY_DIR")
if [[ "$result" == "selenium" ]]; then
    pass "selenium detected from requirements.txt"
else
    fail "selenium NOT detected from requirements.txt: got '$result'"
fi

# =============================================================================
# Test 16: Selenium via pom.xml
# =============================================================================
echo "=== detect_ui_framework: Selenium via pom.xml ==="

SEL_JAVA_DIR=$(make_proj "selenium_java")
cat > "$SEL_JAVA_DIR/pom.xml" << 'EOF'
<project>
  <dependencies>
    <dependency>
      <groupId>org.seleniumhq.selenium</groupId>
      <artifactId>selenium-java</artifactId>
    </dependency>
  </dependencies>
</project>
EOF
reset_ui_globals

result=$(detect_ui_framework "$SEL_JAVA_DIR")
if [[ "$result" == "selenium" ]]; then
    pass "selenium detected from pom.xml"
else
    fail "selenium NOT detected from pom.xml: got '$result'"
fi

# =============================================================================
# Test 17: Generic UI — tsx files + react dep (2 signals)
# =============================================================================
echo "=== detect_ui_framework: Generic UI (tsx + react dep) ==="

GENERIC_DIR=$(make_proj "generic_react")
cat > "$GENERIC_DIR/package.json" << 'EOF'
{
  "name": "my-app",
  "dependencies": {
    "react": "^18.0.0",
    "react-dom": "^18.0.0"
  }
}
EOF
touch "$GENERIC_DIR/App.tsx" "$GENERIC_DIR/index.tsx"
reset_ui_globals

result=$(detect_ui_framework "$GENERIC_DIR")
if [[ "$result" == "generic" ]]; then
    pass "generic UI detected with tsx files + react dep (2 signals)"
else
    fail "generic UI NOT detected with tsx + react dep: got '$result'"
fi

# =============================================================================
# Test 18: Generic UI — Django project (templates + manage.py)
# =============================================================================
echo "=== detect_ui_framework: Generic UI (Django — templates + manage.py) ==="

DJANGO_DIR=$(make_proj "django_ui")
mkdir -p "$DJANGO_DIR/templates"
touch "$DJANGO_DIR/manage.py"
# Django templates + manage.py = 2 signals
reset_ui_globals

result=$(detect_ui_framework "$DJANGO_DIR")
if [[ "$result" == "generic" ]]; then
    pass "generic UI detected for Django project (templates + manage.py)"
else
    fail "generic UI NOT detected for Django project: got '$result'"
fi

# =============================================================================
# Test 19: No detection — single signal only
# =============================================================================
echo "=== detect_ui_framework: No detection on single signal ==="

SINGLE_SIGNAL_DIR=$(make_proj "single_signal")
# Only react dep, no component files or templates
cat > "$SINGLE_SIGNAL_DIR/package.json" << 'EOF'
{
  "name": "app",
  "dependencies": {
    "react": "^18.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$SINGLE_SIGNAL_DIR")
if [[ -z "$result" ]]; then
    pass "no detection on single signal (react dep only, no tsx/templates)"
else
    fail "incorrectly detected UI on single signal: got '$result'"
fi

# =============================================================================
# Test 20: No detection — empty project
# =============================================================================
echo "=== detect_ui_framework: No detection on empty project ==="

EMPTY_DIR=$(make_proj "empty_proj")
reset_ui_globals

result=$(detect_ui_framework "$EMPTY_DIR")
if [[ -z "$result" ]]; then
    pass "no detection on empty project"
else
    fail "incorrectly detected UI on empty project: got '$result'"
fi

# =============================================================================
# Test 21: Sets UI_PROJECT_DETECTED=true on detection
# =============================================================================
echo "=== detect_ui_framework: Sets UI_PROJECT_DETECTED=true ==="

DETECTED_DIR=$(make_proj "detected_dir")
touch "$DETECTED_DIR/playwright.config.ts"
UI_PROJECT_DETECTED=""
UI_FRAMEWORK="auto"
export UI_PROJECT_DETECTED UI_FRAMEWORK

detect_ui_framework "$DETECTED_DIR" > /dev/null
if [[ "${UI_PROJECT_DETECTED:-}" == "true" ]]; then
    pass "UI_PROJECT_DETECTED set to true on detection"
else
    fail "UI_PROJECT_DETECTED NOT set to true: got '${UI_PROJECT_DETECTED:-}'"
fi

# =============================================================================
# Test 22: Sets UI_FRAMEWORK to detected framework (non-generic)
# =============================================================================
echo "=== detect_ui_framework: Sets UI_FRAMEWORK for non-generic ==="

FW_DIR=$(make_proj "fw_dir")
touch "$FW_DIR/playwright.config.ts"
UI_PROJECT_DETECTED=""
UI_FRAMEWORK="auto"
export UI_PROJECT_DETECTED UI_FRAMEWORK

detect_ui_framework "$FW_DIR" > /dev/null
if [[ "${UI_FRAMEWORK:-}" == "playwright" ]]; then
    pass "UI_FRAMEWORK set to 'playwright' after detection"
else
    fail "UI_FRAMEWORK NOT set correctly: got '${UI_FRAMEWORK:-}'"
fi

# =============================================================================
# Test 23: Generic detection leaves UI_FRAMEWORK empty
# =============================================================================
echo "=== detect_ui_framework: Generic detection leaves UI_FRAMEWORK empty ==="

GEN_FW_DIR=$(make_proj "gen_fw")
cat > "$GEN_FW_DIR/package.json" << 'EOF'
{
  "name": "app",
  "dependencies": {
    "react": "^18.0.0"
  }
}
EOF
touch "$GEN_FW_DIR/App.tsx"
UI_PROJECT_DETECTED=""
UI_FRAMEWORK="auto"
export UI_PROJECT_DETECTED UI_FRAMEWORK

detect_ui_framework "$GEN_FW_DIR" > /dev/null
if [[ -z "${UI_FRAMEWORK:-}" ]]; then
    pass "generic detection leaves UI_FRAMEWORK empty"
else
    fail "generic detection set UI_FRAMEWORK to '${UI_FRAMEWORK:-}' (expected empty)"
fi

# =============================================================================
# Test 24: Explicit non-auto UI_FRAMEWORK is NOT overridden
# =============================================================================
echo "=== detect_ui_framework: Does not override explicit UI_FRAMEWORK ==="

NO_OVERRIDE_DIR=$(make_proj "no_override")
touch "$NO_OVERRIDE_DIR/cypress.config.ts"
UI_PROJECT_DETECTED=""
UI_FRAMEWORK="playwright"  # explicitly set, not "auto"
export UI_PROJECT_DETECTED UI_FRAMEWORK

detect_ui_framework "$NO_OVERRIDE_DIR" > /dev/null
if [[ "${UI_FRAMEWORK:-}" == "playwright" ]]; then
    pass "explicit UI_FRAMEWORK=playwright not overridden by cypress detection"
else
    fail "explicit UI_FRAMEWORK was overridden: got '${UI_FRAMEWORK:-}'"
fi

# =============================================================================
# Test 25: Playwright takes priority over Testing Library when both present
# =============================================================================
echo "=== detect_ui_framework: Playwright priority over Testing Library ==="

PRIORITY_DIR=$(make_proj "priority")
cat > "$PRIORITY_DIR/package.json" << 'EOF'
{
  "name": "app",
  "devDependencies": {
    "@playwright/test": "^1.40.0",
    "@testing-library/react": "^14.0.0"
  }
}
EOF
reset_ui_globals

result=$(detect_ui_framework "$PRIORITY_DIR")
if [[ "$result" == "playwright" ]]; then
    pass "playwright detected over testing-library when both present"
else
    fail "playwright priority failed — got '$result'"
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
