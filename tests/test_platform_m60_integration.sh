#!/usr/bin/env bash
# =============================================================================
# test_platform_m60_integration.sh — Integration tests for M60 platform adapters
#
# Tests source_platform_detect() end-to-end for all four M60 platforms.
# Edge cases (iOS tie-breaking, user overrides) are in
# test_platform_m60_edge_cases.sh.
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TEKHTON_HOME

PASS=0
FAIL=0

pass() { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# Stub logging functions required by _base.sh and detect.sh
log()     { :; }
warn()    { :; }
error()   { :; }
success() { :; }
header()  { :; }

# Source lib/detect.sh first — game_web/detect.sh depends on _extract_json_keys
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# Source _base.sh once — provides detect_ui_platform, source_platform_detect,
# load_platform_fragments
# shellcheck source=../platforms/_base.sh
source "${TEKHTON_HOME}/platforms/_base.sh"

# Helper: create a fresh project directory and reset all UI globals
make_proj() {
    local name="$1"
    PROJECT_DIR="${TEST_TMPDIR}/proj_${name}"
    export PROJECT_DIR
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    DESIGN_SYSTEM=""
    DESIGN_SYSTEM_CONFIG=""
    COMPONENT_LIBRARY_DIR=""
    UI_PLATFORM="auto"
    UI_PLATFORM_DIR=""
    UI_FRAMEWORK=""
    UI_PROJECT_DETECTED="true"
    export DESIGN_SYSTEM DESIGN_SYSTEM_CONFIG COMPONENT_LIBRARY_DIR
    export UI_PLATFORM UI_PLATFORM_DIR UI_FRAMEWORK UI_PROJECT_DETECTED
}

echo "=== test_platform_m60_integration.sh ==="

# =============================================================================
# Section 1: source_platform_detect() end-to-end — Flutter
# =============================================================================

echo ""
echo "--- source_platform_detect() end-to-end: Flutter ---"

make_proj "e2e_flutter"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART

UI_FRAMEWORK="flutter"
detect_ui_platform
source_platform_detect

[[ "$UI_PLATFORM" == "mobile_flutter" ]] \
    && pass "e2e Flutter: UI_PLATFORM resolved to mobile_flutter" \
    || fail "e2e Flutter: UI_PLATFORM resolved to mobile_flutter (got: ${UI_PLATFORM})"

[[ "$DESIGN_SYSTEM" == "material" ]] \
    && pass "e2e Flutter: DESIGN_SYSTEM=material via source_platform_detect" \
    || fail "e2e Flutter: DESIGN_SYSTEM=material via source_platform_detect (got: ${DESIGN_SYSTEM})"

# =============================================================================
# Section 2: source_platform_detect() end-to-end — iOS SwiftUI
# =============================================================================

echo ""
echo "--- source_platform_detect() end-to-end: iOS ---"

make_proj "e2e_ios"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ContentView.swift" <<'SWIFT'
import SwiftUI
struct ContentView: View {
    var body: some View { Text("Hello") }
}
SWIFT

UI_FRAMEWORK="swiftui"
detect_ui_platform
source_platform_detect

[[ "$UI_PLATFORM" == "mobile_native_ios" ]] \
    && pass "e2e iOS: UI_PLATFORM resolved to mobile_native_ios" \
    || fail "e2e iOS: UI_PLATFORM resolved to mobile_native_ios (got: ${UI_PLATFORM})"

[[ "$DESIGN_SYSTEM" == "swiftui" ]] \
    && pass "e2e iOS: DESIGN_SYSTEM=swiftui via source_platform_detect" \
    || fail "e2e iOS: DESIGN_SYSTEM=swiftui via source_platform_detect (got: ${DESIGN_SYSTEM})"

# =============================================================================
# Section 3: source_platform_detect() end-to-end — Android
# =============================================================================

echo ""
echo "--- source_platform_detect() end-to-end: Android ---"

make_proj "e2e_android"
mkdir -p "$PROJECT_DIR/app/src/main/java/com/example/ui"
cat > "$PROJECT_DIR/app/src/main/java/com/example/ui/HomeScreen.kt" <<'KOTLIN'
import androidx.compose.runtime.Composable
@Composable
fun HomeScreen() { Text("Hello") }
KOTLIN
mkdir -p "$PROJECT_DIR/app"
cat > "$PROJECT_DIR/app/build.gradle.kts" <<'GRADLE'
dependencies {
    implementation("androidx.compose.material3:material3:1.2.0")
}
GRADLE

UI_FRAMEWORK="jetpack-compose"
detect_ui_platform
source_platform_detect

[[ "$UI_PLATFORM" == "mobile_native_android" ]] \
    && pass "e2e Android: UI_PLATFORM resolved to mobile_native_android" \
    || fail "e2e Android: UI_PLATFORM resolved to mobile_native_android (got: ${UI_PLATFORM})"

[[ "$DESIGN_SYSTEM" == "material3" ]] \
    && pass "e2e Android: DESIGN_SYSTEM=material3 via source_platform_detect" \
    || fail "e2e Android: DESIGN_SYSTEM=material3 via source_platform_detect (got: ${DESIGN_SYSTEM})"

# =============================================================================
# Section 4: source_platform_detect() end-to-end — Web Game (Phaser)
# =============================================================================

echo ""
echo "--- source_platform_detect() end-to-end: Web Game ---"

make_proj "e2e_game"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "phaser": "^3.60.0"
  }
}
JSON

