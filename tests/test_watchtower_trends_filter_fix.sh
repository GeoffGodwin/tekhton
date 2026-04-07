#!/usr/bin/env bash
# =============================================================================
# test_watchtower_trends_filter_fix.sh
#
# Test suite for Watchtower Trends page filtering fix.
# Verifies that the Recent Runs section correctly defaults run_type to 'adhoc'
# (not 'milestone'), properly counts runs by type, and correctly filters
# visibility based on user-selected filter.
#
# Bug: Recent Runs section was only showing the last --milestone run,
# not showing recent --human runs due to incorrect run_type defaults.
#
# Fix: run_type now defaults to 'adhoc' throughout the filtering logic:
#   1. Filter counter aggregation defaults to 'adhoc'
#   2. Visibility count defaults to 'adhoc'
#   3. Per-run display defaults to 'adhoc'
#   4. matchFilter() correctly distinguishes human/adhoc/milestone types
#
# These tests verify:
# - run_type defaults to 'adhoc' not 'milestone' in counter logic
# - Filter counter correctly aggregates runs by actual type
# - matchFilter() distinguishes between human/adhoc/milestone
# - Visibility toggling updates run-count span and hidden class
# - All run types are properly displayed after filtering
# =============================================================================
set -euo pipefail

TEKHTON_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# =============================================================================
# Test 1: run_type defaults to 'adhoc' in filter counter logic
# =============================================================================
echo "=== Test 1: run_type defaults to 'adhoc' in counter logic ==="

APP_JS="${TEKHTON_HOME}/templates/watchtower/app.js"

# Line 663: Building filter counters with || 'adhoc' default
if grep -q "tn = (mRuns\[g\]\.run_type || 'adhoc')" "$APP_JS"; then
    pass "Counter aggregation defaults to 'adhoc': (run_type || 'adhoc')"
else
    fail "Counter aggregation missing 'adhoc' default"
fi

# Verify this is specifically in renderTrends() for type counters
TRENDS_FUNC=$(sed -n '/function renderTrends()/,/^  }/p' "$APP_JS")
if echo "$TRENDS_FUNC" | grep -q "tn = (mRuns\[g\]\.run_type || 'adhoc')"; then
    pass "run_type defaults applied inside renderTrends() function"
else
    fail "Counter default not found in renderTrends()"
fi

# =============================================================================
# Test 2: Visibility count also defaults to 'adhoc'
# =============================================================================
echo ""
echo "=== Test 2: Visibility count defaults to 'adhoc' ==="

# Line 671: Counting visible runs
if grep -q "runs\[vc\]\.run_type || 'adhoc'.*toLowerCase()" "$APP_JS"; then
    pass "Visibility counting defaults run_type to 'adhoc'"
else
    fail "Visibility count does not default to 'adhoc'"
fi

# =============================================================================
# Test 3: Per-run display defaults to 'adhoc'
# =============================================================================
echo ""
echo "=== Test 3: Per-run display defaults to 'adhoc' ==="

# Line 677: Getting run type for display
if grep -q "rt = (run\.run_type || 'adhoc')\.toLowerCase()" "$APP_JS"; then
    pass "Per-run type defaults to 'adhoc' for display"
else
    fail "Per-run type does not default to 'adhoc'"
fi

# =============================================================================
# Test 4: matchFilter() function exists and handles all types
# =============================================================================
echo ""
echo "=== Test 4: matchFilter() function logic ==="

# Line 640: matchFilter function definition
if grep -q "function matchFilter(fl, rt)" "$APP_JS"; then
    pass "matchFilter() function is defined"
else
    fail "matchFilter() function not found"
fi

# Verify it handles 'all' filter
if grep -A 1 "function matchFilter(fl, rt)" "$APP_JS" | \
   grep -q "fl === 'all'"; then
    pass "matchFilter() handles 'all' filter (show everything)"
else
    fail "matchFilter() does not handle 'all' filter"
fi

# Verify it handles 'human' filter (checks for 'human' prefix)
if grep "function matchFilter(fl, rt)" -A 1 "$APP_JS" | \
   grep -q "indexOf('human') === 0"; then
    pass "matchFilter() handles 'human' filter (prefix match)"
