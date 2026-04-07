#!/usr/bin/env bash
# =============================================================================
# test_m66_watchtower_ui.sh
#
# Tests for M66 Watchtower UI features:
#   1. cycle-badge and cycle-red CSS classes exist in style.css
#   2. cycle-badge rendered when review cycles > 1; cycle-red when >= 3
#   3. expand/collapse state persists via tk_expanded_stages localStorage key
#   4. test_audit sub-step declared in tester group
#   5. Expanded sub-step rows rendered with correct HTML attributes
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() {
    echo "  PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  FAIL: $1"
    FAIL=$((FAIL + 1))
}

APP_JS="${TEKHTON_HOME}/templates/watchtower/app.js"
STYLE_CSS="${TEKHTON_HOME}/templates/watchtower/style.css"

# =============================================================================
# Test 1: cycle-badge CSS class exists in style.css
# =============================================================================
echo "=== Test 1: cycle-badge CSS class in style.css ==="

if grep -q "\.cycle-badge" "$STYLE_CSS"; then
    pass ".cycle-badge class defined in style.css"
else
    fail ".cycle-badge class not found in style.css"
fi

# =============================================================================
# Test 2: cycle-red CSS class exists in style.css
# =============================================================================
echo "=== Test 2: cycle-red CSS class in style.css ==="

if grep -q "cycle-red" "$STYLE_CSS"; then
    pass ".cycle-badge.cycle-red class defined in style.css"
else
    fail "cycle-red modifier class not found in style.css"
fi

# Verify cycle-red changes background color (implies it's a visual indicator)
if grep "cycle-red" "$STYLE_CSS" | grep -q "background"; then
    pass "cycle-red sets a background color"
else
    fail "cycle-red does not define a background color"
fi

# =============================================================================
# Test 3: cycle-badge rendered in app.js when reviewer cycles > 1
# =============================================================================
echo "=== Test 3: cycle-badge rendered when reviewer cycles > 1 ==="

if grep -q "sn === 'reviewer' && lsd && lsd.cycles > 1" "$APP_JS"; then
    pass "cycle-badge conditional: reviewer cycles > 1"
else
    fail "cycle-badge not conditioned on reviewer cycles > 1"
fi

if grep "cycle-badge" "$APP_JS" | grep -q "\\\\u00d7"; then
    pass "cycle-badge uses ×(\\u00d7) multiplication symbol"
else
    fail "cycle-badge does not use \\u00d7 symbol"
fi

# =============================================================================
# Test 4: cycle-red applied when reviewer cycles >= 3
# =============================================================================
echo "=== Test 4: cycle-red applied when reviewer cycles >= 3 ==="

if grep -q "cc >= 3 ? ' cycle-red'" "$APP_JS"; then
    pass "cycle-red CSS class applied when cc >= 3"
else
    fail "cycle-red not applied on cc >= 3 threshold"
fi

# Verify cc is assigned from lsd.cycles (not some other field)
if grep "var cc = lsd.cycles" "$APP_JS" | grep -q "var cc"; then
    pass "cc variable sourced from lsd.cycles"
else
    fail "cc variable not sourced from lsd.cycles"
fi

# =============================================================================
# Test 5: security rework_cycles also shown with cycle-badge
# =============================================================================
echo "=== Test 5: security rework_cycles shown as cycle-badge ==="

if grep -q "sn === 'security' && lsd && lsd.rework_cycles > 0" "$APP_JS"; then
    pass "cycle-badge conditional: security rework_cycles > 0"
else
    fail "cycle-badge not conditioned on security rework_cycles > 0"
fi

if grep "sn === 'security'" -A 2 "$APP_JS" | grep -q "rework_cycles + 1"; then
    pass "security badge count = rework_cycles + 1"
else
    fail "security badge count does not add 1 to rework_cycles"
fi

# =============================================================================
# Test 6: getExpandedStages() reads from tk_expanded_stages localStorage key
# =============================================================================
echo "=== Test 6: getExpandedStages() reads tk_expanded_stages ==="

if grep -q "function getExpandedStages()" "$APP_JS"; then
    pass "getExpandedStages() function is defined"
else
    fail "getExpandedStages() function not found"
fi

if grep "function getExpandedStages()" -A 1 "$APP_JS" | \
   grep -q "'tk_expanded_stages'"; then
    pass "getExpandedStages() reads from 'tk_expanded_stages' key"
else
    fail "getExpandedStages() does not read 'tk_expanded_stages'"
fi

if grep "function getExpandedStages()" -A 1 "$APP_JS" | \
   grep -q "JSON.parse"; then
    pass "getExpandedStages() parses JSON from localStorage"
else
    fail "getExpandedStages() does not JSON.parse localStorage value"
fi

# =============================================================================
# Test 7: setExpandedStages() writes to tk_expanded_stages localStorage key
# =============================================================================
echo "=== Test 7: setExpandedStages() writes tk_expanded_stages ==="

if grep -q "function setExpandedStages(" "$APP_JS"; then
    pass "setExpandedStages() function is defined"
else
    fail "setExpandedStages() function not found"
fi

if grep "function setExpandedStages(" -A 1 "$APP_JS" | \
   grep -q "'tk_expanded_stages'"; then
    pass "setExpandedStages() writes to 'tk_expanded_stages' key"
else
    fail "setExpandedStages() does not write to 'tk_expanded_stages'"
fi

if grep "function setExpandedStages(" -A 1 "$APP_JS" | \
   grep -q "JSON.stringify"; then
    pass "setExpandedStages() serializes with JSON.stringify"
else
    fail "setExpandedStages() does not use JSON.stringify"
fi

