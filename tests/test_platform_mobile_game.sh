#!/usr/bin/env bash
# =============================================================================
# test_platform_mobile_game.sh — Tests for mobile & game platform adapters (M60)
#
# Tests detect.sh functions, framework identification, prompt file presence
# and structure for: Flutter, iOS, Android, and browser-based game engines.
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

# Source detect.sh for _extract_json_keys and _check_dep
# shellcheck source=../lib/detect.sh
source "${TEKHTON_HOME}/lib/detect.sh"

# Helper: reset globals and create fresh project dir
reset_ui_globals() {
    DESIGN_SYSTEM=""
    DESIGN_SYSTEM_CONFIG=""
    COMPONENT_LIBRARY_DIR=""
}

make_proj() {
    local name="$1"
    PROJECT_DIR="${TEST_TMPDIR}/proj_${name}"
    rm -rf "$PROJECT_DIR"
    mkdir -p "$PROJECT_DIR"
    reset_ui_globals
}

echo "=== test_platform_mobile_game.sh ==="

# =============================================================================
# Section 1: bash -n and shellcheck on all detect.sh files
# =============================================================================

echo ""
echo "--- Syntax checks ---"

for platform in mobile_flutter mobile_native_ios mobile_native_android game_web; do
    detect_file="${TEKHTON_HOME}/platforms/${platform}/detect.sh"
    if bash -n "$detect_file" 2>/dev/null; then
        pass "bash -n: ${platform}/detect.sh"
    else
        fail "bash -n: ${platform}/detect.sh"
    fi
    if command -v shellcheck >/dev/null 2>&1; then
        if shellcheck "$detect_file" 2>/dev/null; then
            pass "shellcheck: ${platform}/detect.sh"
        else
            fail "shellcheck: ${platform}/detect.sh"
        fi
    else
        pass "shellcheck: ${platform}/detect.sh (skipped — shellcheck not installed)"
    fi
done

# =============================================================================
# Section 2: Prompt file presence and content
# =============================================================================

echo ""
echo "--- Prompt file presence ---"

for platform in mobile_flutter mobile_native_ios mobile_native_android game_web; do
    for fragment in coder_guidance.prompt.md specialist_checklist.prompt.md tester_patterns.prompt.md; do
        fpath="${TEKHTON_HOME}/platforms/${platform}/${fragment}"
        if [[ -f "$fpath" ]] && [[ -s "$fpath" ]]; then
            pass "${platform}/${fragment} exists and non-empty"
        else
            fail "${platform}/${fragment} missing or empty"
        fi
    done
done

# =============================================================================
# Section 3: Flutter detect.sh
# =============================================================================

echo ""
echo "--- Flutter detection ---"

# Test: MaterialApp detection
make_proj "flutter_material"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART
# shellcheck source=/dev/null
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ "$DESIGN_SYSTEM" == "material" ]] && pass "Flutter: MaterialApp → material" || fail "Flutter: MaterialApp → material (got: $DESIGN_SYSTEM)"

# Test: CupertinoApp detection
make_proj "flutter_cupertino"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/cupertino.dart';
void main() => runApp(CupertinoApp(home: MyCupertinoApp()));
DART
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ "$DESIGN_SYSTEM" == "cupertino" ]] && pass "Flutter: CupertinoApp → cupertino" || fail "Flutter: CupertinoApp → cupertino (got: $DESIGN_SYSTEM)"

# Test: MaterialApp takes precedence over CupertinoApp
make_proj "flutter_both"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART
cat > "$PROJECT_DIR/lib/other.dart" <<'DART'
import 'package:flutter/cupertino.dart';
class Foo extends CupertinoApp {}
DART
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ "$DESIGN_SYSTEM" == "material" ]] && pass "Flutter: Both → material wins" || fail "Flutter: Both → material wins (got: $DESIGN_SYSTEM)"

# Test: Theme config detection
make_proj "flutter_theme_file"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
import 'package:flutter/material.dart';
void main() => runApp(MaterialApp(home: MyApp()));
DART
cat > "$PROJECT_DIR/lib/app_theme.dart" <<'DART'
import 'package:flutter/material.dart';
final theme = ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue));
DART
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ -n "$DESIGN_SYSTEM_CONFIG" ]] && pass "Flutter: theme config detected" || fail "Flutter: theme config not detected"