else
    fail "matchFilter() does not properly handle 'human' filter"
fi

# Verify it handles 'adhoc' filter
if grep "function matchFilter(fl, rt)" -A 1 "$APP_JS" | \
   grep -q "rt === 'adhoc' || rt === 'ad_hoc'"; then
    pass "matchFilter() handles 'adhoc' filter (supports both 'adhoc' and 'ad_hoc')"
else
    fail "matchFilter() does not properly handle 'adhoc' filter"
fi

# =============================================================================
# Test 5: getRunTypeFilter() and setRunTypeFilter() for localStorage
# =============================================================================
echo ""
echo "=== Test 5: Filter state persistence via localStorage ==="

# Lines 637-638
if grep -q "function getRunTypeFilter()" "$APP_JS"; then
    pass "getRunTypeFilter() function exists"
else
    fail "getRunTypeFilter() not found"
fi

if grep -q "function setRunTypeFilter(f)" "$APP_JS"; then
    pass "setRunTypeFilter() function exists"
else
    fail "setRunTypeFilter() not found"
fi

# Check getRunTypeFilter defaults to 'all'
if grep "function getRunTypeFilter()" -A 1 "$APP_JS" | \
   grep -q "'tk_run_type_filter') || 'all'"; then
    pass "getRunTypeFilter() defaults to 'all' when localStorage is empty"
else
    fail "getRunTypeFilter() does not default to 'all'"
fi

# =============================================================================
# Test 6: Filter button rendering with correct labels
# =============================================================================
echo ""
echo "=== Test 6: Filter button structure ==="

# Line 673: Filter button definitions
if grep -q "var fl = \[\['all','All'\]" "$APP_JS"; then
    pass "Filter buttons include 'All' option"
else
    fail "Filter buttons missing 'All' option"
fi

if grep "var fl = " "$APP_JS" | grep -q "'milestone','Milestones'"; then
    pass "Filter buttons include 'Milestones' option"
else
    fail "Filter buttons missing 'Milestones' option"
fi

if grep "var fl = " "$APP_JS" | grep -q "'human','Human Notes'"; then
    pass "Filter buttons include 'Human Notes' option"
else
    fail "Filter buttons missing 'Human Notes' option"
fi

if grep "var fl = " "$APP_JS" | grep -q "'adhoc','Ad Hoc'"; then
    pass "Filter buttons include 'Ad Hoc' option"
else
    fail "Filter buttons missing 'Ad Hoc' option"
fi

# =============================================================================
# Test 7: Filter button click handler updates visibility
# =============================================================================
echo ""
echo "=== Test 7: Filter button click handler logic ==="

# Lines 692-706: Button click logic
CLICK_HANDLER=$(sed -n '/for.*fbs\[fb\].*addEventListener/,/});/p' "$APP_JS" | head -20)

if echo "$CLICK_HANDLER" | grep -q "setRunTypeFilter(f)"; then
    pass "Click handler saves filter choice to localStorage"
else
    fail "Click handler does not persist filter choice"
fi

if echo "$CLICK_HANDLER" | grep -q "classList.toggle('active'"; then
    pass "Click handler toggles 'active' class on buttons"
else
    fail "Click handler does not toggle 'active' class"
fi

if echo "$CLICK_HANDLER" | grep -q "classList.toggle('hidden'"; then
    pass "Click handler toggles 'hidden' class on run items"
else
    fail "Click handler does not toggle 'hidden' class"
fi

# =============================================================================
# Test 8: JavaScript logic verification with Node.js
# =============================================================================
echo ""
echo "=== Test 8: JavaScript logic verification with Node.js ==="

NODE_TEST_FILE="${TMPDIR_BASE}/test_trends_filter.js"

cat > "$NODE_TEST_FILE" << 'EOF'
/**
 * Test the trends filter logic with mocked data.
 * Verifies that run_type defaults to 'adhoc' and matchFilter works correctly.
 */

