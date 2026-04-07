#!/usr/bin/env bash
# =============================================================================
# test_watchtower_distribution_toggle.sh
#
# Test suite for Watchtower Trends page Distribution mode toggle.
#
# Task: [POLISH] The Distribution section doesn't make it clear what it's
# calculating. Scout (least time) showed as highest distribution (confusing).
# Fix: Add toggle to switch between "Time Spent" (default) and "Run Count"
# modes. Default to time-based bars. Add localStorage persistence.
#
# These tests verify:
# - getDistMode() and setDistMode() functions exist
# - Default mode is 'time' (not 'turns')
# - localStorage persistence code pattern
# - Toggle buttons are rendered with correct labels and data attributes
# - Distribution label reflects active mode
# - Bar calculation uses time-based data for 'time' mode
# - Bar calculation uses turn-based data for 'turns' mode
# - Tooltip text includes correct units per mode
# - Toggle click handlers call setDistMode() and renderTrends()
# - activeStages list includes only stages with turn count data
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PASS=0
FAIL=0

pass() {
    echo "  ✓ PASS: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ FAIL: $1"
    FAIL=$((FAIL + 1))
}

APP_JS="${TEKHTON_HOME}/templates/watchtower/app.js"

# =============================================================================
# Test 1: getDistMode() function exists and has correct default
# =============================================================================
echo "=== Test 1: getDistMode() function ==="

if grep -q "function getDistMode()" "$APP_JS"; then
    pass "getDistMode() function is defined"
else
    fail "getDistMode() function not found"
fi

# Verify it reads from localStorage with 'tk_dist_mode' key
if grep "function getDistMode()" -A 1 "$APP_JS" | \
   grep -q "localStorage.getItem('tk_dist_mode')"; then
    pass "getDistMode() reads from localStorage with 'tk_dist_mode' key"
else
    fail "getDistMode() does not read from correct localStorage key"
fi

# Verify it defaults to 'time' mode
if grep "function getDistMode()" -A 1 "$APP_JS" | \
   grep -q "'tk_dist_mode') || 'time'"; then
    pass "getDistMode() defaults to 'time' mode"
else
    fail "getDistMode() does not default to 'time'"
fi

# Verify it returns 'time' on localStorage error
if grep "function getDistMode()" -A 2 "$APP_JS" | \
   grep -q "return 'time'"; then
    pass "getDistMode() returns 'time' on error"
else
    fail "getDistMode() does not return 'time' on error"
fi

# =============================================================================
# Test 2: setDistMode() function exists and sets localStorage
# =============================================================================
echo ""
echo "=== Test 2: setDistMode() function ==="

if grep -q "function setDistMode(m)" "$APP_JS"; then
    pass "setDistMode() function is defined"
else
    fail "setDistMode() function not found"
fi

# Verify it writes to localStorage with 'tk_dist_mode' key
if grep "function setDistMode(m)" -A 1 "$APP_JS" | \
   grep -q "localStorage.setItem('tk_dist_mode'"; then
    pass "setDistMode() writes to localStorage"
else
    fail "setDistMode() does not write to localStorage"
fi

# Verify error handling
if grep "function setDistMode(m)" -A 1 "$APP_JS" | \
   grep -q "catch (e)"; then
    pass "setDistMode() has error handling"
else
    fail "setDistMode() lacks error handling"
fi

# =============================================================================
# Test 3: renderStageBreakdown() calls getDistMode()
# =============================================================================
echo ""
echo "=== Test 3: renderStageBreakdown() integration ==="

# M66: renderStageBreakdown now delegates row rendering to _renderStageRow.
# Extract both functions for pattern matching.
BREAKDOWN_FUNC=$(sed -n '/function renderStageBreakdown(runs)/,/^  }/p' "$APP_JS")
STAGE_ROW_FUNC=$(sed -n '/function _renderStageRow(/,/^  }/p' "$APP_JS")
BREAKDOWN_ALL="${BREAKDOWN_FUNC}${STAGE_ROW_FUNC}"

if echo "$BREAKDOWN_FUNC" | grep -q "var mode = getDistMode()"; then
    pass "renderStageBreakdown() calls getDistMode()"
else
    fail "renderStageBreakdown() does not call getDistMode()"
fi

# =============================================================================
# Test 4: Distribution label reflects mode
# =============================================================================
echo ""
echo "=== Test 4: Distribution label reflects mode ==="

# Verify label includes mode name
if echo "$BREAKDOWN_FUNC" | grep -q "Distribution.*'Time Spent'"; then
    pass "Distribution label shows 'Time Spent' for time mode"
else
    fail "Distribution label does not show 'Time Spent'"
fi

# Verify Avg Turns label appears
if echo "$BREAKDOWN_FUNC" | grep -q "'Avg Turns'"; then
    pass "Distribution label includes 'Avg Turns' option"
else
    fail "Distribution label does not mention 'Avg Turns'"
fi

