#!/usr/bin/env bash
# =============================================================================
# test_platform_m60_edge_cases.sh — Edge case tests for M60 platform adapters
#
# Split from test_platform_m60_integration.sh to stay under the 300-line ceiling.
# Tests: iOS SwiftUI/UIKit tie-breaking and user override detect.sh.
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

echo "=== test_platform_m60_edge_cases.sh ==="

# =============================================================================
# Section 1: iOS SwiftUI/UIKit tie-breaking edge case
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
# Section 2: source_platform_detect() with user override (PROJECT_DIR override)
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
