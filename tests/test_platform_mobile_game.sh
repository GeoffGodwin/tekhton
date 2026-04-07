#!/usr/bin/env bash
# =============================================================================
# test_platform_mobile_game.sh — Tests for Flutter & iOS platform adapters (M60)
#
# Tests syntax, prompt file presence, and detect.sh for Flutter and iOS.
# Android, game engine, resolution, and fragment tests are in
# test_platform_android_game.sh.
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
# Summary
# =============================================================================

echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
exit 0
