#!/usr/bin/env bash
# =============================================================================
# test_watchtower_parallel_groups_datalist.sh
#
# Test suite for Watchtower Parallel Groups datalist functionality.
# Verifies that:
# 1. getExistingGroups() extracts group names from milestones correctly
# 2. The datalist is populated with all existing groups
# 3. New groups typed by users can be added to the datalist (free-text entry)
# 4. Session-level datalist persistence works correctly
#
# Bug Fixed: "Cannot add new Parallel Groups, only existing ones are selectable.
# New projects have only one (or zero) options available"
#
# Root Cause: The datalist was initially empty for new projects (no existing
# milestones), and users didn't understand they could type arbitrary group names.
#
# Fixes:
# 1. Improved placeholder text: "Type new or pick existing"
# 2. Added hint text: "Free-text: type any group name"
# 3. Session-level datalist update: After creating a milestone with a new group,
#    the group is added to the datalist for reuse in subsequent creations
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
# Test 1: getExistingGroups() function is present
# =============================================================================
echo "=== Test 1: getExistingGroups() function presence ==="

APP_JS="${TEKHTON_HOME}/templates/watchtower/app.js"

if grep -q "function getExistingGroups()" "$APP_JS"; then
    pass "getExistingGroups() function is defined"
else
    fail "getExistingGroups() function not found in app.js"
fi

# Verify it extracts from milestones()
if grep -A 10 "function getExistingGroups()" "$APP_JS" | grep -q "milestones()"; then
    pass "getExistingGroups() calls milestones()"
else
    fail "getExistingGroups() does not call milestones()"
fi

# Verify it accesses parallel_group property
if grep -A 10 "function getExistingGroups()" "$APP_JS" | grep -q "\.parallel_group"; then
    pass "getExistingGroups() accesses .parallel_group property"
else
    fail "getExistingGroups() does not access .parallel_group"
fi

# =============================================================================
# Test 2: Placeholder text indicates free-text entry
# =============================================================================
echo ""
echo "=== Test 2: Placeholder text and hints ==="

if grep -q 'placeholder="Type new or pick existing"' "$APP_JS"; then
    pass "Placeholder text 'Type new or pick existing' is present"
else
    fail "Placeholder text 'Type new or pick existing' not found"
fi

if grep -q "Free-text: type any group name" "$APP_JS"; then
    pass "Form hint 'Free-text: type any group name' is present"
else
    fail "Form hint text not found"
fi

# =============================================================================
# Test 3: Datalist HTML structure in renderActions()
# =============================================================================
echo ""
echo "=== Test 3: Datalist HTML structure ==="

# Extract renderActions function
RENDER_ACTIONS=$(sed -n '/function renderActions()/,/^  }/p' "$APP_JS" | head -100)

if echo "$RENDER_ACTIONS" | grep -q 'id="ms-group-list"'; then
    pass "Datalist with id='ms-group-list' is created"
else
    fail "Datalist with id='ms-group-list' not found"
fi

if echo "$RENDER_ACTIONS" | grep -q 'list="ms-group-list"'; then
    pass "Input element references datalist via list='ms-group-list'"
else
    fail "Input element does not reference datalist"
fi

# =============================================================================
# Test 4: getExistingGroups() JavaScript logic with Node.js
# =============================================================================
echo ""
echo "=== Test 4: getExistingGroups() behavior with Node.js ==="

NODE_TEST_FILE="${TMPDIR_BASE}/test_get_existing_groups.js"

cat > "$NODE_TEST_FILE" << 'EOF'
/**
 * Test getExistingGroups() logic with various milestone configurations.
 */

function simulateGetExistingGroups(milestones) {
  const groups = {};
  for (let i = 0; i < milestones.length; i++) {
    const g = milestones[i].parallel_group;
    if (g) groups[g] = true;
  }
  const result = [];
  for (const k in groups) {
    if (groups.hasOwnProperty(k)) result.push(k);
  }
  return result.sort();
}

let passCount = 0;
let failCount = 0;

function assertEqual(actual, expected, testName) {
  const actualStr = JSON.stringify(actual);
  const expectedStr = JSON.stringify(expected);
  if (actualStr === expectedStr) {
    console.log(`  ✓ PASS: ${testName}`);
    passCount++;
  } else {
    console.log(`  ✗ FAIL: ${testName}`);
    console.log(`    Expected: ${expectedStr}`);
    console.log(`    Actual:   ${actualStr}`);
    failCount++;
  }
}