# =============================================================================
# Test 5: Toggle buttons rendered with correct labels and attributes
# =============================================================================
echo ""
echo "=== Test 5: Toggle button rendering ==="

# Verify toggle container is rendered
if echo "$BREAKDOWN_FUNC" | grep -q "data-dist-toggle"; then
    pass "Toggle container has data-dist-toggle attribute"
else
    fail "Toggle container missing data-dist-toggle attribute"
fi

# Verify Time Spent button
if echo "$BREAKDOWN_FUNC" | grep -q "dist-btn.*data-mode=\"time\""; then
    pass "Time Spent button has data-mode='time' attribute"
else
    fail "Time Spent button missing or misnamed"
fi

# Verify Avg Turns button
if echo "$BREAKDOWN_FUNC" | grep -q "dist-btn.*data-mode=\"turns\""; then
    pass "Avg Turns button has data-mode='turns' attribute"
else
    fail "Avg Turns button missing or misnamed"
fi

# Verify active class based on mode
if echo "$BREAKDOWN_FUNC" | grep -q "mode === 'time' ? ' active' : ''"; then
    pass "Time Spent button gets 'active' class when mode is 'time'"
else
    fail "Time Spent button does not conditionally add 'active' class"
fi

if echo "$BREAKDOWN_FUNC" | grep -q "mode === 'turns' ? ' active' : ''"; then
    pass "Run Count button gets 'active' class when mode is 'turns'"
else
    fail "Run Count button does not conditionally add 'active' class"
fi

# =============================================================================
# Test 6: Both time and turn averages computed
# =============================================================================
echo ""
echo "=== Test 6: Both metric types computed ==="

# Verify stageTotals tracks both turns and time
if echo "$BREAKDOWN_FUNC" | grep -q "stageTotals\[sn\] = { turns: 0, time: 0 }"; then
    pass "stageTotals initialized with both 'turns' and 'time' fields"
else
    fail "stageTotals missing field initialization"
fi

# Verify turn counting per stage
if echo "$BREAKDOWN_FUNC" | grep -q "stageTurnCount\[sn\] = 0"; then
    pass "stageTurnCount array initialized for each stage"
else
    fail "stageTurnCount array not initialized"
fi

# Verify time counting per stage
if echo "$BREAKDOWN_FUNC" | grep -q "stageTimeCount\[sn\] = 0"; then
    pass "stageTimeCount array initialized for each stage"
else
    fail "stageTimeCount array not initialized"
fi

# =============================================================================
# Test 7: Max averages computed for both metrics
# =============================================================================
echo ""
echo "=== Test 7: Max averages for both modes ==="

# Verify maxAvgTurns is computed
if echo "$BREAKDOWN_FUNC" | grep -q "var maxAvgTurns = 1"; then
    pass "maxAvgTurns initialized"
else
    fail "maxAvgTurns not initialized"
fi

# Verify maxAvgTime is computed (on same line as maxAvgTurns)
if echo "$BREAKDOWN_FUNC" | grep -q "maxAvgTime = 1"; then
    pass "maxAvgTime initialized"
else
    fail "maxAvgTime not initialized"
fi

# Verify maxAvgTurns is updated
if echo "$BREAKDOWN_FUNC" | grep -q "if (aT > maxAvgTurns)"; then
    pass "maxAvgTurns is updated in loop"
else
    fail "maxAvgTurns not updated"
fi

# Verify maxAvgTime is updated
if echo "$BREAKDOWN_FUNC" | grep -q "if (aTm > maxAvgTime)"; then
    pass "maxAvgTime is updated in loop"
else
    fail "maxAvgTime not updated"
fi

# =============================================================================
# Test 8: Bar calculation for time mode
# =============================================================================
echo ""
echo "=== Test 8: Bar calculation for time mode ==="

# Verify time mode uses time data
if echo "$BREAKDOWN_FUNC" | grep -q "mode === 'time'"; then
    pass "Time mode check exists"
else
    fail "Time mode check not found"
fi

# Verify time mode calculates bar percentage using time
if echo "$BREAKDOWN_ALL" | grep -A 3 "mode === 'time'" | \
   grep -q "avgTimeRaw / maxTime"; then
    pass "Time mode calculates bar percentage from time data"
else
    fail "Time mode does not use time data for bar calculation"
fi

# Verify time mode tooltip shows duration
if echo "$BREAKDOWN_ALL" | grep -A 3 "mode === 'time'" | \
   grep -q "fmtDuration"; then
    pass "Time mode tooltip formats duration in tooltip"
else
    fail "Time mode tooltip does not format duration"
fi

# =============================================================================
# Test 9: Bar calculation for turns mode
# =============================================================================
echo ""
echo "=== Test 9: Bar calculation for turns mode ==="

# Verify turns mode uses turn data (in _renderStageRow)
if echo "$BREAKDOWN_ALL" | grep -q "else {"; then
    pass "Else block for turns mode exists"
else
    fail "Turns mode calculation missing"