# Test: Widget directory detection
make_proj "flutter_widgets"
mkdir -p "$PROJECT_DIR/lib/widgets"
mkdir -p "$PROJECT_DIR/lib"
cat > "$PROJECT_DIR/lib/main.dart" <<'DART'
void main() {}
DART
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ "$COMPONENT_LIBRARY_DIR" == *"/lib/widgets" ]] && pass "Flutter: lib/widgets detected" || fail "Flutter: lib/widgets not detected (got: $COMPONENT_LIBRARY_DIR)"

# Test: No lib directory — graceful no-op
make_proj "flutter_empty"
source "${TEKHTON_HOME}/platforms/mobile_flutter/detect.sh"
[[ -z "$DESIGN_SYSTEM" ]] && pass "Flutter: empty project → no design system" || fail "Flutter: empty project detected something (got: $DESIGN_SYSTEM)"

# =============================================================================
# Section 4: iOS detect.sh
# =============================================================================

echo ""
echo "--- iOS detection ---"

# Test: SwiftUI detection
make_proj "ios_swiftui"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ContentView.swift" <<'SWIFT'
import SwiftUI
struct ContentView: View {
    var body: some View { Text("Hello") }
}
SWIFT
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"
[[ "$DESIGN_SYSTEM" == "swiftui" ]] && pass "iOS: SwiftUI detection" || fail "iOS: SwiftUI detection (got: $DESIGN_SYSTEM)"

# Test: UIKit detection
make_proj "ios_uikit"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/ViewController.swift" <<'SWIFT'
import UIKit
class ViewController: UIViewController {
    override func viewDidLoad() { super.viewDidLoad() }
}
SWIFT
cat > "$PROJECT_DIR/Sources/Other.swift" <<'SWIFT'
import UIKit
class OtherVC: UIViewController {}
SWIFT
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"
[[ "$DESIGN_SYSTEM" == "uikit" ]] && pass "iOS: UIKit detection" || fail "iOS: UIKit detection (got: $DESIGN_SYSTEM)"

# Test: Asset catalog detection
make_proj "ios_assets"
mkdir -p "$PROJECT_DIR/MyApp/Assets.xcassets/AccentColor.colorset"
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"
[[ "$DESIGN_SYSTEM_CONFIG" == *"Assets.xcassets" ]] && pass "iOS: xcassets detection" || fail "iOS: xcassets detection (got: $DESIGN_SYSTEM_CONFIG)"

# Test: Component directory detection
make_proj "ios_views"
mkdir -p "$PROJECT_DIR/Views"
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"
[[ "$COMPONENT_LIBRARY_DIR" == *"/Views" ]] && pass "iOS: Views dir detected" || fail "iOS: Views dir not detected (got: $COMPONENT_LIBRARY_DIR)"

# Test: Storyboard counts toward UIKit
make_proj "ios_storyboard"
mkdir -p "$PROJECT_DIR/Sources"
cat > "$PROJECT_DIR/Sources/App.swift" <<'SWIFT'
import SwiftUI
struct MyApp: App { var body: some Scene { WindowGroup { ContentView() } } }
SWIFT
touch "$PROJECT_DIR/Sources/Main.storyboard"
touch "$PROJECT_DIR/Sources/Launch.storyboard"
touch "$PROJECT_DIR/Sources/Settings.storyboard"
source "${TEKHTON_HOME}/platforms/mobile_native_ios/detect.sh"
# 1 SwiftUI file vs 3 storyboards → UIKit wins
[[ "$DESIGN_SYSTEM" == "uikit" ]] && pass "iOS: storyboards tip to UIKit" || fail "iOS: storyboards tip to UIKit (got: $DESIGN_SYSTEM)"

# =============================================================================
# Section 5: Android detect.sh
# =============================================================================

echo ""
echo "--- Android detection ---"

# Test: Compose detection
make_proj "android_compose"
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
source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"
[[ "$DESIGN_SYSTEM" == "material3" ]] && pass "Android: Compose + Material3" || fail "Android: Compose + Material3 (got: $DESIGN_SYSTEM)"

# Test: XML layouts detection
make_proj "android_xml"
mkdir -p "$PROJECT_DIR/app/src/main/res/layout"
cat > "$PROJECT_DIR/app/src/main/res/layout/activity_main.xml" <<'XML'
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android" />
XML
source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"
[[ "$DESIGN_SYSTEM" == "xml-layouts" ]] && pass "Android: XML layouts detection" || fail "Android: XML layouts detection (got: $DESIGN_SYSTEM)"