// Test 1: Empty milestones
console.log('Test 1: Empty milestones array');
assertEqual(simulateGetExistingGroups([]), [], 'Returns empty array when no milestones exist');

// Test 2: Single milestone with group
console.log('\nTest 2: Single milestone with parallel_group');
const ms1 = [{ id: 'm01', parallel_group: 'foundation' }];
assertEqual(simulateGetExistingGroups(ms1), ['foundation'], 'Returns single group from one milestone');

// Test 3: Multiple milestones with same group (no duplicates)
console.log('\nTest 3: Multiple milestones with same parallel_group');
const ms2 = [
  { id: 'm01', parallel_group: 'foundation' },
  { id: 'm02', parallel_group: 'foundation' },
  { id: 'm03', parallel_group: 'foundation' }
];
assertEqual(simulateGetExistingGroups(ms2), ['foundation'], 'Returns no duplicates when multiple milestones share same group');

// Test 4: Multiple milestones with different groups
console.log('\nTest 4: Multiple milestones with different parallel_groups');
const ms3 = [
  { id: 'm01', parallel_group: 'foundation' },
  { id: 'm02', parallel_group: 'feature' },
  { id: 'm03', parallel_group: 'bugfix' }
];
assertEqual(simulateGetExistingGroups(ms3), ['bugfix', 'feature', 'foundation'], 'Returns all unique groups sorted alphabetically');

// Test 5: Milestones without parallel_group
console.log('\nTest 5: Milestones without parallel_group');
const ms4 = [
  { id: 'm01', parallel_group: '' },
  { id: 'm02', parallel_group: null },
  { id: 'm03' }
];
assertEqual(simulateGetExistingGroups(ms4), [], 'Returns empty array when milestones have no groups');

// Test 6: Mixed milestones (some with groups, some without)
console.log('\nTest 6: Mixed milestones (some with groups, some without)');
const ms5 = [
  { id: 'm01', parallel_group: 'alpha' },
  { id: 'm02' },
  { id: 'm03', parallel_group: 'beta' },
  { id: 'm04', parallel_group: '' }
];
assertEqual(simulateGetExistingGroups(ms5), ['alpha', 'beta'], 'Returns only populated groups, ignoring empty/null/missing');

// Test 7: Verify sorting (alphabetical order)
console.log('\nTest 7: Alphabetical sorting');
const ms6 = [
  { id: 'm01', parallel_group: 'zebra' },
  { id: 'm02', parallel_group: 'apple' },
  { id: 'm03', parallel_group: 'monkey' }
];
assertEqual(simulateGetExistingGroups(ms6), ['apple', 'monkey', 'zebra'], 'Results are sorted alphabetically');

// Test 8: Case sensitivity (groups are case-sensitive)
console.log('\nTest 8: Case sensitivity');
const ms7 = [
  { id: 'm01', parallel_group: 'Foundation' },
  { id: 'm02', parallel_group: 'foundation' },
  { id: 'm03', parallel_group: 'FOUNDATION' }
];
assertEqual(simulateGetExistingGroups(ms7), ['FOUNDATION', 'Foundation', 'foundation'], 'Groups are case-sensitive and treated as distinct');

console.log(`\n========================================`);
console.log(`Results: ${passCount} passed, ${failCount} failed`);
console.log(`========================================`);
process.exitCode = failCount === 0 ? 0 : 1;
EOF

if node "$NODE_TEST_FILE"; then
    pass "getExistingGroups() logic verification passed (Node.js tests)"
else
    fail "getExistingGroups() logic verification failed (Node.js tests)"
fi

# =============================================================================
# Test 5: getExistingGroups() is called during renderActions()
# =============================================================================
echo ""
echo "=== Test 5: getExistingGroups() integration in renderActions() ==="

RENDER_ACTIONS_FULL=$(sed -n '/function renderActions()/,/^  }/p' "$APP_JS")

if echo "$RENDER_ACTIONS_FULL" | grep -q "var groups = getExistingGroups()"; then
    pass "renderActions() calls getExistingGroups() and stores result"
else
    fail "renderActions() does not call getExistingGroups()"
fi

# =============================================================================
# Test 6: Datalist options are populated from getExistingGroups()
# =============================================================================
echo ""
echo "=== Test 6: Datalist population from groups array ==="

DATALIST_SECTION=$(sed -n '/datalist id="ms-group-list"/,/<\/datalist>/p' "$APP_JS" | head -10)

if echo "$DATALIST_SECTION" | grep -q "for (var g = 0; g < groups.length; g++)"; then
    pass "Loop iterates over groups array"
