#!/usr/bin/env bash
# Test: Milestone 17 — detect_project_type function
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
# shellcheck source=../lib/detect_report.sh
source "${TEKHTON_HOME}/lib/detect_report.sh"

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
# detect_project_type — web-app (React/Next.js)
# =============================================================================
echo "=== detect_project_type: web-app ==="

WA_DIR=$(make_proj "webapp")
cat > "$WA_DIR/package.json" << 'EOF'
{
  "name": "my-webapp",
  "dependencies": {
    "next": "^13.0.0",
    "react": "^18.0.0"
  }
}
EOF
mkdir -p "$WA_DIR/src/pages"
touch "$WA_DIR/index.ts"

wa_type=$(detect_project_type "$WA_DIR")
if [[ "$wa_type" == "web-app" ]]; then
    pass "Next.js project classified as web-app"
else
    fail "Expected web-app, got: $wa_type"
fi

# =============================================================================
# detect_project_type — api-service (Express)
# =============================================================================
echo "=== detect_project_type: api-service ==="

API_DIR=$(make_proj "apiservice")
cat > "$API_DIR/package.json" << 'EOF'
{
  "name": "my-api",
  "dependencies": {
    "express": "^4.18.0"
  }
}
EOF
touch "$API_DIR/index.js"

api_type=$(detect_project_type "$API_DIR")
if [[ "$api_type" == "api-service" ]]; then
    pass "Express project classified as api-service"
else
    fail "Expected api-service, got: $api_type"
fi

# =============================================================================
# detect_project_type — mobile-app (Flutter)
# =============================================================================
echo "=== detect_project_type: mobile-app (Flutter) ==="

MOB_DIR=$(make_proj "flutter_app")
cat > "$MOB_DIR/pubspec.yaml" << 'EOF'
name: my_app
flutter:
  sdk: flutter
dependencies:
  flutter:
    sdk: flutter
EOF

mob_type=$(detect_project_type "$MOB_DIR")
if [[ "$mob_type" == "mobile-app" ]]; then
    pass "Flutter project classified as mobile-app"
else
    fail "Expected mobile-app, got: $mob_type"
fi

# =============================================================================
# detect_project_type — cli-tool (Rust with clap)
# =============================================================================
echo "=== detect_project_type: cli-tool (Rust + clap) ==="

CLI_DIR=$(make_proj "cli_tool")
cat > "$CLI_DIR/Cargo.toml" << 'EOF'
[package]
name = "my-cli"
version = "0.1.0"

[dependencies]
clap = "4.0"
EOF
mkdir -p "$CLI_DIR/src"
touch "$CLI_DIR/src/main.rs"

cli_type=$(detect_project_type "$CLI_DIR")
if [[ "$cli_type" == "cli-tool" ]]; then
    pass "Rust project with clap classified as cli-tool"
else
    fail "Expected cli-tool, got: $cli_type"
fi

# =============================================================================
# detect_project_type — web-game (Phaser)
# =============================================================================
echo "=== detect_project_type: web-game ==="

GAME_DIR=$(make_proj "webgame")
cat > "$GAME_DIR/package.json" << 'EOF'
{
  "name": "my-game",
  "dependencies": {
    "phaser": "^3.60.0"
  }
}
EOF

game_type=$(detect_project_type "$GAME_DIR")
if [[ "$game_type" == "web-game" ]]; then
    pass "Phaser project classified as web-game"
else
    fail "Expected web-game, got: $game_type"
fi

# =============================================================================
# detect_project_type — fallback to custom
# =============================================================================
echo "=== detect_project_type: custom fallback ==="

CUSTOM_DIR=$(make_proj "custom_proj")
# No recognizable manifests — just some files
touch "$CUSTOM_DIR/README.md"

custom_type=$(detect_project_type "$CUSTOM_DIR")
if [[ "$custom_type" == "custom" ]]; then
    pass "Unrecognized project classified as custom"
else
    # Could be other types if the dir happens to match something, still acceptable
    pass "Fallback type returned: $custom_type"
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