UI_FRAMEWORK="phaser"
detect_ui_platform
source_platform_detect

[[ "$UI_PLATFORM" == "game_web" ]] \
    && pass "e2e Game: UI_PLATFORM resolved to game_web" \
    || fail "e2e Game: UI_PLATFORM resolved to game_web (got: ${UI_PLATFORM})"

[[ "$DESIGN_SYSTEM" == "phaser" ]] \
    && pass "e2e Game: DESIGN_SYSTEM=phaser via source_platform_detect" \
    || fail "e2e Game: DESIGN_SYSTEM=phaser via source_platform_detect (got: ${DESIGN_SYSTEM})"

# =============================================================================
# Section 5: source_platform_detect() end-to-end — DESIGN_SYSTEM exported
# after detect and injected into load_platform_fragments
# =============================================================================

echo ""
echo "--- source_platform_detect() → load_platform_fragments() handoff ---"

make_proj "e2e_handoff"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART
cat > "$PROJECT_DIR/lib/app_theme.dart" <<'DART'
import 'package:flutter/material.dart';
final theme = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
DART
mkdir -p "$PROJECT_DIR/lib/widgets"

UI_FRAMEWORK="flutter"
detect_ui_platform
source_platform_detect
load_platform_fragments

# Coder guidance must mention the detected design system
[[ "$UI_CODER_GUIDANCE" == *"material"* ]] \
    && pass "e2e Handoff: coder guidance contains design system name" \
    || fail "e2e Handoff: coder guidance missing design system name"

# Coder guidance must contain the detected config path
[[ -n "$DESIGN_SYSTEM_CONFIG" ]] && [[ "$UI_CODER_GUIDANCE" == *"$DESIGN_SYSTEM_CONFIG"* ]] \
    && pass "e2e Handoff: coder guidance contains DESIGN_SYSTEM_CONFIG path" \
    || fail "e2e Handoff: coder guidance missing DESIGN_SYSTEM_CONFIG path (config: ${DESIGN_SYSTEM_CONFIG})"

# Coder guidance must reference detected component library dir
[[ -n "$COMPONENT_LIBRARY_DIR" ]] && [[ "$UI_CODER_GUIDANCE" == *"$COMPONENT_LIBRARY_DIR"* ]] \
    && pass "e2e Handoff: coder guidance references COMPONENT_LIBRARY_DIR" \
    || fail "e2e Handoff: coder guidance missing COMPONENT_LIBRARY_DIR (dir: ${COMPONENT_LIBRARY_DIR})"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