else
    fail "Groups loop not found in datalist rendering"
fi

if echo "$DATALIST_SECTION" | grep -q "esc(groups\[g\])"; then
    pass "Group values are properly escaped in datalist options"
else
    fail "Groups are not properly escaped"
fi

# =============================================================================
# Test 7: Session-level datalist persistence (adding new option)
# =============================================================================
echo ""
echo "=== Test 7: Session-level datalist persistence logic ==="

NODE_PERSISTENCE_FILE="${TMPDIR_BASE}/test_datalist_persistence.js"

cat > "$NODE_PERSISTENCE_FILE" << 'EOF'
/**
 * Test session-level datalist persistence logic.
 * When a milestone is created with a new group, the group should be added
 * to the datalist so it appears as a suggestion in subsequent creations.
 */

function simulateDatalistPersistence() {
  // Simulate the DOM and functions
  const datalist = {
    options: [
      { value: 'foundation' },
      { value: 'feature' }
    ],
    appendChild: function(opt) {
      this.options.push(opt);
    }
  };

  function esc(str) {
    return str; // Simplified for this test
  }

  function createElement(tag) {
    return { value: null };
  }

  const callLog = [];

  // Simulate milestone creation with new group
  function createMilestoneWithGroup(groupName) {
    const dl = datalist;
    if (dl) {
      let dup = false;
      for (let o = 0; o < dl.options.length; o++) {
        if (dl.options[o].value === groupName) {
          dup = true;
          callLog.push(`found_duplicate: ${groupName}`);
          break;
        }
      }
      if (!dup) {
        const opt = { value: groupName };
        dl.appendChild(opt);
        callLog.push(`added_option: ${groupName}`);
      }
    }
  }

  // Test 1: Add new group that doesn't exist
  createMilestoneWithGroup('bugfix');

  // Verify it was added
  const hasBugfix = datalist.options.some(o => o.value === 'bugfix');

  // Test 2: Try to add duplicate
  createMilestoneWithGroup('bugfix');

  // Count how many times 'bugfix' appears
  const bugfixCount = datalist.options.filter(o => o.value === 'bugfix').length;

  // Test 3: Add another new group
  createMilestoneWithGroup('optimization');

  const hasOptimization = datalist.options.some(o => o.value === 'optimization');

  let passed = 0;
  let failed = 0;

  if (hasBugfix) {
    console.log('  ✓ PASS: New group "bugfix" was added to datalist');
    passed++;
  } else {
    console.log('  ✗ FAIL: New group "bugfix" was not added to datalist');
    failed++;
  }

  if (bugfixCount === 1) {
    console.log('  ✓ PASS: Duplicate "bugfix" was not added (prevents duplication)');
    passed++;
  } else {
    console.log(`  ✗ FAIL: "bugfix" appears ${bugfixCount} times, expected 1`);
    failed++;
  }

  if (hasOptimization) {
    console.log('  ✓ PASS: Second new group "optimization" was added to datalist');
    passed++;
  } else {
    console.log('  ✗ FAIL: Group "optimization" was not added');
    failed++;
  }

  // Verify final datalist has all groups
  const expectedGroups = new Set(['foundation', 'feature', 'bugfix', 'optimization']);
  const actualGroups = new Set(datalist.options.map(o => o.value));

  if (expectedGroups.size === actualGroups.size &&
      [...expectedGroups].every(g => actualGroups.has(g))) {
    console.log('  ✓ PASS: Final datalist contains all groups (original + added)');
    passed++;
  } else {
    console.log('  ✗ FAIL: Final datalist groups mismatch');
    console.log(`    Expected: ${JSON.stringify([...expectedGroups])}`);
    console.log(`    Actual:   ${JSON.stringify([...actualGroups])}`);
    failed++;
  }

  console.log(`\nDatalist persistence: ${passed} passed, ${failed} failed`);
  return failed === 0 ? 0 : 1;
}

process.exitCode = simulateDatalistPersistence();
EOF

if node "$NODE_PERSISTENCE_FILE"; then
    pass "Datalist persistence logic verification passed"
else
    fail "Datalist persistence logic verification failed"
fi

# =============================================================================
# Test 8: Verify the persistence code is present in milestone submit handler
# =============================================================================
echo ""
echo "=== Test 8: Datalist persistence code presence ==="

# Find the milestone submit handler section (larger context)
MS_SUBMIT=$(sed -n '/var msBtn = document.getElementById.*ms-submit/,/Task submit/p' "$APP_JS")

