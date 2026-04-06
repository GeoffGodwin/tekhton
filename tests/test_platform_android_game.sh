#!/usr/bin/env bash
# =============================================================================
# test_platform_android_game.sh — Tests for Android & game platform adapters (M60)
#
# Split from test_platform_mobile_game.sh to stay under the 300-line ceiling.
# Tests: Android detect.sh, game engine detect.sh, platform resolution, and
# fragment loading integration.
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

echo "=== test_platform_android_game.sh ==="

# =============================================================================
# Section 1: Android detect.sh
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
# Section 2: Game engine detect.sh
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
# Section 3: Platform resolution (from _base.sh)
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
# Section 4: Fragment loading integration
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