fi

# Verify turns mode calculates bar percentage using turns
if echo "$BREAKDOWN_ALL" | grep -q "avgT / maxTurns"; then
    pass "Turns mode calculates bar percentage from turn data"
else
    fail "Turns mode does not use turn data for bar calculation"
fi

# Verify turns mode tooltip shows turn count
if echo "$BREAKDOWN_ALL" | grep -q "turns avg"; then
    pass "Turns mode tooltip shows turn count"
else
    fail "Turns mode tooltip does not show turn count"
fi

# =============================================================================
# Test 10: Toggle event listener setup
# =============================================================================
echo ""
echo "=== Test 10: Toggle event listener ==="

RENDER_TRENDS=$(sed -n '/function renderTrends()/,/^  }/p' "$APP_JS")

# Verify toggle button listeners are registered
if echo "$RENDER_TRENDS" | grep -q "data-dist-toggle"; then
    pass "Toggle container is referenced in renderTrends()"
else
    fail "Toggle container not found in renderTrends()"
fi

# Verify click handler exists
if echo "$RENDER_TRENDS" | grep -q "addEventListener('click'"; then
    pass "Click event listener added to toggle buttons"
else
    fail "Click event listener not added"
fi

# Verify click handler calls setDistMode - check the specific pattern in renderTrends
if echo "$RENDER_TRENDS" | grep -q "setDistMode(m)"; then
    pass "Toggle click handler calls setDistMode()"
else
    fail "Toggle click handler does not call setDistMode()"
fi

# Verify click handler calls renderTrends
if echo "$RENDER_TRENDS" | grep -q "renderTrends()"; then
    pass "Toggle click handler calls renderTrends() to re-render"
else
    fail "Toggle click handler does not call renderTrends()"
fi

# =============================================================================
# Test 11: activeStages filtering
# =============================================================================
echo ""
echo "=== Test 11: activeStages filtering ==="

# Verify only stages with turn count data are included (uses stageGroupOrder)
if echo "$BREAKDOWN_FUNC" | grep -q "stageTurnCount\[gn\] > 0"; then
    pass "activeStages only includes stages with turn count data"
else
    fail "activeStages does not filter by turn count"
fi

# Verify early return when no active stages
if echo "$BREAKDOWN_FUNC" | grep -q "No per-stage data available yet"; then
    pass "Function returns helpful message when no stages available"
else
    fail "No message for empty stage data"
fi

# =============================================================================
# Test 12: Bar width calculation is not missing division protection
# =============================================================================
echo ""
echo "=== Test 12: Division by zero protection ==="

# Verify maxTime check before division (in _renderStageRow)
if echo "$BREAKDOWN_ALL" | grep -q "maxTime > 0"; then
    pass "Division by zero check for maxAvgTime"
else
    fail "maxAvgTime division not protected"
fi

# Verify maxAvgTurns check before division
if echo "$BREAKDOWN_FUNC" | grep -q "maxAvgTurns"; then
    pass "maxAvgTurns used in bar calculation"
else
    fail "maxAvgTurns not used in calculation"
fi

# =============================================================================
# Test 13: Table headers and structure
# =============================================================================
echo ""
echo "=== Test 13: Table structure ==="

# Verify table has correct headers
if echo "$BREAKDOWN_FUNC" | grep -q "<th>Stage</th>"; then
    pass "Stage header present"
else
    fail "Stage header missing"
fi

if echo "$BREAKDOWN_FUNC" | grep -q "<th>Avg Turns</th>"; then
    pass "Avg Turns header present"
else
    fail "Avg Turns header missing"
fi

if echo "$BREAKDOWN_FUNC" | grep -q "<th>Avg Time</th>"; then
    pass "Avg Time header present"
else
    fail "Avg Time header missing"
fi

if echo "$BREAKDOWN_FUNC" | grep -q "class=\"bar-chart-cell\".*Distribution"; then
    pass "Distribution column header has bar-chart-cell class"
else
    fail "Distribution column header missing bar-chart-cell class"
fi

# =============================================================================
# Test 14: CSS styles exist for distribution toggle
# =============================================================================
echo ""
echo "=== Test 14: CSS styling ==="

STYLE_CSS="${TEKHTON_HOME}/templates/watchtower/style.css"

if grep -q "\.dist-btn" "$STYLE_CSS"; then
    pass ".dist-btn style class defined"
else
    fail ".dist-btn style class not found"
fi

if grep -q "\.dist-toggle" "$STYLE_CSS"; then
    pass ".dist-toggle style class defined"
else
    fail ".dist-toggle style class not found"
fi

if grep -q "\.dist-header" "$STYLE_CSS"; then
    pass ".dist-header style class defined"
else
    fail ".dist-header style class not found"
fi

if grep -q "\.dist-label" "$STYLE_CSS"; then
    pass ".dist-label style class defined"
else
    fail ".dist-label style class not found"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== SUMMARY ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi

exit 0
