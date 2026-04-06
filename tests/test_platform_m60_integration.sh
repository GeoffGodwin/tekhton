#!/usr/bin/env bash
# =============================================================================
# test_platform_m60_integration.sh — Integration tests for M60 platform adapters
#
# Tests the combined flow through source_platform_detect() for all four
# M60 platforms, and edge cases not covered in test_platform_mobile_game.sh:
#   1. source_platform_detect() end-to-end (detect_ui_platform → source detect.sh)
#   2. iOS SwiftUI/UIKit tie-breaking (swiftui_count == uikit_count → SwiftUI wins)
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
# Section 6: iOS SwiftUI/UIKit tie-breaking edge case
#   Condition: swiftui_count -ge uikit_count → SwiftUI wins on tie
# =============================================================================

echo ""
echo "--- iOS SwiftUI/UIKit tie-breaking ---"

# Test: Exact tie (1 SwiftUI file, 1 UIKit file) → SwiftUI wins
make_proj "ios_tie"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ContentView.swift" <<'SWIFT'
import SwiftUI
struct ContentView: View {
    var body: some View { Text("Hello") }
}
SWIFT
cat > "$PROJECT_DIR/Sources/LegacyController.swift" <<'SWIFT'
import UIKit
class LegacyController: UIViewController {
    override func viewDidLoad() { super.viewDidLoad() }
}
SWIFT

# Source detect.sh directly (mirrors how source_platform_detect works)
DESIGN_SYSTEM=""
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"

[[ "$DESIGN_SYSTEM" == "swiftui" ]] \
    && pass "iOS tie: equal counts → SwiftUI wins (swiftui_count -ge uikit_count)" \
    || fail "iOS tie: equal counts → SwiftUI wins (got: ${DESIGN_SYSTEM})"

# Test: 2 SwiftUI files, 2 UIKit files → still SwiftUI wins
make_proj "ios_tie_2"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ViewA.swift" <<'SWIFT'
import SwiftUI
struct ViewA: View { var body: some View { Text("A") } }
SWIFT
cat > "$PROJECT_DIR/Sources/ViewB.swift" <<'SWIFT'
import SwiftUI
struct ViewB: View { var body: some View { Text("B") } }
SWIFT
cat > "$PROJECT_DIR/Sources/CtrlA.swift" <<'SWIFT'
import UIKit
class CtrlA: UIViewController {}
SWIFT
cat > "$PROJECT_DIR/Sources/CtrlB.swift" <<'SWIFT'
import UIKit
class CtrlB: UIViewController {}
SWIFT

DESIGN_SYSTEM=""
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"

[[ "$DESIGN_SYSTEM" == "swiftui" ]] \
    && pass "iOS tie 2-vs-2: equal counts → SwiftUI wins" \
    || fail "iOS tie 2-vs-2: equal counts → SwiftUI wins (got: ${DESIGN_SYSTEM})"

# Test: UIKit majority (1 SwiftUI, 2 UIKit files) → UIKit wins
make_proj "ios_uikit_majority"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/OneView.swift" <<'SWIFT'
import SwiftUI
struct OneView: View { var body: some View { Text("One") } }
SWIFT
cat > "$PROJECT_DIR/Sources/CtrlA.swift" <<'SWIFT'
import UIKit
class CtrlA: UIViewController {}
SWIFT
cat > "$PROJECT_DIR/Sources/CtrlB.swift" <<'SWIFT'
import UIKit
class CtrlB: UIViewController {}
SWIFT

DESIGN_SYSTEM=""
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"

[[ "$DESIGN_SYSTEM" == "uikit" ]] \
    && pass "iOS UIKit majority (1 vs 2) → UIKit wins" \
    || fail "iOS UIKit majority (1 vs 2) → UIKit wins (got: ${DESIGN_SYSTEM})"

# Test: SwiftUI majority (2 SwiftUI, 1 UIKit) → SwiftUI wins
make_proj "ios_swiftui_majority"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ViewA.swift" <<'SWIFT'
import SwiftUI
struct ViewA: View { var body: some View { Text("A") } }
SWIFT
cat > "$PROJECT_DIR/Sources/ViewB.swift" <<'SWIFT'
import SwiftUI
struct ViewB: View { var body: some View { Text("B") } }
SWIFT
cat > "$PROJECT_DIR/Sources/Ctrl.swift" <<'SWIFT'
import UIKit
class Ctrl: UIViewController {}
SWIFT

DESIGN_SYSTEM=""
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"

[[ "$DESIGN_SYSTEM" == "swiftui" ]] \
    && pass "iOS SwiftUI majority (2 vs 1) → SwiftUI wins" \
    || fail "iOS SwiftUI majority (2 vs 1) → SwiftUI wins (got: ${DESIGN_SYSTEM})"

# Test: No iOS files at all → no design system set
make_proj "ios_empty"
DESIGN_SYSTEM=""
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"

[[ -z "$DESIGN_SYSTEM" ]] \
    && pass "iOS empty project → DESIGN_SYSTEM unset" \
    || fail "iOS empty project → DESIGN_SYSTEM unset (got: ${DESIGN_SYSTEM})"

# =============================================================================
# Section 7: source_platform_detect() with user override (PROJECT_DIR override)
# =============================================================================

echo ""
echo "--- source_platform_detect() user override ---"

make_proj "e2e_override"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART

# Create a user override detect.sh that sets a custom value
mkdir -p "$PROJECT_DIR/.claude/platforms/mobile_flutter"
cat > "$PROJECT_DIR/.claude/platforms/mobile_flutter/detect.sh" <<'BASH'
# User override: stamp a custom marker
COMPONENT_LIBRARY_DIR="/custom/override/path"
BASH

UI_FRAMEWORK="flutter"
detect_ui_platform
source_platform_detect

# Built-in detect.sh runs first → DESIGN_SYSTEM set
[[ "$DESIGN_SYSTEM" == "material" ]] \
    && pass "Override: built-in detect still ran (DESIGN_SYSTEM=material)" \
    || fail "Override: built-in detect still ran (got: ${DESIGN_SYSTEM})"

# User override runs after → COMPONENT_LIBRARY_DIR overwritten
[[ "$COMPONENT_LIBRARY_DIR" == "/custom/override/path" ]] \
    && pass "Override: user override detect applied (COMPONENT_LIBRARY_DIR=/custom/override/path)" \
    || fail "Override: user override detect applied (got: ${COMPONENT_LIBRARY_DIR})"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