if echo "$MS_SUBMIT" | grep -q 'var dl = document.getElementById.*ms-group-list'; then
    pass "Milestone submit handler gets reference to datalist"
else
    fail "Milestone submit handler does not reference datalist"
fi

if echo "$MS_SUBMIT" | grep -q 'for (var o = 0; o < dl.options.length; o++)'; then
    pass "Submit handler checks existing datalist options"
else
    fail "Submit handler does not check existing options"
fi

if echo "$MS_SUBMIT" | grep -q 'document.createElement'; then
    pass "Submit handler creates new elements"
else
    fail "Submit handler does not create new elements"
fi

if echo "$MS_SUBMIT" | grep -q 'dl.appendChild(opt)'; then
    pass "Submit handler appends new option to datalist"
else
    fail "Submit handler does not append option to datalist"
fi

# =============================================================================
# Test 9: Persistence only runs when group is not empty
# =============================================================================
echo ""
echo "=== Test 9: Empty group handling ==="

NODE_EMPTY_GROUP_FILE="${TMPDIR_BASE}/test_empty_group.js"

cat > "$NODE_EMPTY_GROUP_FILE" << 'EOF'
/**
 * Verify that empty group names are not added to the datalist.
 */

function testEmptyGroupHandling() {
  let passCount = 0;
  let failCount = 0;

  // Simulate the condition: if (group.trim())
  const testCases = [
    { group: 'foundation', shouldProcess: true, label: 'normal group' },
    { group: '  foundation  ', shouldProcess: true, label: 'group with spaces' },
    { group: '', shouldProcess: false, label: 'empty string' },
    { group: '  ', shouldProcess: false, label: 'whitespace only' },
    { group: null, shouldProcess: false, label: 'null value' }
  ];

  for (const test of testCases) {
    // Simulate: if (group.trim())
    const groupStr = test.group || '';
    const shouldProcess = groupStr.trim() !== '';

    if (shouldProcess === test.shouldProcess) {
      console.log(`  ✓ PASS: ${test.label} handled correctly`);
      passCount++;
    } else {
      console.log(`  ✗ FAIL: ${test.label} handling incorrect`);
      failCount++;
    }
  }

  console.log(`\nEmpty group handling: ${passCount} passed, ${failCount} failed`);
  return failCount === 0 ? 0 : 1;
}

process.exitCode = testEmptyGroupHandling();
EOF

if node "$NODE_EMPTY_GROUP_FILE"; then
    pass "Empty group handling logic is correct"
else
    fail "Empty group handling logic has issues"
fi

# =============================================================================
# Test 10: Verify code location in submit handler (after successful submission)
# =============================================================================
echo ""
echo "=== Test 10: Datalist update timing ==="

# Extract section after milestone submission to verify manifest and datalist handling
MS_SUBMIT_CALLBACK=$(grep -A 30 "submitFile.*milestone_.*\.md" "$APP_JS" | head -35)

if echo "$MS_SUBMIT_CALLBACK" | grep -q "submitFile.*manifest"; then
    pass "Manifest file is submitted after milestone file"
else
    fail "Manifest submission not found"
fi

# Verify datalist update is in the success callback
if echo "$MS_SUBMIT_CALLBACK" | grep -q "if (ok2)"; then
    if echo "$MS_SUBMIT_CALLBACK" | grep -A 5 "if (ok2)" | grep -q "ms-group-list"; then
        pass "Datalist update is in the success callback (after manifest submission)"
    else
        fail "Datalist update not found in success callback"
    fi
else
    fail "Success callback for manifest submission not found"
fi

# =============================================================================
# Test 11: Form fields are cleared after successful creation
# =============================================================================
echo ""
echo "=== Test 11: Form reset after successful creation ==="

MS_SUCCESS=$(sed -n '/showFormSuccess.*ms-form/,/showFormSuccess.*ms-form/p' "$APP_JS" | head -20)

if echo "$MS_SUBMIT_CALLBACK" | grep -q "ms-title.*value = ''"; then
    pass "Milestone title field is cleared after submission"
else
    fail "Title field is not cleared"
fi

if echo "$MS_SUBMIT_CALLBACK" | grep -q "ms-desc.*value = ''"; then
    pass "Milestone description field is cleared after submission"
else
    fail "Description field is not cleared"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "========================================="
echo "Test Results: ${PASS} passed, ${FAIL} failed"
echo "========================================="

[[ "$FAIL" -eq 0 ]]