# =============================================================================
# Test 8: _toggleStageGroup() calls both getExpandedStages and setExpandedStages
# =============================================================================
echo "=== Test 8: _toggleStageGroup() persists expand state ==="

if grep -q "function _toggleStageGroup(" "$APP_JS"; then
    pass "_toggleStageGroup() function is defined"
else
    fail "_toggleStageGroup() function not found"
fi

if grep "getExpandedStages()" "$APP_JS" | grep -qv "function getExpandedStages"; then
    pass "_toggleStageGroup() calls getExpandedStages()"
else
    fail "_toggleStageGroup() does not call getExpandedStages()"
fi

if grep "setExpandedStages(" "$APP_JS" | grep -qv "function setExpandedStages"; then
    pass "_toggleStageGroup() calls setExpandedStages()"
else
    fail "_toggleStageGroup() does not call setExpandedStages()"
fi

# Verify toggle flips the boolean stored in the map
if grep "_toggleStageGroup" -A 5 "$APP_JS" | grep -q "!exp\[gn\]"; then
    pass "_toggleStageGroup() negates prior expanded value"
else
    fail "_toggleStageGroup() does not toggle via !exp[gn]"
fi

# =============================================================================
# Test 9: tester group declares test_audit as a child
# =============================================================================
echo "=== Test 9: test_audit declared as tester child ==="

if grep "tester:" "$APP_JS" | grep -q "test_audit"; then
    pass "tester group declares test_audit as a child"
else
    fail "tester group does not include test_audit as a child"
fi

# =============================================================================
# Test 10: test_audit has a label in stageLabels
# =============================================================================
echo "=== Test 10: test_audit has a display label ==="

if grep "stageLabels" "$APP_JS" | grep -q "test_audit"; then
    pass "test_audit has an entry in stageLabels"
else
    fail "test_audit not found in stageLabels"
fi

if grep "stageLabels" "$APP_JS" | grep "test_audit" | grep -q "'Test Audit'"; then
    pass "test_audit label is 'Test Audit'"
else
    fail "test_audit label is not 'Test Audit'"
fi

# =============================================================================
# Test 11: _renderStageRow applies substep-row class to child rows
# =============================================================================
echo "=== Test 11: _renderStageRow applies substep-row class for children ==="

# substep-row is on the line after "if (isChild)" — check both exist and are adjacent
if grep -A 1 "if (isChild)" "$APP_JS" | grep -q "substep-row"; then
    pass "_renderStageRow uses 'substep-row' class for child rows (inside isChild block)"
else
    fail "_renderStageRow does not assign 'substep-row' class inside isChild block"
fi

# Verify hidden class applied when parentExpanded is false
if grep "substep-row" "$APP_JS" | grep -q "hidden"; then
    pass "substep-row includes 'hidden' class when not expanded"
else
    fail "substep-row does not include 'hidden' class for collapsed state"
fi

# =============================================================================
# Test 12: child rows carry data-parent attribute for toggle targeting
# =============================================================================
echo "=== Test 12: child rows carry data-parent attribute ==="

if grep "data-parent" "$APP_JS" | grep -q "esc(parentKey"; then
    pass "child rows render data-parent attribute with escaped parentKey"
else
    fail "child rows do not render data-parent attribute"
fi

# =============================================================================
# Test 13: child bar uses bar-fill-sub CSS class
# =============================================================================
echo "=== Test 13: child bar uses bar-fill-sub class ==="

if grep "bar-fill-sub" "$APP_JS" | grep -q "isChild"; then
    pass "bar-fill-sub class applied conditionally on isChild"
else
    fail "bar-fill-sub not conditioned on isChild"
fi

if grep -q "\.bar-fill-sub" "$STYLE_CSS"; then
    pass ".bar-fill-sub class defined in style.css"
else
    fail ".bar-fill-sub class not found in style.css"
fi

# =============================================================================
# Test 14: substep-label CSS class applied to child label cell
# =============================================================================
echo "=== Test 14: substep-label CSS class applied to child label cell ==="

if grep "substep-label" "$APP_JS" | grep -q "isChild"; then
    pass "substep-label tdClass applied when isChild is true"
else
    fail "substep-label not applied based on isChild"
fi

if grep -q "\.substep-label" "$STYLE_CSS"; then
    pass ".substep-label class defined in style.css"
else
    fail ".substep-label class not found in style.css"
fi

# =============================================================================
# Test 15: expandable-row parent has aria-expanded attribute
# =============================================================================
echo "=== Test 15: expandable parent row has aria-expanded attribute ==="

if grep "expandable-row" "$APP_JS" | grep -q "aria-expanded"; then
    pass "expandable-row includes aria-expanded attribute"
else
    fail "expandable-row missing aria-expanded attribute"
fi

# Verify aria-expanded reflects isExpanded state
if grep "aria-expanded" "$APP_JS" | grep -q "isExpanded"; then
    pass "aria-expanded value bound to isExpanded"
else
    fail "aria-expanded not bound to isExpanded"
fi

# =============================================================================
# Test 16: expand icon renders ▾ when expanded, ▸ when collapsed
# =============================================================================
echo "=== Test 16: expand icon uses correct Unicode characters ==="

# ▾ = \u25be (expanded), ▸ = \u25b8 (collapsed)
if grep "expand-icon" "$APP_JS" | grep -q "\\\\u25be"; then
    pass "expand icon uses \\u25be (▾) when expanded"
else
    fail "expand icon does not use \\u25be for expanded state"
fi

if grep "expand-icon" "$APP_JS" | grep -q "\\\\u25b8"; then
    pass "expand icon uses \\u25b8 (▸) when collapsed"
else
    fail "expand icon does not use \\u25b8 for collapsed state"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Results: Passed=${PASS} Failed=${FAIL} ==="

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