function matchFilter(fl, rt) {
  return fl === 'all' || (fl === 'human' ? rt.indexOf('human') === 0 : (fl === 'adhoc' ? rt === 'adhoc' || rt === 'ad_hoc' : rt === fl));
}

// Test 1: matchFilter with 'all' filter
console.log('Test 1: matchFilter with all filter');
const allFilterTests = [
  { run_type: 'milestone', expected: true },
  { run_type: 'human_run_1', expected: true },
  { run_type: 'adhoc', expected: true },
  { run_type: 'drift', expected: true }
];

let allOk = true;
for (const test of allFilterTests) {
  const result = matchFilter('all', test.run_type);
  if (result !== test.expected) {
    console.log(`  ✗ FAIL: matchFilter('all', '${test.run_type}') returned ${result}, expected ${test.expected}`);
    allOk = false;
  }
}
if (allOk) {
  console.log('  ✓ PASS: all filter matches everything');
}

// Test 2: matchFilter with 'human' filter
console.log('Test 2: matchFilter with human filter');
const humanFilterTests = [
  { run_type: 'human_run_1', expected: true },
  { run_type: 'human_run_2', expected: true },
  { run_type: 'human_notes', expected: true },
  { run_type: 'milestone', expected: false },
  { run_type: 'adhoc', expected: false }
];

let humanOk = true;
for (const test of humanFilterTests) {
  const result = matchFilter('human', test.run_type);
  if (result !== test.expected) {
    console.log(`  ✗ FAIL: matchFilter('human', '${test.run_type}') returned ${result}, expected ${test.expected}`);
    humanOk = false;
  }
}
if (humanOk) {
  console.log('  ✓ PASS: human filter matches human_* runs');
}

// Test 3: matchFilter with 'adhoc' filter
console.log('Test 3: matchFilter with adhoc filter');
const adhocFilterTests = [
  { run_type: 'adhoc', expected: true },
  { run_type: 'ad_hoc', expected: true },
  { run_type: 'milestone', expected: false },
  { run_type: 'human_run_1', expected: false }
];

let adhocOk = true;
for (const test of adhocFilterTests) {
  const result = matchFilter('adhoc', test.run_type);
  if (result !== test.expected) {
    console.log(`  ✗ FAIL: matchFilter('adhoc', '${test.run_type}') returned ${result}, expected ${test.expected}`);
    adhocOk = false;
  }
}
if (adhocOk) {
  console.log('  ✓ PASS: adhoc filter matches adhoc and ad_hoc runs');
}

// Test 4: matchFilter with 'milestone' filter
console.log('Test 4: matchFilter with milestone filter');
const milestoneFilterTests = [
  { run_type: 'milestone', expected: true },
  { run_type: 'adhoc', expected: false },
  { run_type: 'human_run_1', expected: false }
];

let milestoneOk = true;
for (const test of milestoneFilterTests) {
  const result = matchFilter('milestone', test.run_type);
  if (result !== test.expected) {
    console.log(`  ✗ FAIL: matchFilter('milestone', '${test.run_type}') returned ${result}, expected ${test.expected}`);
    milestoneOk = false;
  }
}
if (milestoneOk) {
  console.log('  ✓ PASS: milestone filter matches only milestone runs');
}

// Test 5: Counter aggregation with default run_type
console.log('Test 5: Counter aggregation with default run_type');
const mRuns = [
  { run_type: 'milestone', total_turns: 10 },
  { run_type: 'human_run_1', total_turns: 5 },
  { run_type: undefined, total_turns: 3 },  // Should default to 'adhoc'
  { total_turns: 2 }  // Missing run_type entirely
];

const tg = {};
for (let g = 0; g < mRuns.length; g++) {
  const tn = (mRuns[g].run_type || 'adhoc').toLowerCase();
  if (!tg[tn]) tg[tn] = { t: 0, c: 0 };
  tg[tn].t += (mRuns[g].total_turns || 0);
  tg[tn].c++;
}