# Test: Theme.kt config detection
make_proj "android_theme"
mkdir -p "$PROJECT_DIR/app/ui/theme"
cat > "$PROJECT_DIR/app/ui/theme/Theme.kt" <<'KOTLIN'
@Composable
fun AppTheme(content: @Composable () -> Unit) {
    MaterialTheme(content = content)
}
KOTLIN
source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"
[[ "$DESIGN_SYSTEM_CONFIG" == *"Theme.kt" ]] && pass "Android: Theme.kt config detected" || fail "Android: Theme.kt config not detected (got: $DESIGN_SYSTEM_CONFIG)"

# Test: Material version from XML themes.xml
make_proj "android_material_xml"
mkdir -p "$PROJECT_DIR/app/src/main/res/layout"
mkdir -p "$PROJECT_DIR/app/src/main/res/values"
cat > "$PROJECT_DIR/app/src/main/res/layout/activity_main.xml" <<'XML'
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android" />
XML
cat > "$PROJECT_DIR/app/src/main/res/values/themes.xml" <<'XML'
<resources>
    <style name="AppTheme" parent="Theme.Material3.DayNight">
    </style>
</resources>
XML
source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"
[[ "$DESIGN_SYSTEM" == "material3" ]] && pass "Android: Material3 from themes.xml" || fail "Android: Material3 from themes.xml (got: $DESIGN_SYSTEM)"

# Test: Component directory detection
make_proj "android_components"
mkdir -p "$PROJECT_DIR/app/ui/screens"
source "${TEKHTON_HOME}/platforms/mobile_native_android/detect.sh"
[[ "$COMPONENT_LIBRARY_DIR" == *"/screens" ]] && pass "Android: screens dir detected" || fail "Android: screens dir not detected (got: $COMPONENT_LIBRARY_DIR)"

# =============================================================================
# Section 6: Game engine detect.sh
# =============================================================================

echo ""
echo "--- Game engine detection ---"

# Test: Phaser detection
make_proj "game_phaser"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "phaser": "^3.60.0"
  }
}
JSON
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM" == "phaser" ]] && pass "Game: Phaser detection" || fail "Game: Phaser detection (got: $DESIGN_SYSTEM)"

# Test: PixiJS detection
make_proj "game_pixi"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "pixi.js": "^7.0.0"
  }
}
JSON
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM" == "pixi" ]] && pass "Game: PixiJS detection" || fail "Game: PixiJS detection (got: $DESIGN_SYSTEM)"

# Test: PixiJS scoped packages
make_proj "game_pixi_scoped"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "@pixi/core": "^7.0.0",
    "@pixi/display": "^7.0.0"
  }
}
JSON
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM" == "pixi" ]] && pass "Game: @pixi/* scoped detection" || fail "Game: @pixi/* scoped detection (got: $DESIGN_SYSTEM)"

# Test: Three.js detection
make_proj "game_three"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "three": "^0.160.0"
  }
}
JSON
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM" == "three" ]] && pass "Game: Three.js detection" || fail "Game: Three.js detection (got: $DESIGN_SYSTEM)"

# Test: Babylon.js detection
make_proj "game_babylon"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "@babylonjs/core": "^6.0.0"
  }
}
JSON
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM" == "babylon" ]] && pass "Game: Babylon.js detection" || fail "Game: Babylon.js detection (got: $DESIGN_SYSTEM)"

# Test: Phaser game config detection
make_proj "game_phaser_config"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{
  "dependencies": {
    "phaser": "^3.60.0"
  }
}
JSON
mkdir -p "$PROJECT_DIR/src"
cat > "$PROJECT_DIR/src/main.ts" <<'TS'
const config = { type: Phaser.AUTO, width: 800, height: 600 };
const game = new Phaser.Game(config);
TS
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$DESIGN_SYSTEM_CONFIG" == *"main.ts" ]] && pass "Game: Phaser config file detected" || fail "Game: Phaser config file not detected (got: $DESIGN_SYSTEM_CONFIG)"

# Test: Scene directory detection
make_proj "game_scenes"
cat > "$PROJECT_DIR/package.json" <<'JSON'
{ "dependencies": { "phaser": "^3.60.0" } }
JSON
mkdir -p "$PROJECT_DIR/src/scenes"
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ "$COMPONENT_LIBRARY_DIR" == *"/src/scenes" ]] && pass "Game: scenes dir detected" || fail "Game: scenes dir not detected (got: $COMPONENT_LIBRARY_DIR)"

# Test: No package.json — graceful no-op
make_proj "game_empty"
source "${TEKHTON_HOME}/platforms/game_web/detect.sh"
[[ -z "$DESIGN_SYSTEM" ]] && pass "Game: empty project → no engine" || fail "Game: empty project detected something (got: $DESIGN_SYSTEM)"

# =============================================================================
# Section 7: Platform resolution (from _base.sh)
# =============================================================================

echo ""
echo "--- Platform resolution ---"

# Source _base.sh (needs TEKHTON_HOME and PROJECT_DIR)
make_proj "resolve_test"
# shellcheck source=../platforms/_base.sh
source "${TEKHTON_HOME}/platforms/_base.sh"

# Test: flutter framework → mobile_flutter
UI_FRAMEWORK="flutter"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_flutter" ]] && pass "Resolve: flutter → mobile_flutter" || fail "Resolve: flutter → mobile_flutter (got: $UI_PLATFORM)"

# Test: swiftui framework → mobile_native_ios
UI_FRAMEWORK="swiftui"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_native_ios" ]] && pass "Resolve: swiftui → mobile_native_ios" || fail "Resolve: swiftui → mobile_native_ios (got: $UI_PLATFORM)"

# Test: jetpack-compose → mobile_native_android
UI_FRAMEWORK="jetpack-compose"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "mobile_native_android" ]] && pass "Resolve: jetpack-compose → mobile_native_android" || fail "Resolve: jetpack-compose → mobile_native_android (got: $UI_PLATFORM)"

# Test: phaser → game_web
UI_FRAMEWORK="phaser"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "Resolve: phaser → game_web" || fail "Resolve: phaser → game_web (got: $UI_PLATFORM)"

# Test: pixi → game_web
UI_FRAMEWORK="pixi"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "Resolve: pixi → game_web" || fail "Resolve: pixi → game_web (got: $UI_PLATFORM)"

# Test: three → game_web
UI_FRAMEWORK="three"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "Resolve: three → game_web" || fail "Resolve: three → game_web (got: $UI_PLATFORM)"

# Test: babylon → game_web
UI_FRAMEWORK="babylon"
UI_PROJECT_DETECTED="true"
UI_PLATFORM="auto"
detect_ui_platform
[[ "$UI_PLATFORM" == "game_web" ]] && pass "Resolve: babylon → game_web" || fail "Resolve: babylon → game_web (got: $UI_PLATFORM)"

# =============================================================================
# Section 8: Fragment loading integration
# =============================================================================

echo ""
echo "--- Fragment loading ---"

# Test: Flutter fragments load via load_platform_fragments
make_proj "frag_flutter"
UI_PLATFORM="mobile_flutter"
UI_PLATFORM_DIR="${TEKHTON_HOME}/platforms/mobile_flutter"
load_platform_fragments
[[ -n "$UI_CODER_GUIDANCE" ]] && pass "Flutter: coder guidance loaded" || fail "Flutter: coder guidance not loaded"
[[ -n "$UI_SPECIALIST_CHECKLIST" ]] && pass "Flutter: specialist checklist loaded" || fail "Flutter: specialist checklist not loaded"
[[ -n "$UI_TESTER_PATTERNS" ]] && pass "Flutter: tester patterns loaded" || fail "Flutter: tester patterns not loaded"

# Test: Game fragments load via load_platform_fragments
make_proj "frag_game"
UI_PLATFORM="game_web"
UI_PLATFORM_DIR="${TEKHTON_HOME}/platforms/game_web"
load_platform_fragments
[[ "$UI_CODER_GUIDANCE" == *"Game Loop"* ]] && pass "Game: coder guidance has game content" || fail "Game: coder guidance missing game content"
[[ "$UI_SPECIALIST_CHECKLIST" == *"Frame budget"* ]] && pass "Game: specialist checklist has game content" || fail "Game: specialist checklist missing game content"
[[ "$UI_TESTER_PATTERNS" == *"Headless"* ]] && pass "Game: tester patterns has game content" || fail "Game: tester patterns missing game content"

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