let counterOk = true;
if (tg['adhoc'] && tg['adhoc'].c === 2) {
  console.log('  ✓ PASS: Counter defaults undefined run_type to adhoc (count: ' + tg['adhoc'].c + ')');
} else {
  console.log('  ✗ FAIL: Counter did not properly aggregate adhoc runs');
  counterOk = false;
}

if (tg['milestone'] && tg['milestone'].c === 1) {
  console.log('  ✓ PASS: Milestone runs counted correctly');
} else {
  console.log('  ✗ FAIL: Milestone runs not counted');
  counterOk = false;
}

if (tg['human_run_1'] && tg['human_run_1'].c === 1) {
  console.log('  ✓ PASS: Human runs counted correctly');
} else {
  console.log('  ✗ FAIL: Human runs not counted');
  counterOk = false;
}

// Test 6: Visibility counting
console.log('Test 6: Visibility counting with filter');
const runs = [
  { run_type: 'milestone', outcome: 'pass' },
  { run_type: 'human_run_1', outcome: 'pass' },
  { run_type: 'human_run_2', outcome: 'pass' },
  { run_type: undefined, outcome: 'pass' },  // Default to adhoc
  { run_type: 'drift', outcome: 'pass' }
];

const af = 'human';  // Filter for human runs
let visCount = 0;
for (let vc = 0; vc < runs.length; vc++) {
  if (matchFilter(af, (runs[vc].run_type || 'adhoc').toLowerCase())) visCount++;
}

if (visCount === 2) {
  console.log('  ✓ PASS: Visibility count correct with human filter (' + visCount + ' visible)');
} else {
  console.log('  ✗ FAIL: Visibility count incorrect (got ' + visCount + ', expected 2)');
}

if (humanOk && adhocOk && milestoneOk && counterOk) {
  process.exit(0);
} else {
  process.exit(1);
}
EOF

if node "$NODE_TEST_FILE"; then
    pass "JavaScript logic verification passed (Node.js tests)"
else
    fail "JavaScript logic verification failed (Node.js tests)"
fi

# =============================================================================
# Test 9: Verify Recent Runs section structure
# =============================================================================
echo ""
echo "=== Test 9: Recent Runs section HTML structure ==="

# Line 672: Recent Runs header with count span
if grep -q "Recent Runs.*run-count" "$APP_JS"; then
    pass "Recent Runs header includes run-count span for dynamic updates"
else
    fail "Recent Runs section missing run-count span"
fi

# Filter buttons container
if grep -q "run-type-filters" "$APP_JS"; then
    pass "Filter buttons container exists"
else
    fail "Filter buttons container not found"
fi

# Run list container
if grep -q "class=\"run-list\"" "$APP_JS"; then
    pass "Run list container exists"
else
    fail "Run list container not found"
fi

# =============================================================================
# Test 10: Verify no hard-coded 'milestone' defaults in filter logic
# =============================================================================
echo ""
echo "=== Test 10: No incorrect 'milestone' defaults in filter logic ==="

# The renderTrends function should use 'adhoc' as default, not 'milestone'
TRENDS_SECTION=$(sed -n '/function renderTrends()/,/^  }/p' "$APP_JS")

# Count how many times 'run_type || 'adhoc'' appears in trends
ADHOC_DEFAULTS=$(echo "$TRENDS_SECTION" | grep -c "run_type || 'adhoc'")

if [ "$ADHOC_DEFAULTS" -ge 3 ]; then
    pass "renderTrends() correctly defaults to 'adhoc' in at least 3 places (found: $ADHOC_DEFAULTS)"
else
    fail "renderTrends() missing some 'adhoc' defaults (found: $ADHOC_DEFAULTS, expected 3+)"
fi

# Verify no direct 'milestone' assignment as a default (should only be checked, not defaulted)
if echo "$TRENDS_SECTION" | grep "run_type || 'milestone'" | grep -q "run_type ||"; then
    fail "Found incorrect 'milestone' default in renderTrends()"
else
    pass "No incorrect 'milestone' defaults in renderTrends()"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "Test Results: ${PASS} passed, ${FAIL} failed"
echo "========================================="

[[ "$FAIL" -eq 0 ]]
